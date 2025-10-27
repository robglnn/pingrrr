import Foundation
import Combine
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
import SwiftUI
import SwiftData

@MainActor
final class ProfileService: ObservableObject {
    @Published private(set) var currentUserProfile: UserProfile?
    @Published private(set) var isUploading = false
    @Published private(set) var uploadProgress: Double = 0

    private let db = Firestore.firestore()
    private let storage = Storage.storage()
private var modelContext: ModelContext?

    func configure(modelContext: ModelContext?) {
        self.modelContext = modelContext

        guard let userID = Auth.auth().currentUser?.uid, currentUserProfile == nil else { return }
        if let cached = cachedProfile(userID: userID) {
            currentUserProfile = cached
        }
    }

    func loadCurrentUserProfile(forceRefresh: Bool = false) async {
        guard let userID = Auth.auth().currentUser?.uid else { return }

        if !forceRefresh {
            if let profile = currentUserProfile, profile.id == userID {
                return
            }

            if let cached = cachedProfile(userID: userID) {
                currentUserProfile = cached
                return
            }
        }

        do {
            let document = try await db.collection("users").document(userID).getDocument()
            let data = document.data()
            let photoVersionValue = (data?["photoVersion"] as? NSNumber)?.intValue ?? 0

            let profile = UserProfile(
                id: userID,
                displayName: data?["displayName"] as? String ?? Auth.auth().currentUser?.displayName ?? "",
                email: Auth.auth().currentUser?.email ?? "",
                profilePictureURL: data?["profilePictureURL"] as? String,
                onlineStatus: data?["onlineStatus"] as? Bool ?? false,
                lastSeen: (data?["lastSeen"] as? Timestamp)?.dateValue(),
                fcmToken: data?["fcmToken"] as? String,
                photoVersion: photoVersionValue
            )

            currentUserProfile = profile
            cacheProfileLocally(profile)
        } catch {
            print("[ProfileService] Failed to load profile: \(error)")
        }
    }

    func updateDisplayName(_ newName: String) async throws {
        guard let userID = Auth.auth().currentUser?.uid else { throw ProfileError.noUser }

        // Update Firebase Auth
        let request = Auth.auth().currentUser?.createProfileChangeRequest()
        request?.displayName = newName
        try await request?.commitChanges()

        // Update Firestore
        try await db.collection("users").document(userID).setData(
            [
                "displayName": newName,
                "displayNameLower": newName.lowercased(),
                "updatedAt": FieldValue.serverTimestamp()
            ],
            merge: true
        )

        // Refresh locally cached profile
        await loadCurrentUserProfile(forceRefresh: true)
    }

    func uploadProfilePicture(_ image: UIImage) async throws -> String {
        guard let userID = Auth.auth().currentUser?.uid else { throw ProfileError.noUser }

        isUploading = true
        uploadProgress = 0
        defer {
            isUploading = false
            uploadProgress = 0
        }

        guard let data = image.jpegData(compressionQuality: 0.75) else {
            throw ProfileError.compressionFailed
        }

        let storageRef = storage.reference().child("profile_pictures/\(userID)/avatar.jpg")
        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"

        _ = try await storageRef.putDataAsync(data, metadata: metadata)
        uploadProgress = 1

        let downloadURL = try await storageRef.downloadURL()

        try await db.collection("users").document(userID).setData(
            [
                "profilePictureURL": downloadURL.absoluteString,
                "photoVersion": FieldValue.increment(Int64(1)),
                "updatedAt": FieldValue.serverTimestamp()
            ],
            merge: true
        )

        await ProfileImageCache.shared.invalidate(userID: userID)

        await loadCurrentUserProfile(forceRefresh: true)

        return downloadURL.absoluteString
    }

    func fetchUserProfile(userID: String) async throws -> UserProfile {
        let document = try await db.collection("users").document(userID).getDocument()
        let data = document.data() ?? [:]
        let photoVersionValue = (data["photoVersion"] as? NSNumber)?.intValue ?? 0

        return UserProfile(
            id: userID,
            displayName: data["displayName"] as? String ?? "Unknown",
            email: data["email"] as? String ?? "",
            profilePictureURL: data["profilePictureURL"] as? String,
            onlineStatus: data["onlineStatus"] as? Bool ?? false,
            lastSeen: (data["lastSeen"] as? Timestamp)?.dateValue(),
            fcmToken: data["fcmToken"] as? String,
            photoVersion: photoVersionValue
        )
    }

    private func cachedProfile(userID: String) -> UserProfile? {
        guard let modelContext else { return nil }

        let descriptor = FetchDescriptor<UserEntity>(predicate: #Predicate { $0.id == userID })
        guard let entity = try? modelContext.fetch(descriptor).first else { return nil }

        return UserProfile(
            id: entity.id,
            displayName: entity.displayName,
            email: entity.email,
            profilePictureURL: entity.profilePictureURL,
            onlineStatus: entity.onlineStatus,
            lastSeen: entity.lastSeen,
            fcmToken: entity.fcmToken,
            photoVersion: entity.photoVersion ?? 0
        )
    }

    private func cacheProfileLocally(_ profile: UserProfile) {
        guard let modelContext else { return }

        let descriptor = FetchDescriptor<UserEntity>(predicate: #Predicate { $0.id == profile.id })

        if let existing = try? modelContext.fetch(descriptor).first {
            existing.displayName = profile.displayName
            existing.email = profile.email
            existing.profilePictureURL = profile.profilePictureURL
            existing.onlineStatus = profile.onlineStatus
            existing.lastSeen = profile.lastSeen
            existing.fcmToken = profile.fcmToken
            existing.photoVersion = profile.photoVersion
        } else {
            let entity = UserEntity(
                id: profile.id,
                displayName: profile.displayName,
                email: profile.email,
                profilePictureURL: profile.profilePictureURL,
                onlineStatus: profile.onlineStatus,
                lastSeen: profile.lastSeen,
                fcmToken: profile.fcmToken,
                photoVersion: profile.photoVersion
            )
            modelContext.insert(entity)
        }

        try? modelContext.save()
    }
}

enum ProfileError: LocalizedError {
    case noUser
    case compressionFailed
    case emptyDisplayName

    var errorDescription: String? {
        switch self {
        case .noUser:
            return "No authenticated user available"
        case .compressionFailed:
            return "Unable to prepare the selected photo"
        case .emptyDisplayName:
            return "Display name cannot be empty"
        }
    }
}
