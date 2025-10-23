import SwiftUI
import SwiftData
import Combine
import FirebaseAuth
import FirebaseFirestore

struct RootContainerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var appServices = AppServices()

    var body: some View {
        Group {
            if appServices.sessionState == .authenticated {
                ConversationsView(appServices: appServices, modelContext: modelContext)
            } else {
                AuthenticationFlowView(appServices: appServices)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            appServices.handleScenePhaseChange(newPhase)
        }
        .task {
            await appServices.configure(modelContext: modelContext)
        }
    }
}

@MainActor
final class AppServices: ObservableObject {
    @Published private(set) var sessionState: SessionState = .loading

    let authService = AuthService()
    let presenceService = PresenceService()
    let notificationService = NotificationService.shared
    let networkMonitor = NetworkMonitor()
    lazy var outgoingMessageQueue = OutgoingMessageQueue(networkMonitor: networkMonitor)
    let conversationService = ConversationService()

    private var modelContext: ModelContext?
    private var hasConfigured = false

    func configure(modelContext: ModelContext) async {
        if modelContext !== self.modelContext {
            self.modelContext = modelContext
            outgoingMessageQueue.start(modelContext: modelContext)
        }

        guard !hasConfigured else { return }
        hasConfigured = true

        networkMonitor.start()
        await notificationService.requestAuthorization()
        await notificationService.registerForRemoteNotifications()

        authService.startListening { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case let .authenticated(user):
                    self.sessionState = .authenticated
                    await self.presenceService.updatePresence(isOnline: true)
                    await self.notificationService.refreshFCMToken()
                    self.outgoingMessageQueue.triggerFlush()
                    await self.cacheAuthenticatedUser(user)
                case .unauthenticated:
                    self.sessionState = .unauthenticated
                    await self.presenceService.updatePresence(isOnline: false)
                    self.outgoingMessageQueue.reset()
                case let .error(error):
                    self.sessionState = .error(error)
                }
            }
        }
    }

    func handleScenePhaseChange(_ phase: ScenePhase) {
        Task {
            switch phase {
            case .active:
                await presenceService.updatePresence(isOnline: true)
            case .background:
                await presenceService.updatePresence(isOnline: false)
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }

    func signIn(email: String, password: String) async throws {
        try await authService.signIn(email: email, password: password)
    }

    func signInWithGoogle(presenting viewController: UIViewController? = nil) async throws {
        try await authService.signInWithGoogle(presenting: viewController)
    }

    func signUp(email: String, password: String, displayName: String) async throws {
        try await authService.signUp(email: email, password: password, displayName: displayName)
    }

    func signOut() throws {
        try authService.signOut()
        sessionState = .unauthenticated
        outgoingMessageQueue.reset()
        networkMonitor.stop()
    }

    private func cacheAuthenticatedUser(_ user: AuthenticatedUser) async {
        let firestore = Firestore.firestore()
        var data: [String: Any] = [
            "uid": user.id,
            "updatedAt": FieldValue.serverTimestamp()
        ]

        if let email = user.email {
            data["email"] = email
            data["emailLower"] = email.lowercased()
        }

        if let displayName = user.displayName {
            data["displayName"] = displayName
        }

        do {
            try await firestore.collection("users").document(user.id).setData(data, merge: true)
        } catch {
            print("[AppServices] Failed to cache user: \(error)")
        }
    }
}

enum SessionState: Equatable {
    case loading
    case authenticated
    case unauthenticated
    case error(Error)

    static func == (lhs: SessionState, rhs: SessionState) -> Bool {
        switch (lhs, rhs) {
        case (.loading, .loading), (.authenticated, .authenticated), (.unauthenticated, .unauthenticated):
            return true
        case let (.error(lhsError), .error(rhsError)):
            return lhsError.localizedDescription == rhsError.localizedDescription
        default:
            return false
        }
    }
}

