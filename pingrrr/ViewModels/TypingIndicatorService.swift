import Foundation
import FirebaseFirestore

@MainActor
final class TypingIndicatorService {
    private let db = Firestore.firestore()
    private var conversationID: String?
    private var currentUserID: String?
    private var listener: ListenerRegistration?
    private var onTypingChange: (([String]) -> Void)?
    private let typingVisibilityWindow: TimeInterval = 3

    func startMonitoring(
        conversationID: String,
        currentUserID: String,
        onTypingChange: @escaping ([String]) -> Void
    ) {
        stop()
        self.conversationID = conversationID
        self.currentUserID = currentUserID
        self.onTypingChange = onTypingChange

        listener = db.collection("conversations")
            .document(conversationID)
            .collection("metadata")
            .document("typing")
            .addSnapshotListener { [weak self] snapshot, _ in
                guard let self else { return }
                guard let data = snapshot?.data(),
                      let users = data["users"] as? [String],
                      let timestamp = (data["updatedAt"] as? Timestamp)?.dateValue(),
                      Date().timeIntervalSince(timestamp) <= self.typingVisibilityWindow else {
                    self.updateTypingUsers([])
                    return
                }
                let filtered = users.filter { $0 != currentUserID }
                self.updateTypingUsers(filtered)
            }
    }

    func setTyping(_ isTyping: Bool) {
        guard let conversationID, let currentUserID else { return }

        let ref = db.collection("conversations")
            .document(conversationID)
            .collection("metadata")
            .document("typing")

        Task {
            do {
                if isTyping {
                    try await ref.setData([
                        "users": FieldValue.arrayUnion([currentUserID]),
                        "updatedAt": FieldValue.serverTimestamp()
                    ], merge: true)
                } else {
                    try await ref.setData([
                        "users": FieldValue.arrayRemove([currentUserID]),
                        "updatedAt": FieldValue.serverTimestamp()
                    ], merge: true)
                }
            } catch {
                print("[TypingIndicator] Failed to update typing state: \(error)")
            }
        }
    }

    func stop() {
        listener?.remove()
        listener = nil
        conversationID = nil
        currentUserID = nil
        onTypingChange = nil
        updateTypingUsers([])
    }

    private func updateTypingUsers(_ users: [String]) {
        onTypingChange?(users)
    }
}

