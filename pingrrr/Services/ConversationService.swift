import Foundation
import FirebaseFunctions
import FirebaseFirestore

struct ConversationCreationResponse: Decodable {
    let conversationId: String
    let participantIds: [String]
    let type: String
}

final class ConversationService {
    private let functions = Functions.functions()
    private let db = Firestore.firestore()

    func createConversation(participantEmails: [String], title: String?) async throws -> ConversationCreationResponse {
        let callable = functions.httpsCallable("createConversation")
        let payload: [String: Any] = [
            "participantEmails": participantEmails,
            "title": title ?? ""
        ]

        let result = try await callable.call(payload)
        guard let data = result.data as? [String: Any],
              let conversationId = data["conversationId"] as? String,
              let participantIds = data["participantIds"] as? [String],
              let type = data["type"] as? String else {
            throw ConversationServiceError.invalidResponse
        }

        return ConversationCreationResponse(
            conversationId: conversationId,
            participantIds: participantIds,
            type: type
        )
    }

    func awaitConversation(conversationID: String) async {
        let docRef = db.collection("conversations").document(conversationID)
        if let existing = try? await docRef.getDocument(), existing.exists {
            return
        }

        let semaphore = DispatchSemaphore(value: 0)
        let listener = docRef.addSnapshotListener { snapshot, _ in
            if let snapshot, snapshot.exists {
                semaphore.signal()
            }
        }

        _ = semaphore.wait(timeout: .now() + 3)
        listener.remove()
    }
}

enum ConversationServiceError: Error {
    case invalidResponse
}

