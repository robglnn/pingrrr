import XCTest
import UIKit
@testable import pingrrr

final class ProfileImageCacheTests: XCTestCase {
    func testDownloadsOnlyOncePerVersion() async throws {
        let tempDirectory = makeTemporaryDirectory()
        let imageData = makeImageData(color: .systemBlue)
        let fetcher = MockImageFetcher(imageData: imageData)
        let cache = ProfileImageCache(session: fetcher, diskDirectory: tempDirectory, observesSystemNotifications: false)

        let url = URL(string: "https://example.com/avatar.jpg")!
        let descriptorV1 = ProfileImageCache.Descriptor(userID: "user-123", url: url, photoVersion: 1)

        _ = try await cache.image(for: descriptorV1, size: .regular)
        _ = try await cache.image(for: descriptorV1, size: .mini)
        _ = try await cache.image(for: descriptorV1, size: .regular)

        XCTAssertEqual(fetcher.callCount, 1, "Image should only be downloaded once for the same version")

        let descriptorV2 = ProfileImageCache.Descriptor(userID: "user-123", url: url, photoVersion: 2)
        _ = try await cache.image(for: descriptorV2, size: .regular)
        XCTAssertEqual(fetcher.callCount, 2, "New photo version should trigger a new download")

        await cache.removeAll()
        cleanup(directory: tempDirectory)
    }

    func testDiskCacheHitRequiresNoNetwork() async throws {
        let tempDirectory = makeTemporaryDirectory()
        let imageData = makeImageData(color: .systemPink)
        let primaryFetcher = MockImageFetcher(imageData: imageData)
        let descriptor = ProfileImageCache.Descriptor(
            userID: "user-456",
            url: URL(string: "https://example.com/avatar.png")!,
            photoVersion: 3
        )

        // Prime the cache
        let primaryCache = ProfileImageCache(session: primaryFetcher, diskDirectory: tempDirectory, observesSystemNotifications: false)
        _ = try await primaryCache.image(for: descriptor, size: .regular)
        XCTAssertEqual(primaryFetcher.callCount, 1)

        // New cache instance should read from disk without making a network call
        let secondaryFetcher = MockImageFetcher(imageData: imageData)
        let secondaryCache = ProfileImageCache(session: secondaryFetcher, diskDirectory: tempDirectory, observesSystemNotifications: false)
        _ = try await secondaryCache.image(for: descriptor, size: .regular)
        XCTAssertEqual(secondaryFetcher.callCount, 0, "Disk cache should satisfy the request without hitting the network")

        await primaryCache.removeAll()
        await secondaryCache.removeAll()
        cleanup(directory: tempDirectory)
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cleanup(directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeImageData(color: UIColor) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 120))
        let image = renderer.image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: CGSize(width: 120, height: 120)))
        }
        return image.pngData() ?? Data()
    }
}

private final class MockImageFetcher: ProfileImageDataSource {
    private(set) var callCount = 0
    private let imageData: Data

    init(imageData: Data) {
        self.imageData = imageData
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        callCount += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (imageData, response)
    }
}
