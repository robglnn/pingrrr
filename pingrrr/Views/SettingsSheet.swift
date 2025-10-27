import SwiftUI

struct SettingsSheet: View {
    @ObservedObject private var appServices: AppServices
    let onDismiss: () -> Void

    @State private var isSigningOut = false
    @State private var errorMessage: String?
    @State private var showingProfileEdit = false
    @ObservedObject private var profileService: ProfileService

    init(appServices: AppServices, onDismiss: @escaping () -> Void) {
        _appServices = ObservedObject(initialValue: appServices)
        _profileService = ObservedObject(initialValue: appServices.profileService)
        self.onDismiss = onDismiss
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Profile") {
                    Button {
                        showingProfileEdit = true
                    } label: {
                        HStack {
                            ProfileAvatarView(profile: profileService.currentUserProfile)
                                .frame(width: 44, height: 44)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profileService.currentUserProfile?.displayName ?? appServices.authService.currentUserDisplayName ?? "Unknown user")
                                    .font(.headline)
                                Text(appServices.authService.currentUserEmail ?? "")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Section("Account") {
                    if let userID = appServices.authService.currentUserID {
                        HStack {
                            Text("User ID")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(userID)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
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
            .task {
                await profileService.loadCurrentUserProfile(forceRefresh: false)
            }
        }
        .sheet(isPresented: $showingProfileEdit) {
            ProfileEditView(profileService: profileService)
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

struct ProfileAvatarView: View {
    let profile: UserProfile?

    var body: some View {
        AsyncProfileImageView(
            userID: profile?.id ?? "current-user",
            displayName: profile?.displayName ?? "User",
            photoURL: profile?.profilePictureURL,
            photoVersion: profile?.photoVersion ?? 0,
            size: .regular,
            showsBorder: true
        )
        .clipShape(Circle())
    }
}


