import Foundation
import FirebaseAuth
import FirebaseFirestore
import GoogleSignIn
import UIKit

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

    func currentUserUID() -> String? {
        Auth.auth().currentUser?.uid
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

    func signInWithGoogle(presenting viewController: UIViewController?) async throws {
        let presentingController: UIViewController

        if let viewController {
            presentingController = viewController
        } else if let controller = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController })
            .first {
            presentingController = controller
        } else {
            throw AuthError.missingPresentingController
        }

        let signInResult = try await GIDSignIn.sharedInstance.signIn(withPresenting: presentingController)

        guard let idToken = signInResult.user.idToken?.tokenString else {
            throw AuthError.missingGoogleIDToken
        }

        let accessToken = signInResult.user.accessToken.tokenString
        let credential = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: accessToken)

        do {
            try await Auth.auth().signIn(with: credential)
        } catch {
            throw error
        }
    }
}

extension AuthService {
    enum AuthError: LocalizedError {
        case missingPresentingController
        case missingGoogleIDToken

        var errorDescription: String? {
            switch self {
            case .missingPresentingController:
                return "Unable to find a view controller to present the Google Sign-In flow."
            case .missingGoogleIDToken:
                return "Google Sign-In did not return an ID token."
            }
        }
    }
}

