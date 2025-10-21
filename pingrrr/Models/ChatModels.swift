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

@Model
final class ConversationEntity {
    @Attribute(.unique) var id: String
    var title: String?
    @Attribute(.transformable) var participantIDs: [String]
    var typeRawValue: String
    var lastMessageID: String?
    var lastMessagePreview: String?
    var lastMessageTimestamp: Date?
    var unreadCount: Int

    @Relationship(deleteRule: .cascade, inverse: \MessageEntity.conversation)
    var messages: [MessageEntity]

    init(
        id: String,
        title: String? = nil,
        participantIDs: [String],
        type: ConversationType,
        lastMessageID: String? = nil,
        lastMessagePreview: String? = nil,
        lastMessageTimestamp: Date? = nil,
        unreadCount: Int = 0,
        messages: [MessageEntity] = []
    ) {
        self.id = id
        self.title = title
        self.participantIDs = participantIDs
        self.typeRawValue = type.rawValue
        self.lastMessageID = lastMessageID
        self.lastMessagePreview = lastMessagePreview
        self.lastMessageTimestamp = lastMessageTimestamp
        self.unreadCount = unreadCount
        self.messages = messages
    }

    var type: ConversationType {
        get { ConversationType(rawValue: typeRawValue) ?? .oneOnOne }
        set { typeRawValue = newValue.rawValue }
    }
}

enum MessageStatus: String, Codable, CaseIterable, Sendable {
    case sending
    case sent
    case delivered
    case read
    case failed
}

@Model
final class MessageEntity {
    @Attribute(.unique) var id: String
    var conversationID: String
    var senderID: String
    var content: String
    var translatedContent: String?
    var timestamp: Date
    var statusRawValue: String
    @Attribute(.transformable) var readBy: [String]
    var isLocalOnly: Bool

    @Relationship(deleteRule: .nullify, inverse: \ConversationEntity.messages)
    var conversation: ConversationEntity?

    init(
        id: String,
        conversationID: String,
        senderID: String,
        content: String,
        translatedContent: String? = nil,
        timestamp: Date,
        status: MessageStatus,
        readBy: [String] = [],
        isLocalOnly: Bool = false
    ) {
        self.id = id
        self.conversationID = conversationID
        self.senderID = senderID
        self.content = content
        self.translatedContent = translatedContent
        self.timestamp = timestamp
        self.statusRawValue = status.rawValue
        self.readBy = readBy
        self.isLocalOnly = isLocalOnly
    }

    var status: MessageStatus {
        get { MessageStatus(rawValue: statusRawValue) ?? .sending }
        set { statusRawValue = newValue.rawValue }
    }
}

