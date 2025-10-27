import Foundation

struct TranslationLanguage: Identifiable, Hashable, Codable, Sendable {
    let code: String
    let name: String

    var id: String { code }

    static let supported: [TranslationLanguage] = [
        TranslationLanguage(code: "zh", name: "Mandarin"),
        TranslationLanguage(code: "es", name: "Spanish"),
        TranslationLanguage(code: "en", name: "English"),
        TranslationLanguage(code: "hi", name: "Hindi"),
        TranslationLanguage(code: "pl", name: "Polish"),
        TranslationLanguage(code: "ja", name: "Japanese"),
        TranslationLanguage(code: "fr", name: "French")
    ]

    static func language(for code: String?) -> TranslationLanguage? {
        guard let code else { return nil }
        return supported.first { $0.code == code }
    }
}
