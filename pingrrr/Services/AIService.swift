import Foundation
import FirebaseFunctions

enum AIServiceError: LocalizedError {
    case userUnauthenticated
    case invalidResponse
    case rateLimited
    case server(String)

    var errorDescription: String? {
        switch self {
        case .userUnauthenticated:
            return "You need to be signed in to use AI features."
        case .invalidResponse:
            return "Received an invalid response from AI service."
        case .rateLimited:
            return "Daily AI limit reached. Try again tomorrow."
        case .server(let message):
            return message
        }
    }
}

final class AIService {
    static let shared = AIService()

    private let functions = Functions.functions(region: "us-central1")

    private init() {}

    func translate(text: String, targetLang: String?, formality: Formality) async throws -> String {
        var payload: [String: Any] = ["text": text]

        if let targetLang, !targetLang.isEmpty {
            payload["targetLang"] = targetLang
        }

        if let formalityValue = formality.firebaseValue {
            payload["formality"] = formalityValue
        }

        let data = try await call(function: "aiTranslate", payload: payload)

        guard let translated = data["translatedText"] as? String else {
            throw AIServiceError.invalidResponse
        }
        return translated
    }

    func detectLanguage(for text: String) async throws -> AIDetectionResult {
        let data = try await call(function: "aiDetectLang", payload: ["text": text])

        guard let language = data["language"] as? String,
              let confidence = data["confidence"] as? Double else {
            throw AIServiceError.invalidResponse
        }

        let name = data["name"] as? String ?? language
        return AIDetectionResult(code: language, name: name, confidence: confidence)
    }

    func culturalHint(text: String, language: String?, audienceCountry: String?) async throws -> String {
        var payload: [String: Any] = ["text": text]

        if let language, !language.isEmpty {
            payload["language"] = language
        }

        if let audienceCountry, !audienceCountry.isEmpty {
            payload["audienceCountry"] = audienceCountry
        }

        let data = try await call(function: "aiCulturalHint", payload: payload)

        guard let hint = data["hint"] as? String else {
            throw AIServiceError.invalidResponse
        }
        return hint
    }

    func explainSlang(text: String, language: String?) async throws -> String {
        var payload: [String: Any] = ["text": text]

        if let language, !language.isEmpty {
            payload["language"] = language
        }

        let data = try await call(function: "aiExplainSlang", payload: payload)

        guard let explanation = data["explanation"] as? String else {
            throw AIServiceError.invalidResponse
        }
        return explanation
    }

    func adjustTone(text: String, language: String?, formality: Formality) async throws -> String {
        var payload: [String: Any] = [
            "text": text,
            "formality": formality.firebaseValue ?? formality.rawValue,
        ]

        if let language, !language.isEmpty {
            payload["language"] = language
        }

        let data = try await call(function: "aiAdjustTone", payload: payload)

        guard let adjusted = data["adjustedText"] as? String else {
            throw AIServiceError.invalidResponse
        }
        return adjusted
    }

    func smartReplies(conversationID: String, lastN: Int = 10, count: Int = 3, includeFullHistory: Bool = false) async throws -> [String] {
        let data = try await call(function: "aiSmartReplies", payload: [
            "conversationId": conversationID,
            "lastN": lastN,
            "replyCount": count,
            "includeFullHistory": includeFullHistory,
        ])

        guard let replies = data["replies"] as? [String] else {
            throw AIServiceError.invalidResponse
        }
        return replies
    }

    func summarizeConversation(conversationID: String, lastN: Int = 50, includeFullHistory: Bool = false) async throws -> String {
        let data = try await call(function: "aiSummarize", payload: [
            "conversationId": conversationID,
            "lastN": lastN,
            "includeFullHistory": includeFullHistory,
            "promptStyle": "concise",
        ])

        guard let summary = data["summary"] as? String else {
            throw AIServiceError.invalidResponse
        }
        return summary
    }

    func assistantReply(prompt: String, conversationID: String?, lastN: Int = 10, includeFullHistory: Bool = false) async throws -> String {
        var payload: [String: Any] = [
            "prompt": prompt,
            "lastN": lastN,
            "includeFullHistory": includeFullHistory,
        ]

        if let conversationID, !conversationID.isEmpty {
            payload["conversationId"] = conversationID
        }

        let data = try await call(function: "aiAssistant", payload: payload)

        guard let reply = data["reply"] as? String else {
            throw AIServiceError.invalidResponse
        }
        return reply
    }

    private func call(function name: String, payload: [String: Any]) async throws -> [String: Any] {
        do {
            let callable = functions.httpsCallable(name)
            let result = try await callable.call(payload)
            guard let data = result.data as? [String: Any] else {
                throw AIServiceError.invalidResponse
            }
            return data
        } catch {
            throw map(error: error)
        }
    }

    private func map(error: Error) -> Error {
        let nsError = error as NSError
        if nsError.domain == FunctionsErrorDomain,
           let code = FunctionsErrorCode(rawValue: nsError.code) {
            if code == .resourceExhausted {
                return AIServiceError.rateLimited
            }

            if let details = nsError.userInfo[FunctionsErrorDetailsKey] as? [String: Any],
               let message = details["message"] as? String {
                return AIServiceError.server(message)
            }

            return AIServiceError.server(nsError.localizedDescription)
        }

        return error
    }
}

enum Formality: String, CaseIterable, Identifiable {
    case automatic
    case formal
    case informal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic:
            return "Automatic"
        case .formal:
            return "Formal"
        case .informal:
            return "Informal"
        }
    }

    var firebaseValue: String? {
        switch self {
        case .automatic:
            return nil
        case .formal:
            return "formal"
        case .informal:
            return "informal"
        }
    }
}

struct AIDetectionResult {
    let code: String
    let name: String
    let confidence: Double
}

