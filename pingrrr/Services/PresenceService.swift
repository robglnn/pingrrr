import Foundation
import FirebaseFirestore
import FirebaseAuth
import Combine

@MainActor
final class PresenceService: ObservableObject {
    struct Snapshot: Equatable {
        let isOnline: Bool
        let lastSeen: Date?
    }

    private let db = Firestore.firestore()
    private var listeners: [String: ListenerRegistration] = [:]
    private var listenerCounts: [String: Int] = [:]

    @Published private(set) var presenceByUser: [String: Snapshot] = [:]

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

    func observe(userID: String) {
        if let count = listenerCounts[userID] {
            listenerCounts[userID] = count + 1
            return
        }

        let registration = db.collection("presence").document(userID).addSnapshotListener { [weak self] snapshot, _ in
            guard let self else { return }
            Task { @MainActor in
                guard let data = snapshot?.data() else {
                    self.presenceByUser[userID] = Snapshot(isOnline: false, lastSeen: nil)
                    return
                }
                let isOnline = data["isOnline"] as? Bool ?? false
                let timestamp = (data["lastSeen"] as? Timestamp)?.dateValue()
                self.presenceByUser[userID] = Snapshot(isOnline: isOnline, lastSeen: timestamp)
            }
        }

        listeners[userID] = registration
        listenerCounts[userID] = 1
    }

    func observe(userIDs: [String]) {
        userIDs.forEach { observe(userID: $0) }
    }

    func snapshot(for userID: String) -> Snapshot? {
        presenceByUser[userID]
    }

    func removeObserver(for userID: String) {
        guard let count = listenerCounts[userID] else { return }

        if count <= 1 {
            listeners[userID]?.remove()
            listeners[userID] = nil
            listenerCounts[userID] = nil
            presenceByUser[userID] = nil
        } else {
            listenerCounts[userID] = count - 1
        }
    }

    func removeAllObservers() {
        listeners.values.forEach { $0.remove() }
        listeners.removeAll()
        listenerCounts.removeAll()
        presenceByUser.removeAll()
    }
}

