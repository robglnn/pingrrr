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
    @Published private(set) var displayItemsVersion: Int = 0
    @Published private(set) var readReceiptVersion: Int = 0
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

    private var networkMonitor: NetworkMonitor {
        appServices.networkMonitor
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
    @Published private(set) var autoTranslateEnabled = false
    @Published private(set) var autoTranslateNativeLanguage: TranslationLanguage = TranslationLanguage.supported.first(where: { $0.code == "en" }) ?? TranslationLanguage.supported.first!
    @Published private(set) var autoTranslateTargetLanguage: TranslationLanguage = TranslationLanguage.supported.first(where: { $0.code == "es" }) ?? TranslationLanguage.supported.first!

    private var translationCache: [String: String] = [:]
    private var translationVisibility: [String: Bool] = [:]
    private var aiInsights: [String: AIInsight] = [:]
    private var aiBusyMessageIDs: Set<String> = []
    private var aiProcessingFlag = false
    private var profilePrefetchTask: Task<Void, Never>?
    private var autoTranslationTasks: [String: Task<Void, Never>] = [:]
    private var conversationPreference: ConversationPreferenceEntity?

    var aiIsProcessingTranslation: Bool {
        isAIProcessingTranslation
    }

    var loggedInUserID: String {
        currentUserID
    }

    private var cancellables: Set<AnyCancellable> = []
    private static let broadcastTranslationKey = "broadcast"

    var supportedTranslationLanguages: [TranslationLanguage] {
        TranslationLanguage.supported
    }

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
        loadTranslationPreferenceFromStore()
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
        cancelPendingAutoTranslationTasks()
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

    func toggleAutoTranslate() async {
        autoTranslateEnabled.toggle()
        conversationPreference?.autoTranslateEnabled = autoTranslateEnabled
        try? modelContext.save()

        if autoTranslateEnabled {
            applyAutoTranslationToCachedMessages(force: true)
        } else {
            cancelPendingAutoTranslationTasks()
        }

        await persistTranslationPreference()
    }

    func updateAutoTranslateLanguages(native: TranslationLanguage, target: TranslationLanguage) async {
        autoTranslateNativeLanguage = native
        autoTranslateTargetLanguage = target

        conversationPreference?.nativeLanguageCode = native.code
        conversationPreference?.targetLanguageCode = target.code
        try? modelContext.save()

        if autoTranslateEnabled {
            cancelPendingAutoTranslationTasks()
            applyAutoTranslationToCachedMessages(force: true)
        }

        await persistTranslationPreference()
    }

    var isAutoTranslateActive: Bool {
        autoTranslateEnabled
    }

    func translationForDisplay(of message: MessageEntity) -> MessageAutoTranslation? {
        guard autoTranslateEnabled else { return nil }

        if let personal = message.autoTranslations[currentUserID] {
            return personal
        }

        if let broadcast = message.autoTranslations[Self.broadcastTranslationKey],
           broadcast.targetLanguageCode == autoTranslateNativeLanguage.code {
            return broadcast
        }

        return nil
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

    func explainSlang(for messageID: String?) async {
        guard let messageID,
              let message = messages.first(where: { $0.id == messageID }) else {
            return
        }

        await markBusy(true, for: messageID)
        defer { Task { await self.markBusy(false, for: messageID) } }

        do {
            let explanation = try await AIService.shared.explainSlang(
                text: message.content,
                language: aiPreferences.primaryLanguage
            )
            aiInsights[message.id] = AIInsight(type: .slang, content: explanation)
            regroupMessages()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func culturalHint(for messageID: String?) async {
        guard let messageID,
              let message = messages.first(where: { $0.id == messageID }) else {
            return
        }

        await markBusy(true, for: messageID)
        defer { Task { await self.markBusy(false, for: messageID) } }

        do {
            let hint = try await AIService.shared.culturalHint(
                text: message.content,
                language: aiPreferences.primaryLanguage,
                audienceCountry: nil
            )
            aiInsights[message.id] = AIInsight(type: .culture, content: hint)
            regroupMessages()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func adjustTone(for messageID: String?) async {
        guard let messageID,
              let message = messages.first(where: { $0.id == messageID }) else {
            return
        }

        await markBusy(true, for: messageID)
        defer { Task { await self.markBusy(false, for: messageID) } }

        let preferredFormality = aiPreferences.defaultFormality == .automatic ? .formal : aiPreferences.defaultFormality

        do {
            let adjusted = try await AIService.shared.adjustTone(
                text: message.content,
                language: aiPreferences.primaryLanguage,
                formality: preferredFormality
            )
            aiInsights[message.id] = AIInsight(type: .formality, content: adjusted)
            regroupMessages()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeInsight(for messageID: String?) {
        guard let messageID else { return }
        aiInsights[messageID] = nil
        regroupMessages()
    }

    func isAIRequestInFlight(for messageID: String) -> Bool {
        aiBusyMessageIDs.contains(messageID)
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
        let wasFailed = message.status == .failed
        outgoingQueue.enqueueRetry(for: message)

        if networkMonitor.isReachable {
            await resend(message)
        } else if wasFailed {
            message.status = .failed
            regroupMessages()
        }
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
        var outgoingTranslations: [String: MessageAutoTranslation] = [:]

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
        } else if case let .text(text) = request, autoTranslateEnabled {
            isAIProcessingTranslation = true
            defer { isAIProcessingTranslation = false }
            do {
                outgoingTranslations = try await prepareOutgoingAutoTranslations(for: text)
            } catch {
                errorMessage = error.localizedDescription
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
            readTimestamps: [currentUserID: now],
            isLocalOnly: true,
            retryCount: 0,
            nextRetryTimestamp: nil,
            mediaURL: optimisticMediaURL,
            mediaType: optimisticMediaType,
            autoTranslations: outgoingTranslations
        )
        optimisticMessage.voiceDuration = optimisticDuration

        modelContext.insert(optimisticMessage)
        messages.append(optimisticMessage)
        regroupMessages()
        updateReadReceiptProfiles()

        updateConversationForOutgoingMessage(content: optimisticContent, timestamp: now, messageID: tempID)

        if !networkMonitor.isReachable {
            outgoingQueue.enqueueRetry(for: optimisticMessage)
            regroupMessages()
            return
        }

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

        if !message.readTimestamps.isEmpty {
            let map = message.readTimestamps.mapValues { Timestamp(date: $0) }
            payload["readTimestamps"] = map
        }

        if let mediaURL = message.mediaURL {
            payload["mediaURL"] = mediaURL
            payload["mediaType"] = message.mediaType?.rawValue
            if let duration = message.voiceDuration {
                payload["voiceDuration"] = duration
            }
        }

        if !message.autoTranslations.isEmpty {
            var translationsPayload: [String: Any] = [:]
            for (key, translation) in message.autoTranslations {
                var entry: [String: Any] = [
                    "text": translation.text,
                    "targetLanguageCode": translation.targetLanguageCode,
                    "authorID": translation.authorID,
                    "updatedAt": Timestamp(date: translation.updatedAt)
                ]
                if let source = translation.sourceLanguageCode {
                    entry["sourceLanguageCode"] = source
                }
                translationsPayload[key] = entry
            }
            payload["autoTranslations"] = translationsPayload
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
                "readBy": FieldValue.arrayUnion([currentUserID]),
                "readTimestamps.\(currentUserID)": FieldValue.serverTimestamp()
            ], forDocument: messageRef)
            if !message.readBy.contains(currentUserID) {
                message.readBy.append(currentUserID)
            }
            message.readTimestamps[currentUserID] = Date()
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
        Task { await markMessagesAsRead() }
        attemptedProfileFetches.removeAll()
        prefetchRelevantProfiles()
    }

    func userLeftChat() {
        NotificationService.shared.clearCurrentChatID()
        profilePrefetchTask?.cancel()
        profilePrefetchTask = nil
        cancelPendingAutoTranslationTasks()
    }

    func loadCachedMessages() {
        print("[ChatViewModel] loadCachedMessages conversationID=\(conversationID)")
        let descriptor = FetchDescriptor<MessageEntity>(
            predicate: #Predicate { $0.conversationID == conversationID },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        messages = (try? modelContext.fetch(descriptor)) ?? []
        let participantIDs = conversation?.participantIDs ?? []
        let senderIDs = messages.map { $0.senderID }
        let readReceiptIDs = messages.flatMap { $0.readBy }
        let cachedIDs = Set(participantIDs).union(senderIDs).union(readReceiptIDs)
        seedProfilesFromCache(for: cachedIDs)
        regroupMessages()
        updateReadReceiptProfiles()
        refreshConversationReference()
        loadTranslationPreferenceFromStore()
        applyAutoTranslationToCachedMessages()
        Task { await markMessagesAsRead() }
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

    private func loadTranslationPreferenceFromStore() {
        let descriptor = FetchDescriptor<ConversationPreferenceEntity>(
            predicate: #Predicate { $0.conversationID == conversationID }
        )

        if let preference = try? modelContext.fetch(descriptor).first {
            conversationPreference = preference
        } else {
            let preference = ConversationPreferenceEntity(conversationID: conversationID)
            modelContext.insert(preference)
            conversationPreference = preference
            try? modelContext.save()
        }

        if let preference = conversationPreference {
            if preference.nativeLanguageCode == nil {
                preference.nativeLanguageCode = autoTranslateNativeLanguage.code
            }
            if preference.targetLanguageCode == nil {
                preference.targetLanguageCode = autoTranslateTargetLanguage.code
            }
            applyTranslationPreference(preference)
            try? modelContext.save()
        }
    }

    private func applyTranslationPreference(_ preference: ConversationPreferenceEntity) {
        autoTranslateEnabled = preference.autoTranslateEnabled
        if let native = TranslationLanguage.language(for: preference.nativeLanguageCode) {
            autoTranslateNativeLanguage = native
        }
        if let target = TranslationLanguage.language(for: preference.targetLanguageCode) {
            autoTranslateTargetLanguage = target
        }
    }

    private func applyAutoTranslationToCachedMessages(force: Bool = false) {
        guard autoTranslateEnabled else { return }
        for message in messages {
            scheduleAutoTranslation(for: message, force: force)
        }
    }

    private func scheduleAutoTranslation(for message: MessageEntity, force: Bool) {
        guard autoTranslateEnabled else { return }
        guard message.senderID != currentUserID else { return }
        guard message.mediaType == nil else { return }
        guard message.mediaURL == nil else { return }

        if !force {
            if let existing = message.autoTranslations[currentUserID],
               existing.targetLanguageCode == autoTranslateNativeLanguage.code {
                return
            }
            if let broadcast = message.autoTranslations[Self.broadcastTranslationKey],
               broadcast.targetLanguageCode == autoTranslateNativeLanguage.code {
                return
            }
        }

        if autoTranslationTasks[message.id] != nil {
            return
        }

        autoTranslationTasks[message.id] = Task { @MainActor [weak self, weak message] in
            guard let self, let message else { return }
            do {
                let translated = try await AIService.shared.translate(
                    text: message.content,
                    targetLang: self.autoTranslateNativeLanguage.code,
                    formality: self.aiPreferences.defaultFormality
                )
                if Task.isCancelled { return }

                let payload = MessageAutoTranslation(
                    text: translated,
                    sourceLanguageCode: nil,
                    targetLanguageCode: self.autoTranslateNativeLanguage.code,
                    authorID: self.currentUserID,
                    updatedAt: Date()
                )

                message.autoTranslations[self.currentUserID] = payload
                try? self.modelContext.save()
                self.regroupMessages()
                await self.persistAutoTranslation(payload, for: message, key: self.currentUserID)
            } catch {
                if !Task.isCancelled {
                    self.errorMessage = error.localizedDescription
                }
            }
            self.autoTranslationTasks[message.id] = nil
        }
    }

    private func cancelPendingAutoTranslationTasks() {
        for (_, task) in autoTranslationTasks {
            task.cancel()
        }
        autoTranslationTasks.removeAll()
    }

    private func persistAutoTranslation(_ translation: MessageAutoTranslation, for message: MessageEntity, key: String) async {
        let docRef = Firestore.firestore()
            .collection("conversations")
            .document(conversationID)
            .collection("messages")
            .document(message.id)

        var entry: [String: Any] = [
            "text": translation.text,
            "targetLanguageCode": translation.targetLanguageCode,
            "authorID": translation.authorID,
            "updatedAt": Timestamp(date: translation.updatedAt)
        ]

        if let source = translation.sourceLanguageCode {
            entry["sourceLanguageCode"] = source
        }

        do {
            try await docRef.setData([
                "autoTranslations.\(key)": entry
            ], merge: true)
        } catch {
            if !Task.isCancelled {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func persistTranslationPreference() async {
        let docRef = Firestore.firestore().collection("conversations").document(conversationID)
        let payload: [String: Any] = [
            "enabled": autoTranslateEnabled,
            "native": autoTranslateNativeLanguage.code,
            "target": autoTranslateTargetLanguage.code
        ]

        do {
            try await docRef.setData([
                "translationPreferences.\(currentUserID)": payload
            ], merge: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func prepareOutgoingAutoTranslations(for text: String) async throws -> [String: MessageAutoTranslation] {
        let translated = try await AIService.shared.translate(
            text: text,
            targetLang: autoTranslateTargetLanguage.code,
            formality: aiPreferences.defaultFormality
        )

        let payload = MessageAutoTranslation(
            text: translated,
            sourceLanguageCode: autoTranslateNativeLanguage.code,
            targetLanguageCode: autoTranslateTargetLanguage.code,
            authorID: currentUserID,
            updatedAt: Date()
        )

        var map: [String: MessageAutoTranslation] = [
            Self.broadcastTranslationKey: payload,
            currentUserID: payload
        ]

        return map
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
            applyDisplayItems([])
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
                    makeDisplayItem(for: message, showName: showName, showAvatar: showAvatar, isCurrentUser: isCurrentUser)
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

        applyDisplayItems(newItems)

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

            var didUpdateProfiles = false

            for id in toFetch {
                do {
                    let profile = try await profileService.fetchUserProfile(userID: id)
                    let existing = userProfiles[id]
                    userProfiles[id] = profile
                    if existing == nil ||
                        existing?.displayName != profile.displayName ||
                        existing?.profilePictureURL != profile.profilePictureURL ||
                        existing?.photoVersion != profile.photoVersion {
                        didUpdateProfiles = true
                    }
                } catch {
                    print("[ChatViewModel] Failed to load profile for \(id): \(error)")
                }
            }
            if didUpdateProfiles {
                regroupMessages()
                updateReadReceiptProfiles()
            }
        }
    }

    func cachedProfile(for userID: String) -> UserProfile? {
        userProfiles[userID]
    }

    private func updateReadReceiptProfiles() {
        var map: [String: UserProfile] = [:]
        var missing: Set<String> = []
        for message in messages {
            for userID in message.readBy where map[userID] == nil {
                if let cached = userProfiles[userID] {
                    map[userID] = cached
                } else {
                    missing.insert(userID)
                }
            }
        }
        applyReadReceiptProfiles(map)
        if !missing.isEmpty {
            loadProfilesIfNeeded(for: missing)
        }
    }

    private func applyDisplayItems(_ items: [MessageDisplayItem]) {
        let previousIDs = displayItems.map(\.id)
        let newIDs = items.map(\.id)
        displayItems = items
        if previousIDs != newIDs {
            displayItemsVersion &+= 1
        }
    }

    private func applyReadReceiptProfile(_ profile: UserProfile, for userID: String) {
        var updated = readReceiptProfiles
        updated[userID] = profile
        applyReadReceiptProfiles(updated)
    }

    private func applyReadReceiptProfiles(_ profiles: [String: UserProfile]) {
        guard shouldUpdateReadReceipts(with: profiles) else { return }
        readReceiptProfiles = profiles
        readReceiptVersion &+= 1
    }

    private func shouldUpdateReadReceipts(with newProfiles: [String: UserProfile]) -> Bool {
        let currentKeys = Set(readReceiptProfiles.keys)
        let newKeys = Set(newProfiles.keys)
        if currentKeys != newKeys {
            return true
        }
        for key in newKeys {
            guard let current = readReceiptProfiles[key], let updated = newProfiles[key] else { continue }
            if current.displayName != updated.displayName ||
                current.photoVersion != updated.photoVersion ||
                current.profilePictureURL != updated.profilePictureURL {
                return true
            }
        }
        return false
    }

    private func seedProfilesFromCache(for userIDs: Set<String>) {
        let missing = userIDs.subtracting(userProfiles.keys)
        guard !missing.isEmpty else { return }

        let ids = Array(missing)
        let descriptor = FetchDescriptor<UserEntity>(
            predicate: #Predicate { ids.contains($0.id) }
        )

        guard let entities = try? modelContext.fetch(descriptor) else { return }

        for entity in entities {
            let profile = userProfile(from: entity)
            userProfiles[entity.id] = profile
        }
    }

    private func relevantProfileIDs() -> Set<String> {
        var ids = Set(conversation?.participantIDs ?? [])
        ids.remove(currentUserID)

        for message in messages {
            if message.senderID != currentUserID {
                ids.insert(message.senderID)
            }
            for reader in message.readBy where reader != currentUserID {
                ids.insert(reader)
            }
        }
        return ids
    }

    private func prefetchRelevantProfiles() {
        profilePrefetchTask?.cancel()
        let ids = relevantProfileIDs()
        guard !ids.isEmpty else {
            updateReadReceiptProfiles()
            return
        }

        profilePrefetchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var needsRegroup = false

            for id in ids {
                do {
                    let profile = try await profileService.fetchUserProfile(userID: id)
                    let existing = userProfiles[id]
                    userProfiles[id] = profile
                    if existing == nil ||
                        existing?.displayName != profile.displayName ||
                        existing?.profilePictureURL != profile.profilePictureURL ||
                        existing?.photoVersion != profile.photoVersion {
                        needsRegroup = true
                    }
                } catch {
                    print("[ChatViewModel] Failed to prefetch profile for \(id): \(error)")
                }
            }

            if needsRegroup {
                regroupMessages()
            }
            attemptedProfileFetches.formUnion(ids)
            updateReadReceiptProfiles()
        }
    }

    private func userProfile(from entity: UserEntity) -> UserProfile {
        UserProfile(
            id: entity.id,
            displayName: entity.displayName,
            email: entity.email,
            profilePictureURL: entity.profilePictureURL,
            onlineStatus: entity.onlineStatus,
            lastSeen: entity.lastSeen,
            fcmToken: entity.fcmToken,
            photoVersion: entity.photoVersion ?? 0
        )
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
        let insight: AIInsight?
        let isProcessing: Bool
    }

    private func makeDisplayItem(for message: MessageEntity, showName: Bool, showAvatar: Bool, isCurrentUser: Bool) -> MessageDisplayItem {
        MessageDisplayItem(
            id: message.id,
            message: message,
            showSenderName: showName,
            showAvatar: showAvatar,
            senderProfile: userProfiles[message.senderID],
            isCurrentUser: isCurrentUser,
            showTranslation: translationVisibility[message.id] == true,
            insight: aiInsights[message.id],
            isProcessing: aiBusyMessageIDs.contains(message.id)
        )
    }

    private func aiInsight(for messageID: String) -> AIInsight? {
        aiInsights[messageID]
    }

    struct AIInsight {
        enum InsightType {
            case slang
            case culture
            case formality
        }

        let type: InsightType
        let content: String
    }

    private func markBusy(_ busy: Bool, for messageID: String) async {
        await MainActor.run {
            if busy {
                aiBusyMessageIDs.insert(messageID)
                aiInsights[messageID] = nil
            } else {
                aiBusyMessageIDs.remove(messageID)
            }
            regroupMessages()
        }
    }
}

