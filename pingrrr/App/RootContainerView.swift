import SwiftUI
import SwiftData
import Combine
import FirebaseAuth

struct RootContainerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var appServices = AppServices()

    var body: some View {
        Group {
            if appServices.sessionState == .authenticated {
                ConversationsView(appServices: appServices)
                    .environment(\.modelContext, modelContext)
            } else {
                AuthenticationFlowView(appServices: appServices)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            appServices.handleScenePhaseChange(newPhase)
        }
        .task {
            await appServices.configure()
        }
    }
}

final class AppServices: ObservableObject {
    let objectWillChange = PassthroughSubject<Void, Never>()

    @Published private(set) var sessionState: SessionState = .loading

    let authService = AuthService()
    let presenceService = PresenceService()
    let notificationService = NotificationService()

    func configure() async {
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
                    await self.cacheAuthenticatedUser(user)
                case .unauthenticated:
                    self.sessionState = .unauthenticated
                    await self.presenceService.updatePresence(isOnline: false)
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

    func signUp(email: String, password: String, displayName: String) async throws {
        try await authService.signUp(email: email, password: password, displayName: displayName)
    }

    func signOut() throws {
        try authService.signOut()
        sessionState = .unauthenticated
    }

    private func cacheAuthenticatedUser(_ user: AuthenticatedUser) async {
        // TODO: Sync user profile into SwiftData cache
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

