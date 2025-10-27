import Foundation
import SwiftData
import FirebaseFirestore

private final class MessageListenerState {
    var lastMessageID: String?
    var conversationTitle: String?
    var hasPrimed: Bool
    var registration: ListenerRegistration?

    init(lastMessageID: String?, conversationTitle: String?) {
        self.lastMessageID = lastMessageID
        self.conversationTitle = conversationTitle
        self.hasPrimed = false
    }
}

@MainActor
final class ConversationsSyncService {
    private let db = Firestore.firestore()
    private var listener: ListenerRegistration?
    private var currentUserID: String?
    private weak var modelContext: ModelContext?
    private var onChange: (() -> Void)?
    private var hasProcessedInitialSnapshot = false
    private var messageListeners: [String: MessageListenerState] = [:]

    func start(for userID: String, modelContext: ModelContext, onChange: @escaping () -> Void) {
        stop()
        currentUserID = userID
        self.modelContext = modelContext
        self.onChange = onChange
        hasProcessedInitialSnapshot = false

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
                        let isInitial = !self.hasProcessedInitialSnapshot
                        try await self.processSnapshotChanges(snapshot.documentChanges, isInitial: isInitial)
                        self.hasProcessedInitialSnapshot = true
                    } catch {
                        print("[ConversationsSync] Failed to process changes: \(error)")
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
        hasProcessedInitialSnapshot = false
        for (_, state) in messageListeners {
            state.registration?.remove()
        }
        messageListeners.removeAll()
    }

    private func processSnapshotChanges(_ changes: [DocumentChange], isInitial: Bool) async throws {
        guard let modelContext, let currentUserID else { return }

        let existing = try modelContext.fetch(FetchDescriptor<ConversationEntity>())
        var existingMap = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

        let hiddenDescriptor = FetchDescriptor<ConversationPreferenceEntity>(
            predicate: #Predicate { $0.isHidden }
        )
        let hiddenPreferences = (try? modelContext.fetch(hiddenDescriptor)) ?? []
        let hiddenConversationIDs = Set(hiddenPreferences.map { $0.conversationID })

        for change in changes {
            switch change.type {
            case .added, .modified:
                let record = try change.document.data(as: ConversationRecord.self)
                let identifier = change.document.documentID
                if hiddenConversationIDs.contains(identifier) {
                    if let entity = existingMap[identifier] {
                        modelContext.delete(entity)
                        existingMap.removeValue(forKey: identifier)
                    }
                    continue
                }
                if record.hiddenForUserIDs.contains(currentUserID) {
                    continue
                }
                let entity = existingMap[identifier] ?? {
                    let newEntity = ConversationEntity(
                        id: identifier,
                        title: record.title,
                        participantIDs: record.participants,
                        type: record.type ?? .oneOnOne,
                        lastMessageID: record.lastMessageID,
                        lastMessagePreview: record.lastMessagePreview,
                        lastMessageTimestamp: record.bestTimestamp ?? Date(),
                        unreadCount: 0,
                        hiddenForUserIDs: record.hiddenForUserIDs
                    )
                    modelContext.insert(newEntity)
                    existingMap[identifier] = newEntity
                    return newEntity
                }()

                entity.title = record.title
                entity.participantIDs = record.participants
                entity.type = record.type ?? .oneOnOne
                entity.lastMessageID = record.lastMessageID
                entity.lastMessagePreview = record.lastMessagePreview
                entity.lastMessageTimestamp = record.bestTimestamp ?? entity.lastMessageTimestamp ?? Date()
                entity.unreadCount = record.unreadCounts?[currentUserID] ?? 0
                entity.hiddenForUserIDs = record.hiddenForUserIDs

                ensureMessageListener(for: identifier, title: entity.title, lastMessageID: entity.lastMessageID)
                updateTranslationPreference(for: identifier, record: record, in: modelContext)
            case .removed:
                let identifier = change.document.documentID
                if let entity = existingMap[identifier] {
                    modelContext.delete(entity)
                    existingMap.removeValue(forKey: identifier)
                }
                removeMessageListener(for: identifier)
            }
        }

        try modelContext.save()
        onChange?()
    }

    private func replaceLocalConversations(with documents: [QueryDocumentSnapshot]) async throws {
        guard let modelContext, let currentUserID else { return }

        let existing = try modelContext.fetch(FetchDescriptor<ConversationEntity>())
        var existingMap = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        var seenIdentifiers: Set<String> = []

        let hiddenDescriptor = FetchDescriptor<ConversationPreferenceEntity>(
            predicate: #Predicate { $0.isHidden }
        )
        let hiddenPreferences = (try? modelContext.fetch(hiddenDescriptor)) ?? []
        let hiddenConversationIDs = Set(hiddenPreferences.map { $0.conversationID })

        for document in documents {
            let record = try document.data(as: ConversationRecord.self)
            let identifier = document.documentID
            if hiddenConversationIDs.contains(identifier) {
                if let entity = existingMap[identifier] {
                    modelContext.delete(entity)
                    existingMap.removeValue(forKey: identifier)
                }
                continue
            }
            if record.hiddenForUserIDs.contains(currentUserID) {
                continue
            }
            seenIdentifiers.insert(identifier)

            let entity = existingMap[identifier] ?? {
                let newEntity = ConversationEntity(
                    id: identifier,
                    title: record.title,
                    participantIDs: record.participants,
                    type: record.type ?? .oneOnOne,
                    lastMessageID: record.lastMessageID,
                    lastMessagePreview: record.lastMessagePreview,
                    lastMessageTimestamp: record.bestTimestamp ?? Date(),
                    unreadCount: 0,
                    hiddenForUserIDs: record.hiddenForUserIDs
                )
                modelContext.insert(newEntity)
                existingMap[identifier] = newEntity
                return newEntity
            }()

            entity.title = record.title
            entity.participantIDs = record.participants
            entity.type = record.type ?? .oneOnOne
            entity.lastMessageID = record.lastMessageID
            entity.lastMessagePreview = record.lastMessagePreview
            entity.lastMessageTimestamp = record.bestTimestamp ?? entity.lastMessageTimestamp ?? Date()
            entity.unreadCount = record.unreadCounts?[currentUserID] ?? 0
            entity.hiddenForUserIDs = record.hiddenForUserIDs

            ensureMessageListener(for: identifier, title: entity.title, lastMessageID: entity.lastMessageID)
            updateTranslationPreference(for: identifier, record: record, in: modelContext)
        }

        for (identifier, entity) in existingMap where !seenIdentifiers.contains(identifier) {
            modelContext.delete(entity)
            removeMessageListener(for: identifier)
        }

        try modelContext.save()
        onChange?()
    }

    private func ensureMessageListener(for conversationID: String, title: String?, lastMessageID: String?) {
        if let state = messageListeners[conversationID] {
            if let title { state.conversationTitle = title }
            if let lastMessageID { state.lastMessageID = lastMessageID }
            return
        }

        guard let currentUserID else { return }

        let state = MessageListenerState(lastMessageID: lastMessageID, conversationTitle: title)
        messageListeners[conversationID] = state

        let baseQuery = db.collection("conversations")
            .document(conversationID)
            .collection("messages")

        let registration: ListenerRegistration
        registration = baseQuery
            .order(by: "timestamp", descending: false)
            .limit(toLast: 50)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                guard let state = self.messageListeners[conversationID] else { return }

                if let error {
                    print("[ConversationsSync] Message listener error for \(conversationID): \(error)")
                    return
                }

                guard let snapshot else { return }

                if !state.hasPrimed {
                    state.hasPrimed = true
                    if let lastDocumentID = snapshot.documents.last?.documentID {
                        state.lastMessageID = lastDocumentID
                    }
                    return
                }

                for change in snapshot.documentChanges where change.type == .added {
                    let docID = change.document.documentID
                    if docID == state.lastMessageID {
                        continue
                    }
                    state.lastMessageID = docID
                    self.handleIncomingMessage(
                        document: change.document,
                        conversationID: conversationID,
                        conversationTitle: state.conversationTitle,
                        currentUserID: currentUserID
                    )
                }
            }

        state.registration = registration
    }

    private func removeMessageListener(for conversationID: String) {
        guard let state = messageListeners.removeValue(forKey: conversationID) else { return }
        state.registration?.remove()
    }

    private func updateTranslationPreference(for conversationID: String, record: ConversationRecord, in context: ModelContext) {
        guard let currentUserID else { return }

        let descriptor = FetchDescriptor<ConversationPreferenceEntity>(
            predicate: #Predicate { $0.conversationID == conversationID }
        )

        let preference: ConversationPreferenceEntity
        if let existing = try? context.fetch(descriptor).first {
            preference = existing
        } else {
            let newPreference = ConversationPreferenceEntity(conversationID: conversationID)
            context.insert(newPreference)
            preference = newPreference
        }

        if let remote = record.translationPreferences?[currentUserID] {
            preference.autoTranslateEnabled = remote.enabled ?? false
            preference.nativeLanguageCode = remote.native
            preference.targetLanguageCode = remote.target
        } else {
            preference.autoTranslateEnabled = false
        }
    }

    private func handleIncomingMessage(
        document: QueryDocumentSnapshot,
        conversationID: String,
        conversationTitle: String?,
        currentUserID: String
    ) {
        guard NotificationService.shared.currentConversationID != conversationID else { return }

        let data = document.data()
        guard let senderID = data["senderID"] as? String, senderID != currentUserID else { return }

        let content = (data["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !content.isEmpty else { return }

        Task { [weak self] in
            guard let self else { return }
            let senderName = await self.resolveDisplayName(for: senderID) ?? "New message"
            await MainActor.run {
                NotificationService.shared.showForegroundNotification(
                    message: content,
                    conversationID: conversationID,
                    conversationTitle: conversationTitle,
                    senderName: senderName
                )
            }
        }
    }

    private func resolveDisplayName(for userID: String) async -> String? {
        if let cached = cachedDisplayName(for: userID) {
            return cached
        }

        do {
            let snapshot = try await db.collection("users").document(userID).getDocument()
            guard let data = snapshot.data() else { return nil }
            let displayName = data["displayName"] as? String
            let email = data["email"] as? String
            cacheUser(userID: userID, displayName: displayName, email: email, profilePictureURL: nil, photoVersion: nil)
            return displayName
        } catch {
            print("[ConversationsSync] Failed to fetch user display name: \(error)")
            return nil
        }
    }

    private func cachedDisplayName(for userID: String) -> String? {
        guard let modelContext else { return nil }
        let descriptor = FetchDescriptor<UserEntity>(
            predicate: #Predicate { $0.id == userID }
        )
        return try? modelContext.fetch(descriptor).first?.displayName
    }

    private func cacheUser(
        userID: String,
        displayName: String?,
        email: String?,
        profilePictureURL: String?,
        photoVersion: Int?
    ) {
        guard let modelContext, let displayName else { return }

        let descriptor = FetchDescriptor<UserEntity>(
            predicate: #Predicate { $0.id == userID }
        )

        if let existing = try? modelContext.fetch(descriptor).first {
            let previousVersion = existing.photoVersion
            existing.displayName = displayName
            if let email { existing.email = email }
            if let profilePictureURL { existing.profilePictureURL = profilePictureURL }
            if let photoVersion { existing.photoVersion = photoVersion }
            if let photoVersion, previousVersion != Optional(photoVersion) {
                Task { await ProfileImageCache.shared.invalidate(userID: userID, photoVersion: previousVersion) }
            }
        } else {
            let user = UserEntity(
                id: userID,
                displayName: displayName,
                email: email ?? "",
                profilePictureURL: profilePictureURL,
                photoVersion: photoVersion ?? 0
            )
            modelContext.insert(user)
        }

        try? modelContext.save()
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
    var lastMessageSenderID: String?
    var senderDisplayName: String?
    var hiddenForUserIDs: [String]
    var translationPreferences: [String: TranslationPreferenceRecord]?

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
        createdAt: Date? = nil,
        lastMessageSenderID: String? = nil,
        senderDisplayName: String? = nil,
        hiddenForUserIDs: [String] = [],
        translationPreferences: [String: TranslationPreferenceRecord]? = nil
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
        self.lastMessageSenderID = lastMessageSenderID
        self.senderDisplayName = senderDisplayName
        self.hiddenForUserIDs = hiddenForUserIDs
        self.translationPreferences = translationPreferences
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

        lastMessageSenderID = try container.decodeIfPresent(String.self, forKey: .lastMessageSenderID)
        senderDisplayName = try container.decodeIfPresent(String.self, forKey: .senderDisplayName)
        hiddenForUserIDs = (try? container.decodeIfPresent([String].self, forKey: .hiddenForUserIDs)) ?? []
        translationPreferences = try container.decodeIfPresent([String: TranslationPreferenceRecord].self, forKey: .translationPreferences)
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
        case lastMessageSenderID = "lastMessageSenderID"
        case senderDisplayName = "senderDisplayName"
        case hiddenForUserIDs = "hiddenFor"
        case translationPreferences = "translationPreferences"
    }
}

private struct TranslationPreferenceRecord: Codable {
    var enabled: Bool?
    var native: String?
    var target: String?
}

