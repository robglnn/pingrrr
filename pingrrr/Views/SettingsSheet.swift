import SwiftUI

struct SettingsSheet: View {
    @ObservedObject private var appServices: AppServices
    let onDismiss: () -> Void

    @State private var isSigningOut = false
    @State private var errorMessage: String?

    init(appServices: AppServices, onDismiss: @escaping () -> Void) {
        _appServices = ObservedObject(initialValue: appServices)
        self.onDismiss = onDismiss
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(appServices.authService.currentUserDisplayName ?? "Unknown user")
                                .font(.headline)
                            if let email = appServices.authService.currentUserEmail {
                                Text(email)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if let userID = appServices.authService.currentUserID {
                            Text(userID)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button(role: .destructive, action: signOut) {
                        if isSigningOut {
                            ProgressView()
                        } else {
                            Text("Sign Out")
                        }
                    }
                    .disabled(isSigningOut)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDismiss() }
                }
            }
        }
    }

    private func signOut() {
        guard !isSigningOut else { return }
        isSigningOut = true
        errorMessage = nil

        Task {
            do {
                try appServices.signOut()
                await MainActor.run {
                    onDismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
            }

            await MainActor.run {
                isSigningOut = false
            }
        }
    }
}


