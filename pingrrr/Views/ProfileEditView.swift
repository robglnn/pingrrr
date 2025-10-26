import SwiftUI
import PhotosUI

struct ProfileEditView: View {
    @ObservedObject var profileService: ProfileService
    @Environment(\.dismiss) private var dismiss

    @State private var displayName: String = ""
    @State private var selectedImage: UIImage?
    @State private var showingImagePicker = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile Picture") {
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            avatar
                                .frame(width: 110, height: 110)
                            Button("Change Photo") {
                                showingImagePicker = true
                            }
                            .disabled(isSaving)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }

                Section("Display Name") {
                    TextField("Display Name", text: $displayName)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.words)
                        .disabled(isSaving)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Edit Profile")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: saveProfile)
                        .disabled(isSaving || displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear {
            if let currentProfile = profileService.currentUserProfile {
                displayName = currentProfile.displayName
            }
        }
        .sheet(isPresented: $showingImagePicker) {
            ImagePicker(selectedImage: $selectedImage)
        }
    }

    private var avatar: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let selectedImage {
                    Image(uiImage: selectedImage)
                        .resizable()
                        .scaledToFill()
                } else if let profile = profileService.currentUserProfile {
                    AsyncProfileImageView(
                        userID: profile.id,
                        displayName: profile.displayName,
                        photoURL: profile.profilePictureURL,
                        photoVersion: profile.photoVersion,
                        size: .regular,
                        showsBorder: true
                    )
                } else {
                    placeholder
                }
            }
            .frame(width: 110, height: 110)
            .clipShape(Circle())
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.4), lineWidth: 2)
            )

            Circle()
                .fill(Color.blue)
                .frame(width: 32, height: 32)
                .overlay(
                    Image(systemName: "camera.fill")
                        .font(.footnote)
                        .foregroundColor(.white)
                )
                .offset(x: 4, y: 4)
        }
    }

    private var placeholder: some View {
        Circle()
            .fill(Color.blue.opacity(0.2))
            .overlay(
                Text(displayName.prefix(1).uppercased())
                    .font(.largeTitle.bold())
                    .foregroundColor(.blue)
            )
    }

    private func saveProfile() {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil

        Task {
            do {
                let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedName.isEmpty {
                    throw ProfileError.emptyDisplayName
                }

                if trimmedName != profileService.currentUserProfile?.displayName {
                    try await profileService.updateDisplayName(trimmedName)
                }

                if let image = selectedImage {
                    _ = try await profileService.uploadProfilePicture(image)
                }

                await MainActor.run {
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
            }

            await MainActor.run {
                isSaving = false
            }
        }
    }
}
