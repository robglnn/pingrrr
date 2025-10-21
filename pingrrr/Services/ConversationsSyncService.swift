import Foundation
import SwiftData
import FirebaseFirestore
import FirebaseFirestoreSwift

@MainActor
final class ConversationsSyncService {
    private let db = Firestore.firestore()
    private var listener: ListenerRegistration?
    private var currentUserID: String?
    private weak var modelContext: ModelContext?

    func start(for userID: String, modelContext: ModelContext) {
        stop()
        currentUserID = userID
        self.modelContext = modelContext

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
        guard let userID = currentUserID, let modelContext else { return }

        do {
            let snapshot = try await db.collection("conversations")
                .whereField("participants", arrayContains: userID)
                .getDocuments()
            try await processSnapshot(snapshot.documents)
            try modelContext.save()
        } catch {
            print("[ConversationsSync] Refresh failed: \(error)")
        }
    }

    func stop() {
        listener?.remove()
        listener = nil
        currentUserID = nil
        modelContext = nil
    }

    private func processChanges(_ changes: [DocumentChange]) async {
        guard let modelContext else { return }

        do {
            for change in changes {
                switch change.type {
                case .added, .modified:
                    let record = try change.document.data(as: ConversationRecord.self)
                    try upsert(record, in: modelContext)
                case .removed:
                    let record = try change.document.data(as: ConversationRecord.self)
                    try remove(recordID: record.id, in: modelContext)
                }
            }
            try modelContext.save()
        } catch {
            print("[ConversationsSync] Change processing failed: \(error)")
        }
    }

    private func processSnapshot(_ documents: [QueryDocumentSnapshot]) async throws {
        guard let modelContext else { return }

        for document in documents {
            let record = try document.data(as: ConversationRecord.self)
            try upsert(record, in: modelContext)
        }
    }

    private func upsert(_ record: ConversationRecord, in context: ModelContext) throws {
        guard let identifier = record.id else { return }

        let descriptor = FetchDescriptor<ConversationEntity>(
            predicate: #Predicate { $0.id == identifier },
            fetchLimit: 1
        )

        let entity = try context.fetch(descriptor).first ?? ConversationEntity(
            id: identifier,
            participantIDs: record.participants,
            type: record.type ?? .oneOnOne
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

    private func remove(recordID: String?, in context: ModelContext) throws {
        guard let identifier = recordID else { return }

        let descriptor = FetchDescriptor<ConversationEntity>(
            predicate: #Predicate { $0.id == identifier },
            fetchLimit: 1
        )

        if let entity = try context.fetch(descriptor).first {
            context.delete(entity)
        }
    }
}

private struct ConversationRecord: Codable {
    @DocumentID var id: String?
    var title: String?
    var participants: [String]
    var type: ConversationType?
    var lastMessageID: String?
    var lastMessagePreview: String?
    @ServerTimestamp var lastMessageTimestamp: Date?
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

