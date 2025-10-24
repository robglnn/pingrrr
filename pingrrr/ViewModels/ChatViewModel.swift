import Foundation
import Combine
import SwiftData
import FirebaseFirestore

@MainActor
final class ChatViewModel: ObservableObject {
    @Published private(set) var messages: [MessageEntity] = []
    @Published private(set) var displayItems: [MessageDisplayItem] = []
    @Published private(set) var isSending = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isTyping = false

    @Published var draftMessage: String = ""

    private let appServices: AppServices
    private let messageSyncService = MessageSyncService()
    private let typingIndicatorService = TypingIndicatorService()
    private let typingTimeout: TimeInterval = 3
    private let groupingWindow: TimeInterval = 180
    private var typingTimeoutWorkItem: DispatchWorkItem?
    private let modelContext: ModelContext
    private let conversationID: String
    private let currentUserID: String
    private var conversation: ConversationEntity?
    private let profileService = ProfileService()
    private var userProfiles: [String: UserProfile] = [:]
    private var attemptedProfileFetches: Set<String> = []
    private var outgoingQueue: OutgoingMessageQueue {
        appServices.outgoingMessageQueue
    }
    private var presenceService: PresenceService {
        appServices.presenceService
    }
    @Published private(set) var presenceSnapshot: PresenceService.Snapshot?

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
        print("[ChatViewModel] start conversationID=\(conversationID)")
        NotificationService.shared.setCurrentChatID(conversationID)
        messageSyncService.start(
            conversationID: conversationID,
            userID: currentUserID,
            modelContext: modelContext
        ) { [weak self] in
            guard let self else { return }
            print("[ChatViewModel] Message sync emitted change for \(self.conversationID)")
            self.loadCachedMessages()
        }

        typingIndicatorService.startMonitoring(
            conversationID: conversationID,
            currentUserID: currentUserID
        ) { [weak self] usersTyping in
            guard let self else { return }
            self.isTyping = !usersTyping.isEmpty
        }

        observePresence()
    }

    func stop() {
        messageSyncService.stop()
        typingIndicatorService.stop()
        typingTimeoutWorkItem?.cancel()
        typingTimeoutWorkItem = nil
        NotificationService.shared.clearCurrentChatID()
        removePresenceObservers()
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

        typingIndicatorService.setTyping(false)
        typingTimeoutWorkItem?.cancel()
        typingTimeoutWorkItem = nil

        let optimisticMessage = MessageEntity(
            id: tempID,
            conversationID: conversationID,
            senderID: currentUserID,
            content: trimmed,
            timestamp: now,
            status: .sending,
            readBy: [currentUserID],
            isLocalOnly: true,
            retryCount: 0,
            nextRetryTimestamp: nil
        )

        modelContext.insert(optimisticMessage)
        messages.append(optimisticMessage)
        regroupMessages()
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
            optimisticMessage.retryCount = 0
            optimisticMessage.nextRetryTimestamp = nil
            try modelContext.save()
        } catch {
            errorMessage = error.localizedDescription
            outgoingQueue.enqueueRetry(for: optimisticMessage)
        }
    }

    func retrySendingMessage(_ message: MessageEntity) async {
        guard message.status == .failed || message.isLocalOnly else { return }
        outgoingQueue.enqueueRetry(for: message)
        await resend(message)
    }

    private func resend(_ message: MessageEntity) async {
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
            message.retryCount = 0
            message.nextRetryTimestamp = nil
            try modelContext.save()
        } catch {
            errorMessage = error.localizedDescription
            outgoingQueue.enqueueRetry(for: message)
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
        scheduleTypingTimeout()
    }

    func userStoppedTyping() {
        typingTimeoutWorkItem?.cancel()
        typingTimeoutWorkItem = nil
        typingIndicatorService.setTyping(false)
        NotificationService.shared.markChatAsRecentlyActive(conversationID)
    }

    func userStartedViewingChat() {
        NotificationService.shared.setCurrentChatID(conversationID)
    }

    func userLeftChat() {
        NotificationService.shared.clearCurrentChatID()
    }

    func loadCachedMessages() {
        print("[ChatViewModel] loadCachedMessages conversationID=\(conversationID)")
        let descriptor = FetchDescriptor<MessageEntity>(
            predicate: #Predicate { $0.conversationID == conversationID },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        messages = (try? modelContext.fetch(descriptor)) ?? []
        regroupMessages()
        refreshConversationReference()
    }

    private func refreshConversationReference() {
        let descriptor = FetchDescriptor<ConversationEntity>(
            predicate: #Predicate { $0.id == conversationID },
            sortBy: []
        )
        if let fetched = try? modelContext.fetch(descriptor).first {
            conversation = fetched
            print("[ChatViewModel] refreshed conversation reference: \(fetched)")
            observePresence()
        } else {
            print("[ChatViewModel] No conversation entity found locally for \(conversationID)")
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

    private func scheduleTypingTimeout() {
        typingTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.typingIndicatorService.setTyping(false)
            self.typingTimeoutWorkItem = nil
        }
        typingTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + typingTimeout, execute: workItem)
    }

    private func observePresence() {
        guard let conversation else {
            print("[ChatViewModel] observePresence missing conversation")
            return
        }
        let participants = conversation.participantIDs.filter { $0 != currentUserID }
        guard !participants.isEmpty else {
            presenceSnapshot = nil
            removePresenceObservers()
            return
        }

        print("[ChatViewModel] observePresence participants=\(participants)")
        presenceService.observe(userIDs: participants)
        presenceSnapshot = presenceSnapshot(for: participants)
    }

    private func presenceSnapshot(for participants: [String]) -> PresenceService.Snapshot? {
        guard !participants.isEmpty else { return nil }

        var latestSnapshot: PresenceService.Snapshot?
        for participant in participants {
            guard let snapshot = presenceService.snapshot(for: participant) else { continue }
            if snapshot.isOnline {
                return PresenceService.Snapshot(isOnline: true, lastSeen: snapshot.lastSeen)
            }

            if let lastSeen = snapshot.lastSeen {
                if latestSnapshot?.lastSeen == nil || (latestSnapshot?.lastSeen ?? .distantPast) < lastSeen {
                    latestSnapshot = PresenceService.Snapshot(isOnline: false, lastSeen: lastSeen)
                }
            } else if latestSnapshot == nil {
                latestSnapshot = snapshot
            }
        }

        return latestSnapshot
    }

    private func removePresenceObservers() {
        guard let conversation else { return }
        conversation.participantIDs
            .filter { $0 != currentUserID }
            .forEach { presenceService.removeObserver(for: $0) }
    }

    private func regroupMessages() {
        guard !messages.isEmpty else {
            displayItems = []
            return
        }

        let sorted = messages.sorted { $0.timestamp < $1.timestamp }

        var newItems: [MessageDisplayItem] = []
        var currentGroup: [MessageEntity] = []
        var missingProfiles: Set<String> = []

        func flushCurrentGroup() {
            guard !currentGroup.isEmpty else { return }
            let qualifiesForChain = currentGroup.count >= 3

            for (index, message) in currentGroup.enumerated() {
                let isCurrentUser = message.senderID == currentUserID
                var showName = false
                var showAvatar = false

                if !isCurrentUser {
                    if qualifiesForChain {
                        showName = index == 0
                        showAvatar = index == 0
                    } else {
                        showName = true
                        showAvatar = true
                    }

                    if userProfiles[message.senderID] == nil {
                        missingProfiles.insert(message.senderID)
                    }
                }

                newItems.append(
                    MessageDisplayItem(
                        id: message.id,
                        message: message,
                        showSenderName: showName,
                        showAvatar: showAvatar,
                        senderProfile: userProfiles[message.senderID],
                        isCurrentUser: isCurrentUser
                    )
                )
            }

            currentGroup.removeAll(keepingCapacity: true)
        }

        for message in sorted {
            if let last = currentGroup.last,
               last.senderID == message.senderID,
               message.timestamp.timeIntervalSince(last.timestamp) <= groupingWindow {
                currentGroup.append(message)
            } else {
                flushCurrentGroup()
                currentGroup = [message]
            }
        }

        flushCurrentGroup()

        displayItems = newItems

        if !missingProfiles.isEmpty {
            loadProfilesIfNeeded(for: missingProfiles)
        }
    }

    private func loadProfilesIfNeeded(for userIDs: Set<String>) {
        let toFetch = userIDs.subtracting(attemptedProfileFetches)
        guard !toFetch.isEmpty else { return }

        attemptedProfileFetches.formUnion(toFetch)

        Task { @MainActor [weak self] in
            guard let self else { return }

            for id in toFetch {
                do {
                    let profile = try await profileService.fetchUserProfile(userID: id)
                    userProfiles[id] = profile
                } catch {
                    print("[ChatViewModel] Failed to load profile for \(id): \(error)")
                }
            }

            regroupMessages()
        }
    }

    func cachedProfile(for userID: String) -> UserProfile? {
        userProfiles[userID]
    }

    struct MessageDisplayItem: Identifiable {
        let id: String
        let message: MessageEntity
        let showSenderName: Bool
        let showAvatar: Bool
        let senderProfile: UserProfile?
        let isCurrentUser: Bool
    }
}

