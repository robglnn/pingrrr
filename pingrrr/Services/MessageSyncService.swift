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
        print("[MessageSyncService] Starting for conversationID=\(conversationID), userID=\(userID)")
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
        print("[MessageSyncService] Refresh requested for conversationID=\(conversationID ?? "nil")")
        guard let conversationID, let _ = currentUserID else { return }
        let snapshot = try? await db.collection("conversations")
            .document(conversationID)
            .collection("messages")
            .order(by: "timestamp", descending: false)
            .getDocuments()
        guard let documents = snapshot?.documents else { return }
        await processSnapshot(documents)
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

        for change in changes {
            guard let record = try? change.document.data(as: MessageRecord.self) else { continue }
            switch change.type {
            case .added, .modified:
                upsert(record, changeType: change.type, isInitialLoad: false, in: modelContext)
            case .removed:
                remove(recordID: record.id, in: modelContext)
            }
        }
        try? modelContext.save()
        onChange?()
    }

    private func processSnapshot(_ documents: [QueryDocumentSnapshot]) async {
        guard let modelContext else { return }

        for document in documents {
            guard let record = try? document.data(as: MessageRecord.self) else { continue }
            upsert(record, changeType: nil, isInitialLoad: true, in: modelContext)
        }

        try? modelContext.save()
        onChange?()
    }

    private func upsert(
        _ record: MessageRecord,
        changeType: DocumentChangeType?,
        isInitialLoad: Bool,
        in context: ModelContext
    ) {
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
                isLocalOnly: false,
                retryCount: 0,
                nextRetryTimestamp: nil
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
        entity.retryCount = 0
        entity.nextRetryTimestamp = nil

        updateStatus(for: entity, record: record)

        updateConversationMetadata(with: record, changeType: changeType, isInitialLoad: isInitialLoad, in: context)
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

    private func updateConversationMetadata(
        with record: MessageRecord,
        changeType: DocumentChangeType?,
        isInitialLoad: Bool,
        in context: ModelContext
    ) {
        guard let conversationID = record.conversationID ?? conversationID else { return }

        let descriptor = FetchDescriptor<ConversationEntity>(
            predicate: #Predicate { $0.id == conversationID }
        )

        guard let conversation = try? context.fetch(descriptor).first else { return }

        if let content = record.content {
            conversation.lastMessagePreview = content
        }
        if let timestamp = record.timestamp {
            conversation.lastMessageTimestamp = timestamp
        }

        guard !isInitialLoad else { return }

        if changeType == .added,
           let currentUserID = currentUserID,
           let unreadCounts = record.unreadCounts {
            conversation.unreadCount = unreadCounts[currentUserID] ?? conversation.unreadCount
        }
    }

    private func updateStatus(for entity: MessageEntity, record: MessageRecord) {
        guard let conversationID = record.conversationID ?? conversationID else { return }
        guard let modelContext else { return }

        let descriptor = FetchDescriptor<ConversationEntity>(
            predicate: #Predicate { $0.id == conversationID }
        )

        guard let conversation = try? modelContext.fetch(descriptor).first else { return }
        let participants = conversation.participantIDs
        guard !participants.isEmpty else { return }

        let senderID = entity.senderID
        let recipients = participants.filter { $0 != senderID }
        guard !recipients.isEmpty else { return }

        let readBy = Set(entity.readBy)
        let delivered = recipients.contains { readBy.contains($0) }
        let allRead = recipients.allSatisfy { readBy.contains($0) }

        if allRead {
            entity.status = .read
        } else if delivered {
            entity.status = .delivered
        } else if entity.status == .sending {
            entity.status = .sent
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
    var unreadCounts: [String: Int]?

    enum CodingKeys: String, CodingKey {
        case id
        case conversationID
        case senderID
        case content
        case translatedContent
        case timestamp
        case status
        case readBy
        case unreadCounts
    }

    init(
        id: String? = nil,
        conversationID: String? = nil,
        senderID: String? = nil,
        content: String? = nil,
        translatedContent: String? = nil,
        timestamp: Date? = nil,
        status: MessageStatus? = nil,
        readBy: [String]? = nil,
        unreadCounts: [String: Int]? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.senderID = senderID
        self.content = content
        self.translatedContent = translatedContent
        self.timestamp = timestamp
        self.status = status
        self.readBy = readBy
        self.unreadCounts = unreadCounts
    }
}
