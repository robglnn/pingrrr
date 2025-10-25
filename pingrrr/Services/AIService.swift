import Foundation
import Combine
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
            return "Daily AI limit reached. Try again tomorrow.";
        case .server(let message):
            return message
        }
    }
}

@MainActor
final class AIService: ObservableObject {
    static let shared = AIService()

    private let functions = Functions.functions(region: "us-central1")

    private init() {}

    func translate(text: String, targetLang: String?, formality: Formality) async throws -> String {
        let callable = functions.httpsCallable("aiTranslate")
        let result = try await callable.call([
            "text": text,
            "targetLang": targetLang as Any,
            "formality": formality.firebaseValue as Any,
        ])

        guard let data = result.data as? [String: Any],
              let translated = data["translatedText"] as? String else {
            throw AIServiceError.invalidResponse
        }
        return translated
    }

    func detectLanguage(for text: String) async throws -> AIDetectionResult {
        let callable = functions.httpsCallable("aiDetectLang")
        let result = try await callable.call(["text": text])

        guard let data = result.data as? [String: Any],
              let language = data["language"] as? String,
              let confidence = data["confidence"] as? Double else {
            throw AIServiceError.invalidResponse
        }

        let name = data["name"] as? String ?? language
        return AIDetectionResult(code: language, name: name, confidence: confidence)
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

