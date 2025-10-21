import Foundation
import SwiftData

struct UserProfile: Codable, Identifiable, Sendable {
    let id: String
    var displayName: String
    var email: String
    var profilePictureURL: String?
    var onlineStatus: Bool
    var lastSeen: Date?
    var fcmToken: String?

    init(
        id: String,
        displayName: String,
        email: String,
        profilePictureURL: String? = nil,
        onlineStatus: Bool = false,
        lastSeen: Date? = nil,
        fcmToken: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.email = email
        self.profilePictureURL = profilePictureURL
        self.onlineStatus = onlineStatus
        self.lastSeen = lastSeen
        self.fcmToken = fcmToken
    }
}

@Model
final class UserEntity {
    @Attribute(.unique) var id: String
    var displayName: String
    var email: String
    var profilePictureURL: String?
    var onlineStatus: Bool
    var lastSeen: Date?
    var fcmToken: String?

    init(
        id: String,
        displayName: String,
        email: String,
        profilePictureURL: String? = nil,
        onlineStatus: Bool = false,
        lastSeen: Date? = nil,
        fcmToken: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.email = email
        self.profilePictureURL = profilePictureURL
        self.onlineStatus = onlineStatus
        self.lastSeen = lastSeen
        self.fcmToken = fcmToken
    }
}

enum ConversationType: String, Codable, CaseIterable, Sendable {
    case oneOnOne
    case group
}

// Temporarily simplifying ConversationEntity for build compatibility
@Model
final class ConversationEntity {
    @Attribute(.unique) var id: String
    var title: String?
    var participantIDsString: String // Store as JSON string for now
    var typeRawValue: String
    var lastMessageID: String?
    var lastMessagePreview: String?
    var lastMessageTimestamp: Date?
    var unreadCount: Int

    // Temporarily removing relationship for build compatibility
    // @Relationship(deleteRule: .cascade, inverse: \MessageEntity.conversation)
    // var messages: [MessageEntity]

    init(
        id: String,
        title: String? = nil,
        participantIDs: [String],
        type: ConversationType,
        lastMessageID: String? = nil,
        lastMessagePreview: String? = nil,
        lastMessageTimestamp: Date? = nil,
        unreadCount: Int = 0
    ) {
        self.id = id
        self.title = title
        self.participantIDsString = ConversationEntity.encodeIDs(participantIDs)
        self.typeRawValue = type.rawValue
        self.lastMessageID = lastMessageID
        self.lastMessagePreview = lastMessagePreview
        self.lastMessageTimestamp = lastMessageTimestamp
        self.unreadCount = unreadCount
    }

    var type: ConversationType {
        get { ConversationType(rawValue: typeRawValue) ?? .oneOnOne }
        set { typeRawValue = newValue.rawValue }
    }

    var participantIDs: [String] {
        get { ConversationEntity.decodeIDs(participantIDsString) }
        set { participantIDsString = ConversationEntity.encodeIDs(newValue) }
    }

    static func encodeIDs(_ ids: [String]) -> String {
        guard let data = try? JSONEncoder().encode(ids),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }

    static func decodeIDs(_ string: String) -> [String] {
        guard let data = string.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return ids
    }
}

enum MessageStatus: String, Codable, CaseIterable, Sendable {
    case sending
    case sent
    case delivered
    case read
    case failed
}

// Temporarily simplifying MessageEntity for build compatibility
@Model
final class MessageEntity {
    @Attribute(.unique) var id: String
    var conversationID: String
    var senderID: String
    var content: String
    var translatedContent: String?
    var timestamp: Date
    var statusRawValue: String
    var readByString: String // Store as JSON string for now
    var isLocalOnly: Bool
    var retryCount: Int
    var nextRetryTimestamp: Date?

    // Temporarily removing relationship for build compatibility
    // @Relationship(deleteRule: .nullify, inverse: \ConversationEntity.messages)
    // var conversation: ConversationEntity?

    init(
        id: String,
        conversationID: String,
        senderID: String,
        content: String,
        translatedContent: String? = nil,
        timestamp: Date,
        status: MessageStatus,
        readBy: [String] = [],
        isLocalOnly: Bool = false,
        retryCount: Int = 0,
        nextRetryTimestamp: Date? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.senderID = senderID
        self.content = content
        self.translatedContent = translatedContent
        self.timestamp = timestamp
        self.statusRawValue = status.rawValue
        self.readByString = MessageEntity.encodeIDs(readBy)
        self.isLocalOnly = isLocalOnly
        self.retryCount = retryCount
        self.nextRetryTimestamp = nextRetryTimestamp
    }

    var status: MessageStatus {
        get { MessageStatus(rawValue: statusRawValue) ?? .sending }
        set { statusRawValue = newValue.rawValue }
    }

    var readBy: [String] {
        get { MessageEntity.decodeIDs(readByString) }
        set { readByString = MessageEntity.encodeIDs(newValue) }
    }

    static func encodeIDs(_ ids: [String]) -> String {
        guard let data = try? JSONEncoder().encode(ids),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }

    static func decodeIDs(_ string: String) -> [String] {
        guard let data = string.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return ids
    }
}

