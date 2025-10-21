import Foundation
import SwiftUI
import Combine

@MainActor
final class AuthViewModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case signIn
        case signUp

        var id: String { rawValue }

        var title: String {
            switch self {
            case .signIn: return "Log In"
            case .signUp: return "Create Account"
            }
        }

        var actionTitle: String {
            switch self {
            case .signIn: return "Log In"
            case .signUp: return "Sign Up"
            }
        }
    }

    @Published var mode: Mode = .signIn
    @Published var email: String = ""
    @Published var password: String = ""
    @Published var displayName: String = ""
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    private let appServices: AppServices

    init(appServices: AppServices) {
        self.appServices = appServices
    }

    func submit() async {
        guard isLoading == false else { return }
        guard validateInput() else { return }
        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        do {
            switch mode {
            case .signIn:
                try await appServices.signIn(email: email, password: password)
            case .signUp:
                try await appServices.signUp(email: email, password: password, displayName: displayName)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleMode() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            mode = mode == .signIn ? .signUp : .signIn
            errorMessage = nil
        }
    }

    private func validateInput() -> Bool {
        if email.isEmpty || password.isEmpty {
            errorMessage = "Email and password are required."
            return false
        }

        if !email.contains("@") {
            errorMessage = "Enter a valid email."
            return false
        }

        if password.count < 8 {
            errorMessage = "Password must be at least 8 characters."
            return false
        }

        if mode == .signUp && displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errorMessage = "Display name is required."
            return false
        }

        return true
    }
}

