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

    private var observedPresenceIDs: Set<String> = []

    init(modelContext: ModelContext, appServices: AppServices) {
        self.modelContext = modelContext
        self.appServices = appServices
        self.presenceService = appServices.presenceService
        refreshLocalItems()
    }

    func start() {
        guard let userID = appServices.authService.currentUserID else { return }
        syncService.start(for: userID, modelContext: modelContext) { [weak self] in
            self?.refreshLocalItems()
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
        if let fetched = try? modelContext.fetch(descriptor) {
            items = fetched
            updatePresenceObservers()
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
}

extension ConversationsViewModel {
    struct PresenceViewData {
        let isOnline: Bool
        let lastSeen: Date?
    }
}

