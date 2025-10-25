import Foundation
import Combine
import SwiftData
import FirebaseFirestore
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class ChatViewModel: ObservableObject {
    @Published private(set) var messages: [MessageEntity] = []
    @Published private(set) var displayItems: [MessageDisplayItem] = []
    @Published private(set) var readReceiptProfiles: [String: UserProfile] = [:]
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
    private var userProfiles: [String: UserProfile] = [:]
    private var attemptedProfileFetches: Set<String> = []
    private var profileService: ProfileService {
        appServices.profileService
    }

    private var voiceService: VoiceMessageService {
        appServices.voiceMessageService
    }

    private var aiPreferences: AIPreferences {
        AIPreferencesService.shared.preferences
    }

    private var outgoingQueue: OutgoingMessageQueue {
        appServices.outgoingMessageQueue
    }

    private var presenceService: PresenceService {
        appServices.presenceService
    }

    @Published private(set) var isVoiceRecording = false
    @Published private(set) var voiceRecordingDuration: TimeInterval = 0
    @Published private(set) var hasShownVoiceWarning = false
    @Published private(set) var pendingMedia: PendingMedia?
    @Published private(set) var presenceSnapshot: PresenceService.Snapshot?
    @Published private(set) var isAIProcessingTranslation = false

    private var translationCache: [String: String] = [:]
    private var translationVisibility: [String: Bool] = [:]
    private var aiProcessingFlag = false

    var aiIsProcessingTranslation: Bool {
        isAIProcessingTranslation
    }

    private var cancellables: Set<AnyCancellable> = []

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

        voiceService.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] isRecording in
                self?.isVoiceRecording = isRecording
            }
            .store(in: &cancellables)

        voiceService.$recordingDuration
            .receive(on: RunLoop.main)
            .sink { [weak self] duration in
                self?.voiceRecordingDuration = duration
            }
            .store(in: &cancellables)

        voiceService.onAutoStop = { [weak self] in
            Task { await self?.handleAutoStopRecording() }
        }
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

        let request = MessageRequest.text(trimmed)
        await send(request: request)
        draftMessage = ""
    }

    func toggleInlineTranslation() async {
        guard let lastMessage = messages.last else { return }
        await toggleTranslation(for: lastMessage)
    }

    func toggleTranslation(for messageID: String?) async {
        guard let messageID,
              let message = messages.first(where: { $0.id == messageID }) else {
            return
        }
        await toggleTranslation(for: message)
    }

    var lastMessageID: String? {
        messages.last?.id
    }

    private func toggleTranslation(for message: MessageEntity) async {
        if translationVisibility[message.id] == true {
            translationVisibility[message.id] = false
            message.translatedContent = nil
            regroupMessages()
            return
        }

        guard !aiProcessingFlag else { return }
        aiProcessingFlag = true
        isAIProcessingTranslation = true
        defer {
            aiProcessingFlag = false
            isAIProcessingTranslation = false
        }

        if let cached = translationCache[message.id] {
            message.translatedContent = cached
            translationVisibility[message.id] = true
            regroupMessages()
            return
        }

        do {
            let translated = try await AIService.shared.translate(
                text: message.content,
                targetLang: aiPreferences.primaryLanguage,
                formality: aiPreferences.defaultFormality
            )
            translationCache[message.id] = translated
            message.translatedContent = translated
            translationVisibility[message.id] = true
            regroupMessages()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    struct PendingMedia {
        enum State {
            case ready
            case uploading
        }

        var data: Data
        var type: MessageMediaType
        var thumbnailData: Data?
        var state: State
        var duration: TimeInterval?

        mutating func markUploading() {
            state = .uploading
        }
    }

    func enqueuePendingMedia(data: Data, type: MessageMediaType, duration: TimeInterval? = nil) async {
        let thumbnailData: Data?

        if type == .image {
            thumbnailData = data
        } else {
            thumbnailData = nil
        }

        await MainActor.run {
            pendingMedia = PendingMedia(data: data, type: type, thumbnailData: thumbnailData, state: .ready, duration: duration)
        }
    }

    func clearPendingMedia() {
        pendingMedia = nil
    }

    func sendPendingMedia() async {
        guard var pending = pendingMedia else { return }
        pending.markUploading()
        await MainActor.run { self.pendingMedia = pending }

        let request = MessageRequest.media(data: pending.data, mediaType: pending.type, duration: pending.duration)
        await send(request: request)
        await MainActor.run { self.pendingMedia = nil }
    }

    enum MessageRequest {
        case text(String)
        case media(data: Data, mediaType: MessageMediaType, duration: TimeInterval?)

        var previewText: String {
            switch self {
            case let .text(text):
                return text
            case let .media(_, mediaType, _):
                return mediaType.previewText
            }
        }
    }

    private func uploadMedia(data: Data, mediaType: MessageMediaType, conversationID: String) async throws -> String {
        return try await appServices.mediaService.upload(media: data, type: mediaType, conversationID: conversationID)
    }

    func retrySendingMessage(_ message: MessageEntity) async {
        guard message.status == .failed || message.isLocalOnly else { return }
        outgoingQueue.enqueueRetry(for: message)
        await resend(message)
    }

    private func resend(_ message: MessageEntity) async {
        guard let payload = createPayload(for: message) else { return }

        let docRef = Firestore.firestore()
            .collection("conversations")
            .document(conversationID)
            .collection("messages")
            .document(message.id)

        do {
            try await docRef.setData(payload)
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

    private func send(request: MessageRequest) async {
        guard let conversation else { return }

        let tempID = UUID().uuidString
        let now = Date()

        typingIndicatorService.setTyping(false)
        typingTimeoutWorkItem?.cancel()
        typingTimeoutWorkItem = nil

        let optimisticContent = request.previewText
        var optimisticMediaURL: String? = nil
        var optimisticMediaType: MessageMediaType? = nil
        var optimisticDuration: TimeInterval? = nil

        if case let .media(data, mediaType, duration) = request {
            optimisticDuration = duration
            do {
                let uploadedURL = try await uploadMedia(data: data, mediaType: mediaType, conversationID: conversation.id)
                optimisticMediaURL = uploadedURL
                optimisticMediaType = mediaType
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }

        let optimisticMessage = MessageEntity(
            id: tempID,
            conversationID: conversationID,
            senderID: currentUserID,
            content: optimisticContent,
            translatedContent: nil,
            timestamp: now,
            status: .sending,
            readBy: [currentUserID],
            isLocalOnly: true,
            retryCount: 0,
            nextRetryTimestamp: nil,
            mediaURL: optimisticMediaURL,
            mediaType: optimisticMediaType
        )
        optimisticMessage.voiceDuration = optimisticDuration

        modelContext.insert(optimisticMessage)
        messages.append(optimisticMessage)
        regroupMessages()
        updateReadReceiptProfiles()

        updateConversationForOutgoingMessage(content: optimisticContent, timestamp: now, messageID: tempID)

        sendToFirestore(optimisticMessage)
    }

    private func createPayload(for message: MessageEntity) -> [String: Any]? {
        var payload: [String: Any] = [
            "id": message.id,
            "conversationID": message.conversationID,
            "senderID": message.senderID,
            "content": message.content,
            "timestamp": message.timestamp,
            "status": MessageStatus.sent.rawValue,
            "readBy": message.readBy
        ]

        if let mediaURL = message.mediaURL {
            payload["mediaURL"] = mediaURL
            payload["mediaType"] = message.mediaType?.rawValue
            if let duration = message.voiceDuration {
                payload["voiceDuration"] = duration
            }
        }

        return payload
    }

    private func sendToFirestore(_ message: MessageEntity) {
        guard let payload = createPayload(for: message) else {
            errorMessage = "Unable to create message payload"
            return
        }

        let docRef = Firestore.firestore()
            .collection("conversations")
            .document(conversationID)
            .collection("messages")
            .document(message.id)

        Task {
            do {
                try await docRef.setData(payload)
                message.status = .sent
                message.isLocalOnly = false
                message.retryCount = 0
                message.nextRetryTimestamp = nil
                try modelContext.save()
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.outgoingQueue.enqueueRetry(for: message)
                }
            }
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
        updateReadReceiptProfiles()
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
                        isCurrentUser: isCurrentUser,
                        showTranslation: translationVisibility[message.id] == true
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
            updateReadReceiptProfiles()
        }
    }

    func cachedProfile(for userID: String) -> UserProfile? {
        userProfiles[userID]
    }

    private func updateReadReceiptProfiles() {
        var map: [String: UserProfile] = [:]
        for message in messages {
            for userID in message.readBy where map[userID] == nil {
                if let cached = userProfiles[userID] {
                    map[userID] = cached
                } else {
                    attemptedProfileFetches.insert(userID)
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        do {
                            let profile = try await self.profileService.fetchUserProfile(userID: userID)
                            self.userProfiles[userID] = profile
                            self.readReceiptProfiles[userID] = profile
                        } catch {
                            print("[ChatViewModel] Failed to fetch read receipt profile for \(userID): \(error)")
                        }
                    }
                }
            }
        }
        readReceiptProfiles = map
    }

    func loadMediaData(from urlString: String, type: MessageMediaType) async throws -> Data {
        try await appServices.mediaService.downloadMedia(at: urlString, type: type)
    }

    func thumbnailImage(for pending: PendingMedia) -> UIImage? {
#if canImport(UIKit)
        guard pending.type == .image, let data = pending.thumbnailData else { return nil }
        return UIImage(data: data)
#else
        return nil
#endif
    }

    // Voice recording helpers
    func startVoiceRecording() async {
        do {
            try await voiceService.startRecording()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopVoiceRecording() async -> Bool {
        do {
            let result = try await voiceService.stopRecording()
            let data = try Data(contentsOf: result.url)
            try? FileManager.default.removeItem(at: result.url)
            await enqueuePendingMedia(data: data, type: .voice, duration: result.duration)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func cancelVoiceRecording() {
        voiceService.cancelRecording()
    }

    func sendCurrentVoiceRecording() async {
        await sendPendingMedia()
    }

    private func handleAutoStopRecording() async {
        do {
            let result = try await voiceService.stopRecording()
            let data = try Data(contentsOf: result.url)
            try? FileManager.default.removeItem(at: result.url)
            await enqueuePendingMedia(data: data, type: .voice, duration: result.duration)
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    struct MessageDisplayItem: Identifiable {
        let id: String
        let message: MessageEntity
        let showSenderName: Bool
        let showAvatar: Bool
        let senderProfile: UserProfile?
        let isCurrentUser: Bool
        let showTranslation: Bool
    }
}

