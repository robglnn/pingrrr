import Foundation
import Combine
import FirebaseStorage
import UIKit

@MainActor
final class MediaService: ObservableObject {
    enum MediaError: LocalizedError {
        case invalidURL
        case uploadFailed

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid media URL"
            case .uploadFailed:
                return "Failed to upload media"
            }
        }
    }

    struct CachedMedia {
        let url: URL
        let type: MessageMediaType
        let timestamp: Date
    }

    private let storage = Storage.storage()
    private let cacheDirectory: URL
    private let cacheTimeout: TimeInterval = 21_600 // 6 hours
    private let recentCount = 5

    @Published private(set) var recentMedia: [String: CachedMedia] = [:]

    init() {
        let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        cacheDirectory = cachesDirectory.appendingPathComponent("media_cache")
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func upload(media data: Data, type: MessageMediaType, conversationID: String) async throws -> String {
        let filename = UUID().uuidString + "." + type.fileExtension
        let storageRef = storage.reference().child("conversations/\(conversationID)/\(filename)")

        let metadata = StorageMetadata()
        metadata.contentType = type.mimeType

        do {
            _ = try await storageRef.putDataAsync(data, metadata: metadata)
            let downloadURL = try await storageRef.downloadURL()
            cache(data: data, urlString: downloadURL.absoluteString, type: type)
            return downloadURL.absoluteString
        } catch {
            throw MediaError.uploadFailed
        }
    }

    func downloadMedia(at urlString: String, type: MessageMediaType) async throws -> Data {
        if let cached = cachedData(for: urlString) {
            recentMedia[urlString] = cached
            return try Data(contentsOf: cached.url)
        }

        guard let url = URL(string: urlString) else {
            throw MediaError.invalidURL
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        cache(data: data, urlString: urlString, type: type)
        return data
    }

    private func cache(data: Data, urlString: String, type: MessageMediaType) {
        let filename = URL(string: urlString)?.lastPathComponent ?? UUID().uuidString
        let fileURL = cacheDirectory.appendingPathComponent(filename)
        do {
            try data.write(to: fileURL, options: [.atomic])
        let cacheEntry = CachedMedia(url: fileURL, type: type, timestamp: Date())
            recentMedia[urlString] = cacheEntry
            trimRecentMediaIfNeeded()
        } catch {
            print("[MediaService] Failed to cache media: \(error)")
        }
    }

    private func cachedData(for urlString: String) -> CachedMedia? {
        guard let cached = recentMedia[urlString] else { return nil }
        if Date().timeIntervalSince(cached.timestamp) > cacheTimeout {
            try? FileManager.default.removeItem(at: cached.url)
            recentMedia[urlString] = nil
            return nil
        }
        return cached
    }

    private func trimRecentMediaIfNeeded() {
        guard recentMedia.count > recentCount else { return }
        let sorted = recentMedia.sorted { $0.value.timestamp < $1.value.timestamp }
        let toRemove = sorted.prefix(recentMedia.count - recentCount)
        for (urlString, cache) in toRemove {
            try? FileManager.default.removeItem(at: cache.url)
            recentMedia[urlString] = nil
        }
    }
}

enum MediaError: LocalizedError {
    case unused
}
