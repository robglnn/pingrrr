import Foundation
import SwiftData
import FirebaseFirestore

@MainActor
final class ConversationsSyncService {
    private let db = Firestore.firestore()
    private var listener: ListenerRegistration?
    private var currentUserID: String?
    private weak var modelContext: ModelContext?
    private var onChange: (() -> Void)?

    func start(for userID: String, modelContext: ModelContext, onChange: @escaping () -> Void) {
        stop()
        currentUserID = userID
        self.modelContext = modelContext
        self.onChange = onChange

        print("[ConversationsSync] Starting listener for user: \(userID)")
        listener = db.collection("conversations")
            .whereField("participants", arrayContains: userID)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }

                if let error {
                    print("[ConversationsSync] Snapshot error: \(error)")
                    return
                }

                guard let snapshot else { return }

                Task { @MainActor in
                    do {
                        try await self.replaceLocalConversations(with: snapshot.documents)
                    } catch {
                        print("[ConversationsSync] Failed to apply snapshot: \(error)")
                    }
                }
            }
    }

    func refresh() async {
        guard let userID = currentUserID else { return }

        do {
            let snapshot = try await db.collection("conversations")
                .whereField("participants", arrayContains: userID)
                .getDocuments()
            try await replaceLocalConversations(with: snapshot.documents)
        } catch {
            print("[ConversationsSync] Refresh failed: \(error)")
        }
    }

    func stop() {
        listener?.remove()
        listener = nil
        currentUserID = nil
        modelContext = nil
        onChange = nil
    }

    private func replaceLocalConversations(with documents: [QueryDocumentSnapshot]) async throws {
        guard let modelContext, let currentUserID else { return }

        let existing = try modelContext.fetch(FetchDescriptor<ConversationEntity>())
        var existingMap = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        var seenIdentifiers: Set<String> = []

        for document in documents {
            let record = try document.data(as: ConversationRecord.self)
            let identifier = document.documentID
            seenIdentifiers.insert(identifier)

            let entity: ConversationEntity
            if let cached = existingMap[identifier] {
                entity = cached
            } else {
                entity = ConversationEntity(
                    id: identifier,
                    title: record.title,
                    participantIDs: record.participants,
                    type: record.type ?? .oneOnOne,
                    lastMessageID: record.lastMessageID,
                    lastMessagePreview: record.lastMessagePreview,
                    lastMessageTimestamp: record.bestTimestamp ?? Date(),
                    unreadCount: 0
                )
                modelContext.insert(entity)
                existingMap[identifier] = entity
            }

            entity.title = record.title
            entity.participantIDs = record.participants
            entity.type = record.type ?? .oneOnOne
            entity.lastMessageID = record.lastMessageID
            entity.lastMessagePreview = record.lastMessagePreview
            entity.lastMessageTimestamp = record.bestTimestamp ?? entity.lastMessageTimestamp ?? Date()
            entity.unreadCount = record.unreadCounts?[currentUserID] ?? 0
        }

        for (identifier, entity) in existingMap where !seenIdentifiers.contains(identifier) {
            modelContext.delete(entity)
        }

        try modelContext.save()
        onChange?()
    }
}

private struct ConversationRecord: Codable {
    var id: String?
    var title: String?
    var participants: [String]
    var typeRawValue: String?
    var lastMessageID: String?
    var lastMessagePreview: String?
    var lastMessageTimestamp: Date?
    var unreadCounts: [String: Int]?
    var createdAt: Date?

    var type: ConversationType? {
        guard let typeRawValue else { return nil }
        return ConversationType(rawValue: typeRawValue)
    }

    var bestTimestamp: Date? {
        lastMessageTimestamp ?? createdAt
    }

    init(
        id: String? = nil,
        title: String? = nil,
        participants: [String] = [],
        typeRawValue: String? = nil,
        lastMessageID: String? = nil,
        lastMessagePreview: String? = nil,
        lastMessageTimestamp: Date? = nil,
        unreadCounts: [String: Int]? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.participants = participants
        self.typeRawValue = typeRawValue
        self.lastMessageID = lastMessageID
        self.lastMessagePreview = lastMessagePreview
        self.lastMessageTimestamp = lastMessageTimestamp
        self.unreadCounts = unreadCounts
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = nil

        title = try container.decodeIfPresent(String.self, forKey: .title)
        participants = try container.decode([String].self, forKey: .participants)
        typeRawValue = try container.decodeIfPresent(String.self, forKey: .typeRawValue)
        lastMessageID = try container.decodeIfPresent(String.self, forKey: .lastMessageID)
        lastMessagePreview = try container.decodeIfPresent(String.self, forKey: .lastMessagePreview)

        if let timestamp = try? container.decodeIfPresent(Timestamp.self, forKey: .lastMessageTimestamp) {
            lastMessageTimestamp = timestamp.dateValue()
        } else {
            lastMessageTimestamp = nil
        }

        if let createdTimestamp = try? container.decodeIfPresent(Timestamp.self, forKey: .createdAt) {
            createdAt = createdTimestamp.dateValue()
        } else {
            createdAt = nil
        }

        if let unreadCountsMap = try? container.decodeIfPresent([String: Int].self, forKey: .unreadCounts) {
            unreadCounts = unreadCountsMap
        } else {
            unreadCounts = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case participants
        case typeRawValue = "type"
        case lastMessageID = "lastMessageID"
        case lastMessagePreview = "lastMessagePreview"
        case lastMessageTimestamp = "lastMessageTimestamp"
        case unreadCounts = "unreadCounts"
        case createdAt = "createdAt"
    }
}

