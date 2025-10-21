import Foundation
import SwiftData
import FirebaseFirestore

@MainActor
final class MessageSyncService {
    private let db = Firestore.firestore()
    private var listener: ListenerRegistration?
    private weak var modelContext: ModelContext?
    private var onChange: (() -> Void)?
    private var conversationID: String?
    private var currentUserID: String?

    func start(
        conversationID: String,
        userID: String,
        modelContext: ModelContext,
        onChange: @escaping () -> Void
    ) {
        stop()
        self.conversationID = conversationID
        self.currentUserID = userID
        self.modelContext = modelContext
        self.onChange = onChange

        listener = db.collection("conversations")
            .document(conversationID)
            .collection("messages")
            .order(by: "timestamp", descending: false)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }

                if let error {
                    print("[MessageSync] Snapshot error: \(error)")
                    return
                }

                guard let snapshot else { return }

                Task { @MainActor in
                    await self.processChanges(snapshot.documentChanges)
                }
            }
    }

    func refresh() async {
        guard let conversationID, let _ = currentUserID else { return }
        do {
            let snapshot = try await db.collection("conversations")
                .document(conversationID)
                .collection("messages")
                .order(by: "timestamp", descending: false)
                .getDocuments()
            try await processSnapshot(snapshot.documents)
        } catch {
            print("[MessageSync] Refresh failed: \(error)")
        }
    }

    func stop() {
        listener?.remove()
        listener = nil
        modelContext = nil
        onChange = nil
        conversationID = nil
        currentUserID = nil
    }

    private func processChanges(_ changes: [DocumentChange]) async {
        guard let modelContext else { return }

        do {
            for change in changes {
                let record = try change.document.data(as: MessageRecord.self)
                switch change.type {
                case .added, .modified:
                    upsert(record, in: modelContext)
                case .removed:
                    remove(recordID: record.id, in: modelContext)
                }
            }
            try modelContext.save()
            onChange?()
        } catch {
            print("[MessageSync] Change processing failed: \(error)")
        }
    }

    private func processSnapshot(_ documents: [QueryDocumentSnapshot]) async throws {
        guard let modelContext else { return }

        for document in documents {
            let record = try document.data(as: MessageRecord.self)
            upsert(record, in: modelContext)
        }

        try modelContext.save()
        onChange?()
    }

    private func upsert(_ record: MessageRecord, in context: ModelContext) {
        guard let identifier = record.id else { return }

        let descriptor = FetchDescriptor<MessageEntity>(
            predicate: #Predicate { $0.id == identifier }
        )

        let entity: MessageEntity
        if let existing = try? context.fetch(descriptor).first {
            entity = existing
        } else {
            entity = MessageEntity(
                id: identifier,
                conversationID: record.conversationID ?? conversationID ?? "",
                senderID: record.senderID ?? "",
                content: record.content ?? "",
                translatedContent: record.translatedContent,
                timestamp: record.timestamp ?? Date(),
                status: record.status ?? .sent,
                readBy: record.readBy ?? [],
                isLocalOnly: false
            )
            context.insert(entity)
        }

        if let conversationID = record.conversationID {
            entity.conversationID = conversationID
        }

        if let senderID = record.senderID {
            entity.senderID = senderID
        }

        if let content = record.content {
            entity.content = content
        }

        entity.translatedContent = record.translatedContent

        if let timestamp = record.timestamp {
            entity.timestamp = timestamp
        }

        if let status = record.status {
            entity.status = status
        }

        if let readBy = record.readBy {
            entity.readBy = readBy
        }

        entity.isLocalOnly = false
    }

    private func remove(recordID: String?, in context: ModelContext) {
        guard let identifier = recordID else { return }
        let descriptor = FetchDescriptor<MessageEntity>(
            predicate: #Predicate { $0.id == identifier }
        )
        if let entity = try? context.fetch(descriptor).first {
            context.delete(entity)
        }
    }
}

private struct MessageRecord: Codable {
    var id: String?
    var conversationID: String?
    var senderID: String?
    var content: String?
    var translatedContent: String?
    var timestamp: Date?
    var status: MessageStatus?
    var readBy: [String]?

    enum CodingKeys: String, CodingKey {
        case id
        case conversationID
        case senderID
        case content
        case translatedContent
        case timestamp
        case status
        case readBy
    }

    init(
        id: String? = nil,
        conversationID: String? = nil,
        senderID: String? = nil,
        content: String? = nil,
        translatedContent: String? = nil,
        timestamp: Date? = nil,
        status: MessageStatus? = nil,
        readBy: [String]? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.senderID = senderID
        self.content = content
        self.translatedContent = translatedContent
        self.timestamp = timestamp
        self.status = status
        self.readBy = readBy
    }
}

