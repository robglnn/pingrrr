import Foundation
import FirebaseFirestore
import FirebaseFirestoreSwift
import FirebaseAuth

final class PresenceService {
    private let db = Firestore.firestore()
    private var listener: ListenerRegistration?

    func updatePresence(isOnline: Bool) async {
        guard let userID = Auth.auth().currentUser?.uid else { return }

        let presenceRef = db.collection("presence").document(userID)
        let data: [String: Any] = [
            "isOnline": isOnline,
            "lastSeen": FieldValue.serverTimestamp()
        ]

        do {
            if isOnline {
                try await presenceRef.setData(data, merge: true)
            } else {
                try await presenceRef.setData(data, merge: true)
            }
        } catch {
            print("[PresenceService] Failed to update presence: \(error)")
        }
    }

    func observePresence(for userID: String, handler: @escaping (Bool, Date?) -> Void) {
        listener?.remove()
        listener = db.collection("presence").document(userID).addSnapshotListener { snapshot, _ in
            guard let data = snapshot?.data() else { return }
            let isOnline = data["isOnline"] as? Bool ?? false
            let timestamp = (data["lastSeen"] as? Timestamp)?.dateValue()
            handler(isOnline, timestamp)
        }
    }

    deinit {
        listener?.remove()
    }
}

