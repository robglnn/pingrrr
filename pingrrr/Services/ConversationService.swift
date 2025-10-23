import Foundation
import FirebaseFunctions
import FirebaseFirestore
import SwiftData

struct ConversationCreationResponse: Decodable {
    let conversationId: String
    let participantIds: [String]
    let type: String
}

final class ConversationService {
    private let functions = Functions.functions()
    private let db = Firestore.firestore()
    private var modelContext: ModelContext?

    func createConversation(participantEmails: [String], title: String?) async throws -> ConversationCreationResponse {
        print("[ConversationService] Creating conversation with participants: \(participantEmails), title: \(title ?? "nil")")

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
            print("[ConversationService] Invalid response from createConversation: \(result.data)")
            throw ConversationServiceError.invalidResponse
        }

        print("[ConversationService] Created conversation: \(conversationId) with participants: \(participantIds)")

        return ConversationCreationResponse(
            conversationId: conversationId,
            participantIds: participantIds,
            type: type
        )
    }

    func awaitConversation(conversationID: String) async {
        let docRef = db.collection("conversations").document(conversationID)

        // Simple check - if it exists, great. If not, the sync service will handle it
        _ = try? await docRef.getDocument()
        // We don't actually need to wait here - the ConversationsSyncService will populate local data
    }
}

enum ConversationServiceError: Error {
    case invalidResponse
}


