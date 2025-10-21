import Foundation
import FirebaseFirestore

@MainActor
final class TypingIndicatorService {
    private let db = Firestore.firestore()
    private var conversationID: String?
    private var currentUserID: String?
    private var listener: ListenerRegistration?
    private var onTypingChange: (([String]) -> Void)?
    private var typingUsers: Set<String> = []
    private var debounceTask: Task<Void, Never>?

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
                      let typing = data["users"] as? [String] else {
                    self.updateTypingUsers([])
                    return
                }
                self.updateTypingUsers(typing)
            }
    }

    func setTyping(_ isTyping: Bool) {
        guard let conversationID, let currentUserID else { return }

        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, !Task.isCancelled else { return }
            try? await self.updateTypingStatus(
                conversationID: conversationID,
                userID: currentUserID,
                isTyping: isTyping
            )
        }
    }

    func stop() {
        listener?.remove()
        listener = nil
        conversationID = nil
        currentUserID = nil
        onTypingChange = nil
        typingUsers.removeAll()
        debounceTask?.cancel()
        debounceTask = nil
    }

    private func updateTypingUsers(_ users: [String]) {
        typingUsers = Set(users)
        onTypingChange?(users)
    }

    private func updateTypingStatus(conversationID: String, userID: String, isTyping: Bool) async throws {
        let ref = db.collection("conversations")
            .document(conversationID)
            .collection("metadata")
            .document("typing")

        let update: [String: Any]
        if isTyping {
            update = ["users": FieldValue.arrayUnion([userID])]
        } else {
            update = ["users": FieldValue.arrayRemove([userID])]
        }

        try await ref.setData(update, merge: true)
    }
}

