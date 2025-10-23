import Foundation
import SwiftData
import FirebaseFirestore

@MainActor
final class ConversationsSyncService {
    private let db = Firestore.firestore()
    private var listener: ListenerRegistration?
    private var currentUserID: String?
    private weak var modelContext: ModelContext?
    private var onChange: (() -> Void)?

    func start(for userID: String, modelContext: ModelContext, onChange: @escaping () -> Void) {
        stop()
        currentUserID = userID
        self.modelContext = modelContext
        self.onChange = onChange

        print("[ConversationsSync] Starting listener for user: \(userID)")
        listener = db.collection("conversations")
            .whereField("participants", arrayContains: userID)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }

                if let error {
                    print("[ConversationsSync] Snapshot error: \(error)")
                    return
                }

                guard let snapshot else { return }

                print("[ConversationsSync] Received \(snapshot.documentChanges.count) changes")
                for change in snapshot.documentChanges {
                    print("[ConversationsSync] Change: \(change.type.rawValue) for document: \(change.document.documentID)")
                }

                Task { @MainActor in
                    await self.processChanges(snapshot.documentChanges)
                }
            }
    }

    func refresh() async {
        guard let userID = currentUserID else { return }

        do {
            let snapshot = try await db.collection("conversations")
                .whereField("participants", arrayContains: userID)
                .getDocuments()
            try await processSnapshot(snapshot.documents)
        } catch {
            print("[ConversationsSync] Refresh failed: \(error)")
        }
    }

    func stop() {
        listener?.remove()
        listener = nil
        currentUserID = nil
        modelContext = nil
        onChange = nil
    }

    private func processChanges(_ changes: [DocumentChange]) async {
        guard let modelContext, let currentUserID else { return }

        print("[ConversationsSync] Processing \(changes.count) changes for user: \(currentUserID)")

        do {
            for change in changes {
                print("[ConversationsSync] Change: \(change.type.rawValue) for doc: \(change.document.documentID)")
                switch change.type {
                case .added, .modified:
                    let record = try change.document.data(as: ConversationRecord.self)
                    print("[ConversationsSync] Adding/updating conversation: \(change.document.documentID)")
                    upsert(change.document.documentID, record: record, in: modelContext)
                case .removed:
                    print("[ConversationsSync] Removing conversation: \(change.document.documentID)")
                    remove(recordID: change.document.documentID, in: modelContext)
                }
            }
            do {
                try modelContext.save()
                print("[ConversationsSync] Saved changes to model context")
            } catch {
                print("[ConversationsSync] Failed to save model context: \(error)")
                throw error
            }
            onChange?()
        } catch {
            print("[ConversationsSync] Change processing failed: \(error)")
        }
    }

    private func processSnapshot(_ documents: [QueryDocumentSnapshot]) async throws {
        guard let modelContext else { return }

        for document in documents {
            let record = try document.data(as: ConversationRecord.self)
            upsert(document.documentID, record: record, in: modelContext)
        }
        do {
            try modelContext.save()
            print("[ConversationsSync] Saved snapshot changes to model context")
        } catch {
            print("[ConversationsSync] Failed to save snapshot changes: \(error)")
            throw error
        }
        onChange?()
    }

    private func upsert(_ documentID: String, record: ConversationRecord, in context: ModelContext) {
        let identifier = documentID

        print("[ConversationsSync] Upserting conversation \(identifier) with title: \(record.title ?? "nil") participants: \(record.participants)")

        let descriptor = FetchDescriptor<ConversationEntity>(
            predicate: #Predicate { $0.id == identifier }
        )

        let entity = (try? context.fetch(descriptor).first) ?? ConversationEntity(
            id: identifier,
            title: record.title,
            participantIDs: record.participants,
            type: record.type ?? .oneOnOne,
            lastMessageID: record.lastMessageID,
            lastMessagePreview: record.lastMessagePreview,
            lastMessageTimestamp: record.lastMessageTimestamp,
            unreadCount: 0
        )

        entity.title = record.title
        entity.participantIDs = record.participants
        entity.type = record.type ?? .oneOnOne
        entity.lastMessageID = record.lastMessageID
        entity.lastMessagePreview = record.lastMessagePreview
        entity.lastMessageTimestamp = record.lastMessageTimestamp

        if let userID = currentUserID,
           let unread = record.unreadCounts?[userID] {
            entity.unreadCount = unread
        } else {
            entity.unreadCount = 0
        }

        if entity.persistentModelID == nil {
            print("[ConversationsSync] Inserting new conversation entity for id \(identifier)")
            context.insert(entity)
        } else {
            print("[ConversationsSync] Updating existing conversation entity for id \(identifier)")
        }
    }

    private func remove(recordID: String?, in context: ModelContext) {
        guard let identifier = recordID else { return }

        let descriptor = FetchDescriptor<ConversationEntity>(
            predicate: #Predicate { $0.id == identifier }
        )

        if let entity = try? context.fetch(descriptor).first {
            context.delete(entity)
        }
    }
}

private struct ConversationRecord: Codable {
    var id: String?
    var title: String?
    var participants: [String]
    var typeRawValue: String?
    var lastMessageID: String?
    var lastMessagePreview: String?
    var lastMessageTimestamp: Date?
    var unreadCounts: [String: Int]?

    var type: ConversationType? {
        guard let typeRawValue else { return nil }
        return ConversationType(rawValue: typeRawValue)
    }

    init(
        id: String? = nil,
        title: String? = nil,
        participants: [String] = [],
        typeRawValue: String? = nil,
        lastMessageID: String? = nil,
        lastMessagePreview: String? = nil,
        lastMessageTimestamp: Date? = nil,
        unreadCounts: [String: Int]? = nil
    ) {
        self.id = id
        self.title = title
        self.participants = participants
        self.typeRawValue = typeRawValue
        self.lastMessageID = lastMessageID
        self.lastMessagePreview = lastMessagePreview
        self.lastMessageTimestamp = lastMessageTimestamp
        self.unreadCounts = unreadCounts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Document ID is not in the JSON, it's the document name
        id = nil

        title = try container.decodeIfPresent(String.self, forKey: .title)
        participants = try container.decode([String].self, forKey: .participants)
        typeRawValue = try container.decodeIfPresent(String.self, forKey: .typeRawValue)
        lastMessageID = try container.decodeIfPresent(String.self, forKey: .lastMessageID)
        lastMessagePreview = try container.decodeIfPresent(String.self, forKey: .lastMessagePreview)

        // Handle timestamp decoding
        if let timestamp = try? container.decodeIfPresent(Timestamp.self, forKey: .lastMessageTimestamp) {
            lastMessageTimestamp = timestamp.dateValue()
        } else {
            lastMessageTimestamp = nil
        }

        // Handle unreadCounts as [String: Int]
        if let unreadCountsMap = try? container.decodeIfPresent([String: Int].self, forKey: .unreadCounts) {
            unreadCounts = unreadCountsMap
        } else {
            unreadCounts = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case participants
        case typeRawValue = "type"
        case lastMessageID = "lastMessageID"
        case lastMessagePreview = "lastMessagePreview"
        case lastMessageTimestamp = "lastMessageTimestamp"
        case unreadCounts = "unreadCounts"
    }
}

