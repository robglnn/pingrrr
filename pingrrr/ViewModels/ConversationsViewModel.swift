import Foundation
import SwiftData
import FirebaseFirestore

@MainActor
final class ConversationsViewModel: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let modelContext: ModelContext
    private let appServices: AppServices
    private let syncService = ConversationsSyncService()

    @Query private var conversations: [ConversationEntity]

    var items: [ConversationEntity] {
        conversations.sorted { lhs, rhs in
            (lhs.lastMessageTimestamp ?? .distantPast) > (rhs.lastMessageTimestamp ?? .distantPast)
        }
    }

    init(modelContext: ModelContext, appServices: AppServices) {
        self.modelContext = modelContext
        self.appServices = appServices

        let descriptor = FetchDescriptor<ConversationEntity>(
            sortBy: [SortDescriptor(\.lastMessageTimestamp, order: .reverse)]
        )
        _conversations = Query(descriptor)
    }

    func start() {
        guard let userID = appServices.authService.currentUserID else { return }
        syncService.start(for: userID, modelContext: modelContext)
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        await syncService.refresh()
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
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

