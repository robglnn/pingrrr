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

        var decodedRecords: [(MessageRecord, DocumentChangeType?)] = []

        for change in changes {
            guard let record = try? change.document.data(as: MessageRecord.self) else { continue }
            decodedRecords.append((record, change.type))
        }

        for (record, changeType) in decodedRecords {
            upsert(record, changeType: changeType, isInitialLoad: false, in: modelContext)
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
                readTimestamps: record.readTimestamps ?? [:],
                isLocalOnly: false,
                retryCount: 0,
                nextRetryTimestamp: nil,
                mediaURL: record.mediaURL,
                mediaType: record.mediaType.flatMap(MessageMediaType.init(rawValue:)),
                voiceDurationSeconds: record.voiceDuration
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
        entity.mediaURL = record.mediaURL
        if let mediaType = record.mediaType.flatMap(MessageMediaType.init(rawValue:)) {
            entity.mediaType = mediaType
        } else {
            entity.mediaType = nil
        }
        entity.voiceDuration = record.voiceDuration

        if let timestamp = record.timestamp {
            entity.timestamp = timestamp
        }

        if let status = record.status {
            entity.status = status
        }

        if let readBy = record.readBy {
            entity.readBy = readBy
        }

        if let readTimestamps = record.readTimestamps {
            entity.readTimestamps = readTimestamps
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

        if let mediaType = record.mediaType.flatMap(MessageMediaType.init(rawValue:)) {
            conversation.lastMessagePreview = mediaType.previewText
        } else if let content = record.content {
            conversation.lastMessagePreview = content
        }
        if let timestamp = record.timestamp {
            conversation.lastMessageTimestamp = timestamp
        }

        guard !isInitialLoad else { return }

        if changeType == .added,
           let currentUserID,
           let senderID = record.senderID,
           senderID != currentUserID,
           let preview = record.content,
           !preview.isEmpty,
           let conversation = try? context.fetch(
               FetchDescriptor<ConversationEntity>(predicate: #Predicate { $0.id == conversationID })
           ).first {
            Task {
                let senderName = await resolveDisplayName(for: senderID, in: context) ?? "New message"
                await MainActor.run {
                    NotificationService.shared.showForegroundNotification(
                        message: preview,
                        conversationID: conversationID,
                        conversationTitle: conversation.title,
                        senderName: senderName
                    )
                }
            }
        }

        if changeType == .added,
           let currentUserID = currentUserID,
           let unreadCounts = record.unreadCounts,
           let conversation = try? context.fetch(
               FetchDescriptor<ConversationEntity>(predicate: #Predicate { $0.id == conversationID })
           ).first {
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

    private func senderDisplayName(for userID: String) -> String? {
        guard let modelContext else { return nil }
        let descriptor = FetchDescriptor<UserEntity>(
            predicate: #Predicate { $0.id == userID }
        )
        return try? modelContext.fetch(descriptor).first?.displayName
    }

    private func resolveDisplayName(for userID: String, in context: ModelContext) async -> String? {
        if let cached = senderDisplayName(for: userID) {
            return cached
        }

        do {
            let snapshot = try await db.collection("users").document(userID).getDocument()
            guard let data = snapshot.data() else {
                print("[MessageSync] No profile data for user \(userID)")
                return nil
            }
            let displayName = data["displayName"] as? String
            if let displayName {
                let photoURL = data["profilePictureURL"] as? String
                let photoVersion = (data["photoVersion"] as? NSNumber)?.intValue ?? 0
                cacheUser(
                    userID: userID,
                    displayName: displayName,
                    email: (data["email"] as? String) ?? "",
                    profilePictureURL: photoURL,
                    photoVersion: photoVersion,
                    in: context
                )
            }
            return displayName
        } catch {
            print("[MessageSync] Failed to fetch sender display name: \(error)")
            return nil
        }
    }

    private func cacheUser(
        userID: String,
        displayName: String,
        email: String,
        profilePictureURL: String?,
        photoVersion: Int,
        in context: ModelContext
    ) {
        let descriptor = FetchDescriptor<UserEntity>(
            predicate: #Predicate { $0.id == userID }
        )

        if let existing = try? context.fetch(descriptor).first {
            let previousVersion = existing.photoVersion
            existing.displayName = displayName
            existing.email = email
            existing.profilePictureURL = profilePictureURL
            existing.photoVersion = photoVersion
            if previousVersion != Optional(photoVersion) {
                Task { await ProfileImageCache.shared.invalidate(userID: userID, photoVersion: previousVersion) }
            }
        } else {
            let user = UserEntity(
                id: userID,
                displayName: displayName,
                email: email,
                profilePictureURL: profilePictureURL,
                photoVersion: photoVersion
            )
            context.insert(user)
        }

        try? context.save()
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
    var readTimestamps: [String: Date]?
    var unreadCounts: [String: Int]?
    var mediaURL: String?
    var mediaType: String?
    var voiceDuration: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case conversationID
        case senderID
        case content
        case translatedContent
        case timestamp
        case status
        case readBy
        case readTimestamps
        case unreadCounts
        case mediaURL
        case mediaType
        case voiceDuration
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
        readTimestamps: [String: Date]? = nil,
        unreadCounts: [String: Int]? = nil,
        mediaURL: String? = nil,
        mediaType: MessageMediaType? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.senderID = senderID
        self.content = content
        self.translatedContent = translatedContent
        self.timestamp = timestamp
        self.status = status
        self.readBy = readBy
        self.readTimestamps = readTimestamps
        self.unreadCounts = unreadCounts
        self.mediaURL = mediaURL
        self.mediaType = mediaType?.rawValue
    }
}
