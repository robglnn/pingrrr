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

        listener = db.collection("conversations")
            .whereField("participants", arrayContains: userID)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }

                if let error {
                    print("[ConversationsSync] Snapshot error: \(error)")
                    return
                }

                guard let snapshot else { return }

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
        guard let modelContext else { return }

        do {
            for change in changes {
                switch change.type {
                case .added, .modified:
                    let record = try change.document.data(as: ConversationRecord.self)
                    upsert(record, in: modelContext)
                case .removed:
                    let record = try change.document.data(as: ConversationRecord.self)
                    remove(recordID: record.id, in: modelContext)
                }
            }
            try modelContext.save()
            onChange?()
        } catch {
            print("[ConversationsSync] Change processing failed: \(error)")
        }
    }

    private func processSnapshot(_ documents: [QueryDocumentSnapshot]) async throws {
        guard let modelContext else { return }

        for document in documents {
            let record = try document.data(as: ConversationRecord.self)
            upsert(record, in: modelContext)
        }
        try modelContext.save()
        onChange?()
    }

    private func upsert(_ record: ConversationRecord, in context: ModelContext) {
        guard let identifier = record.id else { return }

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
            context.insert(entity)
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
    var type: ConversationType?
    var lastMessageID: String?
    var lastMessagePreview: String?
    var lastMessageTimestamp: Date?
    var unreadCounts: [String: Int]?

    init(
        id: String? = nil,
        title: String? = nil,
        participants: [String] = [],
        type: ConversationType? = nil,
        lastMessageID: String? = nil,
        lastMessagePreview: String? = nil,
        lastMessageTimestamp: Date? = nil,
        unreadCounts: [String: Int]? = nil
    ) {
        self.id = id
        self.title = title
        self.participants = participants
        self.type = type
        self.lastMessageID = lastMessageID
        self.lastMessagePreview = lastMessagePreview
        self.lastMessageTimestamp = lastMessageTimestamp
        self.unreadCounts = unreadCounts
    }
}

