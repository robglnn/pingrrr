import Foundation
import Combine
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
import SwiftUI

@MainActor
final class ProfileService: ObservableObject {
    @Published private(set) var currentUserProfile: UserProfile?
    @Published private(set) var isUploading = false
    @Published private(set) var uploadProgress: Double = 0

    private let db = Firestore.firestore()
    private let storage = Storage.storage()

    func loadCurrentUserProfile() async {
        guard let userID = Auth.auth().currentUser?.uid else { return }

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
        await loadCurrentUserProfile()
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

        await loadCurrentUserProfile()

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
