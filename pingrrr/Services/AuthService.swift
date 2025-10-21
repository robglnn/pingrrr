import Foundation
import FirebaseAuth

struct AuthenticatedUser {
    let id: String
    let email: String?
    let displayName: String?
}

enum SessionEvent {
    case authenticated(AuthenticatedUser)
    case unauthenticated
    case error(Error)
}

final class AuthService {
    private var handle: AuthStateDidChangeListenerHandle?

    var currentUserID: String? {
        Auth.auth().currentUser?.uid
    }

    var currentUserEmail: String? {
        Auth.auth().currentUser?.email
    }

    var currentUserDisplayName: String? {
        Auth.auth().currentUser?.displayName
    }

    func startListening(_ handler: @escaping (SessionEvent) -> Void) {
        if let handle {
            Auth.auth().removeStateDidChangeListener(handle)
        }

        handle = Auth.auth().addStateDidChangeListener { _, user in
            if let user {
                let authUser = AuthenticatedUser(
                    id: user.uid,
                    email: user.email,
                    displayName: user.displayName
                )
                handler(.authenticated(authUser))
            } else {
                handler(.unauthenticated)
            }
        }
    }

    func signOut() throws {
        try Auth.auth().signOut()
    }

    func signIn(email: String, password: String) async throws {
        try await Auth.auth().signIn(withEmail: email, password: password)
    }

    func signUp(email: String, password: String, displayName: String) async throws {
        let result = try await Auth.auth().createUser(withEmail: email, password: password)
        let request = result.user.createProfileChangeRequest()
        request.displayName = displayName
        try await request.commitChanges()
    }

    func reloadCurrentUser() async throws {
        try await Auth.auth().currentUser?.reload()
    }
}

