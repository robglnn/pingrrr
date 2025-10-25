import Foundation
import Combine
import FirebaseFirestore
import FirebaseAuth

@MainActor
final class AIPreferencesService: ObservableObject {
    static let shared = AIPreferencesService()

    @Published private(set) var preferences: AIPreferences = .default

    private let db = Firestore.firestore()
    private var listener: ListenerRegistration?

    private init() {
        Task {
            await startListening()
        }
    }

    func startListening() async {
        guard let uid = Auth.auth().currentUser?.uid else {
            preferences = .default
            listener?.remove()
            listener = nil
            return
        }

        listener?.remove()
        listener = db.collection("users").document(uid).addSnapshotListener { [weak self] snapshot, _ in
            guard let data = snapshot?.data() else { return }
            self?.preferences = AIPreferences.fromFirestore(data: data)
        }
    }

    func updateFormality(_ formality: Formality) async throws {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        try await db.collection("users").document(uid).setData([
            "defaultFormality": formality.rawValue,
            "updatedAt": FieldValue.serverTimestamp(),
        ], merge: true)
    }

    func updatePrimaryLanguage(_ language: String) async throws {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        try await db.collection("users").document(uid).setData([
            "primaryLang": language,
            "updatedAt": FieldValue.serverTimestamp(),
        ], merge: true)
    }
}

struct AIPreferences {
    var primaryLanguage: String
    var targetLanguages: [String]
    var defaultFormality: Formality

    static let `default` = AIPreferences(
        primaryLanguage: "en",
        targetLanguages: ["en"],
        defaultFormality: .automatic
    )

    static func fromFirestore(data: [String: Any]) -> AIPreferences {
        let primary = data["primaryLang"] as? String ?? "en"
        let targets = data["targetLangs"] as? [String] ?? [primary]
        let formRaw = data["defaultFormality"] as? String ?? Formality.automatic.rawValue
        let formality = Formality(rawValue: formRaw) ?? .automatic

        return AIPreferences(
            primaryLanguage: primary,
            targetLanguages: targets,
            defaultFormality: formality
        )
    }
}

