import Foundation
import SwiftData
import Combine

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
    var hiddenForUserIDsString: String?

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
        unreadCount: Int = 0,
        hiddenForUserIDs: [String] = []
    ) {
        self.id = id
        self.title = title
        self.participantIDsString = ConversationEntity.encodeIDs(participantIDs)
        self.typeRawValue = type.rawValue
        self.lastMessageID = lastMessageID
        self.lastMessagePreview = lastMessagePreview
        self.lastMessageTimestamp = lastMessageTimestamp
        self.unreadCount = unreadCount
        self.hiddenForUserIDsString = ConversationEntity.encodeIDs(hiddenForUserIDs)
    }

    var type: ConversationType {
        get { ConversationType(rawValue: typeRawValue) ?? .oneOnOne }
        set { typeRawValue = newValue.rawValue }
    }

    var participantIDs: [String] {
        get { ConversationEntity.decodeIDs(participantIDsString) }
        set { participantIDsString = ConversationEntity.encodeIDs(newValue) }
    }

    var hiddenForUserIDs: [String] {
        get { ConversationEntity.decodeIDs(hiddenForUserIDsString ?? "[]") }
        set { hiddenForUserIDsString = ConversationEntity.encodeIDs(newValue) }
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

enum MessageMediaType: String, Codable, CaseIterable, Sendable {
    case image
    case voice
}

extension MessageMediaType {
    var fileExtension: String {
        switch self {
        case .image: return "jpg"
        case .voice: return "m4a"
        }
    }

    var mimeType: String {
        switch self {
        case .image: return "image/jpeg"
        case .voice: return "audio/m4a"
        }
    }

    var previewText: String {
        switch self {
        case .image: return "Sent a photo"
        case .voice: return "Sent a voice message"
        }
    }
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
    var mediaURL: String?
    var mediaTypeRawValue: String?
    var voiceDurationSeconds: Double?

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
        nextRetryTimestamp: Date? = nil,
        mediaURL: String? = nil,
        mediaType: MessageMediaType? = nil,
        voiceDurationSeconds: Double? = nil
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
        self.mediaURL = mediaURL
        self.mediaTypeRawValue = mediaType?.rawValue
        self.voiceDurationSeconds = voiceDurationSeconds
    }

    var status: MessageStatus {
        get { MessageStatus(rawValue: statusRawValue) ?? .sending }
        set { statusRawValue = newValue.rawValue }
    }

    var readBy: [String] {
        get { MessageEntity.decodeIDs(readByString) }
        set { readByString = MessageEntity.encodeIDs(newValue) }
    }

    var mediaType: MessageMediaType? {
        get {
            guard let mediaTypeRawValue else { return nil }
            return MessageMediaType(rawValue: mediaTypeRawValue)
        }
        set {
            mediaTypeRawValue = newValue?.rawValue
        }
    }

    var mediaURLValue: URL? {
        guard let mediaURL else { return nil }
        return URL(string: mediaURL)
    }

    var voiceDuration: TimeInterval? {
        get { voiceDurationSeconds }
        set { voiceDurationSeconds = newValue }
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

@Model
final class ConversationPreferenceEntity {
    @Attribute(.unique) var conversationID: String
    var isHidden: Bool

    init(conversationID: String, isHidden: Bool = false) {
        self.conversationID = conversationID
        self.isHidden = isHidden
    }
}

