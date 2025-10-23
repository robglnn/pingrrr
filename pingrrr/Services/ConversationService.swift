import Foundation
import FirebaseFunctions

struct ConversationCreationResponse: Decodable {
    let conversationId: String
    let participantIds: [String]
    let type: String
}

final class ConversationService {
    private let functions = Functions.functions()

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
}

enum ConversationServiceError: Error {
    case invalidResponse
}

