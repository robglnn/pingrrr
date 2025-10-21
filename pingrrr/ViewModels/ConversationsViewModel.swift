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

    init(modelContext: ModelContext, appServices: AppServices) {
        self.modelContext = modelContext
        self.appServices = appServices
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
        }
    }
}

