import Foundation
import SwiftData
import FirebaseFirestore

@MainActor
final class ChatViewModel: ObservableObject {
    @Published private(set) var messages: [MessageEntity] = []
    @Published private(set) var isSending = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isTyping = false

    @Published var draftMessage: String = ""

    private let appServices: AppServices
    private let messageSyncService = MessageSyncService()
    private let typingIndicatorService = TypingIndicatorService()
    private let modelContext: ModelContext
    private let conversationID: String
    private let currentUserID: String
    private var conversation: ConversationEntity?

    init(
        conversation: ConversationEntity,
        currentUserID: String,
        modelContext: ModelContext,
        appServices: AppServices
    ) {
        self.conversationID = conversation.id
        self.currentUserID = currentUserID
        self.modelContext = modelContext
        self.appServices = appServices
        self.conversation = conversation
        loadCachedMessages()
        refreshConversationReference()
    }

    func start() {
        messageSyncService.start(
            conversationID: conversationID,
            userID: currentUserID,
            modelContext: modelContext
        ) { [weak self] in
            self?.loadCachedMessages()
        }

        typingIndicatorService.startMonitoring(
            conversationID: conversationID,
            currentUserID: currentUserID
        ) { [weak self] usersTyping in
            guard let self else { return }
            self.isTyping = !usersTyping.filter { $0 != self.currentUserID }.isEmpty
        }
    }

    func stop() {
        messageSyncService.stop()
        typingIndicatorService.stop()
    }

    func refresh() async {
        await messageSyncService.refresh()
        loadCachedMessages()
    }

    func sendMessage() async {
        let trimmed = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let tempID = UUID().uuidString
        let now = Date()

        let optimisticMessage = MessageEntity(
            id: tempID,
            conversationID: conversationID,
            senderID: currentUserID,
            content: trimmed,
            timestamp: now,
            status: .sending,
            readBy: [currentUserID],
            isLocalOnly: true
        )

        modelContext.insert(optimisticMessage)
        messages.append(optimisticMessage)
        draftMessage = ""

        updateConversationForOutgoingMessage(content: trimmed, timestamp: now, messageID: tempID)

        let messageData: [String: Any] = [
            "id": tempID,
            "conversationID": conversationID,
            "senderID": currentUserID,
            "content": trimmed,
            "timestamp": now,
            "status": MessageStatus.sent.rawValue,
            "readBy": [currentUserID]
        ]

        let docRef = Firestore.firestore()
            .collection("conversations")
            .document(conversationID)
            .collection("messages")
            .document(tempID)

        do {
            try await docRef.setData(messageData)
            optimisticMessage.status = .sent
            optimisticMessage.isLocalOnly = false
            try modelContext.save()
        } catch {
            optimisticMessage.status = .failed
            errorMessage = error.localizedDescription
        }
    }

    func retrySendingMessage(_ message: MessageEntity) async {
        guard message.status == .failed else { return }
        let docRef = Firestore.firestore()
            .collection("conversations")
            .document(conversationID)
            .collection("messages")
            .document(message.id)

        let data: [String: Any] = [
            "id": message.id,
            "conversationID": conversationID,
            "senderID": currentUserID,
            "content": message.content,
            "timestamp": message.timestamp,
            "status": MessageStatus.sent.rawValue,
            "readBy": message.readBy
        ]

        do {
            try await docRef.setData(data)
            message.status = .sent
            message.isLocalOnly = false
            try modelContext.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func markMessagesAsRead() async {
        let unreadMessages = messages.filter { !$0.readBy.contains(currentUserID) }
        guard !unreadMessages.isEmpty else { return }

        let batch = Firestore.firestore().batch()
        let conversationRef = Firestore.firestore()
            .collection("conversations")
            .document(conversationID)

        for message in unreadMessages {
            let messageRef = conversationRef.collection("messages").document(message.id)
            batch.updateData([
                "readBy": FieldValue.arrayUnion([currentUserID])
            ], forDocument: messageRef)
            message.readBy.append(currentUserID)
            message.status = .read
        }

        do {
            try await batch.commit()
            try modelContext.save()
        } catch {
            errorMessage = error.localizedDescription
        }

        conversation?.unreadCount = 0
        try? modelContext.save()
    }

    func userStartedTyping() {
        typingIndicatorService.setTyping(true)
    }

    func userStoppedTyping() {
        typingIndicatorService.setTyping(false)
    }

    func loadCachedMessages() {
        let descriptor = FetchDescriptor<MessageEntity>(
            predicate: #Predicate { $0.conversationID == conversationID },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        messages = (try? modelContext.fetch(descriptor)) ?? []
        refreshConversationReference()
    }

    private func refreshConversationReference() {
        let descriptor = FetchDescriptor<ConversationEntity>(
            predicate: #Predicate { $0.id == conversationID },
            fetchLimit: 1
        )
        if let fetched = try? modelContext.fetch(descriptor).first {
            conversation = fetched
        }
    }

    private func updateConversationForOutgoingMessage(content: String, timestamp: Date, messageID: String) {
        guard let conversation else { return }
        conversation.lastMessagePreview = content
        conversation.lastMessageTimestamp = timestamp
        conversation.lastMessageID = messageID
        conversation.unreadCount = 0
        try? modelContext.save()
    }
}

