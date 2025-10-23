import Foundation
import SwiftData
import Combine
import FirebaseFirestore

@MainActor
final class ConversationsViewModel: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var items: [ConversationEntity] = []

    private let modelContext: ModelContext
    private let appServices: AppServices
    private let syncService = ConversationsSyncService()
    private let presenceService: PresenceService
    private let notificationService: NotificationService

    private var observedPresenceIDs: Set<String> = []
    private var notificationObserver: AnyCancellable?

    init(modelContext: ModelContext, appServices: AppServices) {
        self.modelContext = modelContext
        self.appServices = appServices
        self.presenceService = appServices.presenceService
        self.notificationService = appServices.notificationService
        refreshLocalItems()
    }

    func start() {
        guard let userID = appServices.authService.currentUserID else { return }
        print("[ConversationsViewModel] Starting sync service for user: \(userID)")
        syncService.start(for: userID, modelContext: modelContext) { [weak self] in
            print("[ConversationsViewModel] Sync service started, refreshing local items")
            self?.refreshLocalItems()
        }

        notificationObserver = notificationService.$lastNotification
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self else { return }
                self.handleForegroundNotification(notification)
            }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        await syncService.refresh()
        refreshLocalItems()
    }

    func stop() {
        syncService.stop()
        presenceService.removeAllObservers()
        observedPresenceIDs.removeAll()
        notificationObserver?.cancel()
        notificationObserver = nil
    }

    func ensureConversationAvailable(conversationID: String) async {
        print("[ConversationsViewModel] Ensuring conversation available: \(conversationID)")
        print("[ConversationsViewModel] Current conversations: \(items.map { $0.id })")

        if items.contains(where: { $0.id == conversationID }) {
            print("[ConversationsViewModel] Conversation already available")
            return
        }

        print("[ConversationsViewModel] Refreshing conversations...")
        await refresh()

        if items.contains(where: { $0.id == conversationID }) {
            print("[ConversationsViewModel] Conversation now available after refresh")
            return
        }

        print("[ConversationsViewModel] Still not found, waiting...")
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
            refreshLocalItems()
            if items.contains(where: { $0.id == conversationID }) {
                print("[ConversationsViewModel] Conversation found after waiting")
                return
            }
        }
        print("[ConversationsViewModel] Conversation not found after waiting: \(conversationID)")
    }

    func appendPlaceholderConversation(
        id: String,
        title: String?,
        participantIDs: [String],
        currentUserID: String
    ) {
        print("[ConversationsViewModel] appendPlaceholderConversation id=\(id)")
        guard !items.contains(where: { $0.id == id }) else { return }

        let placeholder = ConversationEntity(
            id: id,
            title: title,
            participantIDs: participantIDs,
            type: .oneOnOne,
            lastMessageID: nil,
            lastMessagePreview: "",
            lastMessageTimestamp: Date(),
            unreadCount: 0
        )

        if placeholder.persistentModelID == nil {
            modelContext.insert(placeholder)
            try? modelContext.save()
        }

        items.insert(placeholder, at: 0)
        let otherParticipants = participantIDs.filter { $0 != currentUserID }
        presenceService.observe(userIDs: otherParticipants)
        print("[ConversationsViewModel] items now: \(items.map { $0.id })")
    }

    func markConversationAsRead(_ conversation: ConversationEntity) async {
        guard let userID = appServices.authService.currentUserID else { return }
        let docRef = Firestore.firestore().collection("conversations").document(conversation.id)
        do {
            try await docRef.setData([
                "unreadCounts.\(userID)": 0
            ], merge: true)

            conversation.unreadCount = 0
            try modelContext.save()
            refreshLocalItems()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshLocalItems() {
        let descriptor = FetchDescriptor<ConversationEntity>(
            sortBy: [SortDescriptor(\.lastMessageTimestamp, order: .reverse)]
        )
        do {
            let fetched = try modelContext.fetch(descriptor)
            print("[ConversationsViewModel] refreshLocalItems fetched \(fetched.count) conversations: \(fetched.map { $0.id })")
            items = fetched
            updatePresenceObservers()
        } catch {
            print("[ConversationsViewModel] Failed to fetch conversations: \(error)")
        }
    }

    private func updatePresenceObservers() {
        guard let currentUserID = appServices.authService.currentUserID else { return }
        let participantIDs = items
            .flatMap { $0.participantIDs }
            .filter { $0 != currentUserID }
        let uniqueIDs = Set(participantIDs)

        let toRemove = observedPresenceIDs.subtracting(uniqueIDs)
        toRemove.forEach { presenceService.removeObserver(for: $0) }

        let toAdd = uniqueIDs.subtracting(observedPresenceIDs)
        presenceService.observe(userIDs: Array(toAdd))

        observedPresenceIDs = uniqueIDs
    }

    func presenceState(for conversation: ConversationEntity, currentUserID: String) -> PresenceViewData {
        let otherParticipants = conversation.participantIDs.filter { $0 != currentUserID }
        guard !otherParticipants.isEmpty else {
            return PresenceViewData(isOnline: false, lastSeen: nil)
        }

        var isOnline = false
        var latestSeen: Date?

        for participant in otherParticipants {
            guard let snapshot = presenceService.snapshot(for: participant) else { continue }
            if snapshot.isOnline {
                isOnline = true
            }

            if let lastSeen = snapshot.lastSeen {
                if latestSeen == nil || lastSeen > latestSeen! {
                    latestSeen = lastSeen
                }
            }
        }

        return PresenceViewData(isOnline: isOnline, lastSeen: latestSeen)
    }

    private func handleForegroundNotification(_ notification: NotificationService.ChatNotification) {
        guard let conversation = items.first(where: { $0.id == notification.conversationID }) else {
            Task { await refresh() }
            return
        }

        if conversation.unreadCount == 0 {
            Task {
                await markConversationAsRead(conversation)
            }
        }

        refreshLocalItems()
    }
}

extension ConversationsViewModel {
    struct PresenceViewData {
        let isOnline: Bool
        let lastSeen: Date?
    }
}

