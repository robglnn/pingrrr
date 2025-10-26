import Foundation
import UIKit

enum ProfileImageSize: CaseIterable, Sendable {
    case regular
    case mini

    var pixelDimension: CGFloat {
        switch self {
        case .regular:
            return 48
        case .mini:
            return 16
        }
    }

    var cacheSuffix: String {
        switch self {
        case .regular:
            return "regular"
        case .mini:
            return "mini"
        }
    }
}

protocol ProfileImageDataSource {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: ProfileImageDataSource {}

actor ProfileImageCache {
    struct Descriptor: Hashable {
        let userID: String
        let url: URL
        let photoVersion: Int

        fileprivate var cacheKey: String {
            "\(userID)_v\(photoVersion)"
        }
    }

    enum CacheError: Error {
        case missingImage
        case invalidImageData
    }

    static let shared = ProfileImageCache()

    private let memoryCache = NSCache<NSString, UIImage>()
    private var inFlightSourceTasks: [String: Task<Data, Error>] = [:]
    private var inFlightVariantTasks: [String: Task<UIImage, Error>] = [:]
    private var keyIndex: [String: Set<String>] = [:]
    private let fileManager = FileManager.default
    private let diskDirectory: URL
    private let session: ProfileImageDataSource
    private let observesNotifications: Bool
    private var memoryWarningObserver: NSObjectProtocol?

    init(session: ProfileImageDataSource = URLSession.shared, diskDirectory: URL? = nil, observesSystemNotifications: Bool = true) {
        self.session = session
        self.observesNotifications = observesSystemNotifications
        if let diskDirectory {
            self.diskDirectory = diskDirectory
        } else {
            let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
            self.diskDirectory = base.appendingPathComponent("ProfileImageCache", isDirectory: true)
        }

        if !fileManager.fileExists(atPath: self.diskDirectory.path) {
            try? fileManager.createDirectory(at: self.diskDirectory, withIntermediateDirectories: true)
        }

        if observesSystemNotifications {
            Task { await self.registerMemoryWarningObserver() }
        }
    }

    deinit {
        if let token = memoryWarningObserver {
            Task { await MainActor.run { NotificationCenter.default.removeObserver(token) } }
        }
    }

    func image(for descriptor: Descriptor, size: ProfileImageSize) async throws -> UIImage {
        let variantKey = variantCacheKey(for: descriptor, size: size)

        if let cached = memoryCache.object(forKey: variantKey as NSString) {
            return cached
        }

        if let diskImage = loadImageFromDisk(for: descriptor, size: size) {
            memoryCache.setObject(diskImage, forKey: variantKey as NSString)
            index(key: variantKey, for: descriptor.userID)
            return diskImage
        }

        if let task = inFlightVariantTasks[variantKey] {
            return try await task.value
        }

        let task = Task<UIImage, Error> {
            let sourceData = try await sourceData(for: descriptor)
            let image = try await generateVariant(from: sourceData, size: size)
            store(image: image, for: descriptor, size: size)
            return image
        }

        inFlightVariantTasks[variantKey] = task
        defer { inFlightVariantTasks[variantKey] = nil }

        return try await task.value
    }

    func invalidate(userID: String) async {
        guard let keys = keyIndex[userID] else { return }
        keyIndex[userID] = nil

        for key in keys {
            memoryCache.removeObject(forKey: key as NSString)
            let url = diskDirectory.appendingPathComponent("\(key).cache")
            try? fileManager.removeItem(at: url)
        }

        let sourcePrefix = "\(userID)_v"
        if let contents = try? fileManager.contentsOfDirectory(at: diskDirectory, includingPropertiesForKeys: nil) {
            for file in contents where file.lastPathComponent.hasPrefix(sourcePrefix) {
                try? fileManager.removeItem(at: file)
            }
        }
    }

    func invalidate(userID: String, photoVersion: Int?) async {
        guard let photoVersion else {
            await invalidate(userID: userID)
            return
        }
        let baseKey = "\(userID)_v\(photoVersion)"
        for size in ProfileImageSize.allCases {
            let key = "\(baseKey)_\(size.cacheSuffix)"
            memoryCache.removeObject(forKey: key as NSString)
            let url = diskDirectory.appendingPathComponent("\(key).cache")
            try? fileManager.removeItem(at: url)
            keyIndex[userID]?.remove(key)
        }

        let sourceURL = diskDirectory.appendingPathComponent("\(baseKey)_source.cache")
        try? fileManager.removeItem(at: sourceURL)
    }

    func clearMemory() {
        memoryCache.removeAllObjects()
    }

    func removeAll() async {
        memoryCache.removeAllObjects()
        inFlightSourceTasks.removeAll()
        inFlightVariantTasks.removeAll()
        keyIndex.removeAll()
        if let contents = try? fileManager.contentsOfDirectory(at: diskDirectory, includingPropertiesForKeys: nil) {
            for file in contents {
                try? fileManager.removeItem(at: file)
            }
        }
    }

    // MARK: - Private Helpers

    private func variantCacheKey(for descriptor: Descriptor, size: ProfileImageSize) -> String {
        "\(descriptor.cacheKey)_\(size.cacheSuffix)"
    }

    private func sourceCacheURL(for descriptor: Descriptor) -> URL {
        diskDirectory.appendingPathComponent("\(descriptor.cacheKey)_source.cache")
    }

    private func variantCacheURL(for descriptor: Descriptor, size: ProfileImageSize) -> URL {
        diskDirectory.appendingPathComponent("\(variantCacheKey(for: descriptor, size: size)).cache")
    }

    private func loadImageFromDisk(for descriptor: Descriptor, size: ProfileImageSize) -> UIImage? {
        let url = variantCacheURL(for: descriptor, size: size)
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
            return nil
        }
        return image
    }

    private func store(image: UIImage, for descriptor: Descriptor, size: ProfileImageSize) {
        let key = variantCacheKey(for: descriptor, size: size)
        memoryCache.setObject(image, forKey: key as NSString)
        index(key: key, for: descriptor.userID)

        let url = variantCacheURL(for: descriptor, size: size)
        if let data = image.pngData() {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func index(key: String, for userID: String) {
        var keys = keyIndex[userID] ?? []
        keys.insert(key)
        keyIndex[userID] = keys
    }

    @Sendable
    private func registerMemoryWarningObserver() async {
        let token = await MainActor.run {
            NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
                Task { await self?.clearMemory() }
            }
        }
        memoryWarningObserver = token
    }

    private func sourceData(for descriptor: Descriptor) async throws -> Data {
        let cacheURL = sourceCacheURL(for: descriptor)
        if let data = try? Data(contentsOf: cacheURL) {
            return data
        }

        if let task = inFlightSourceTasks[descriptor.cacheKey] {
            return try await task.value
        }

        let task = Task<Data, Error> {
            var request = URLRequest(url: descriptor.url)
            request.cachePolicy = .returnCacheDataElseLoad
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 else {
                throw CacheError.missingImage
            }
            try data.write(to: cacheURL, options: .atomic)
            return data
        }

        inFlightSourceTasks[descriptor.cacheKey] = task
        defer { inFlightSourceTasks[descriptor.cacheKey] = nil }

        return try await task.value
    }

    private func generateVariant(from data: Data, size: ProfileImageSize) async throws -> UIImage {
        guard let original = UIImage(data: data) else { throw CacheError.invalidImageData }
        return resize(image: original, to: CGSize(width: size.pixelDimension, height: size.pixelDimension))
    }

    private func resize(image: UIImage, to targetSize: CGSize) -> UIImage {
        let scale = max(targetSize.width / image.size.width, targetSize.height / image.size.height)
        let scaledSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            let origin = CGPoint(
                x: (targetSize.width - scaledSize.width) / 2,
                y: (targetSize.height - scaledSize.height) / 2
            )
            image.draw(in: CGRect(origin: origin, size: scaledSize))
        }
    }
}
