import CryptoKit
import Foundation
import ImageIO
import Testing
@testable import KumoneCore

private final class ThumbnailFailureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

/// Holds requests to `hang.example.test` until the test releases them;
/// `ok.example.test` answers at once with a small valid JPEG.
private final class ThumbnailGateProtocol: URLProtocol, @unchecked Sendable {
    private struct State {
        var started: [String] = []
        var pending: [String: () -> Void] = [:]
    }

    nonisolated(unsafe) private static var state = State()
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        state = State()
    }

    static func startedCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return state.started.count
    }

    static func hasStarted(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return state.started.contains(url.absoluteString)
    }

    static func firstStarted() -> URL? {
        lock.lock(); defer { lock.unlock() }
        return state.started.first.flatMap(URL.init(string:))
    }

    static func finish(_ url: URL) {
        lock.lock()
        let answer = state.pending.removeValue(forKey: url.absoluteString)
        lock.unlock()
        answer?()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        if url.host != "hang.example.test" {
            deliver()
            return
        }
        Self.lock.lock()
        Self.state.started.append(url.absoluteString)
        Self.state.pending[url.absoluteString] = { [weak self] in self?.deliver() }
        Self.lock.unlock()
    }

    override func stopLoading() {}

    private func deliver() {
        guard let url = request.url else { return }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "image/jpeg"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: thumbnailTestImageData())
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func thumbnailTestImageData(width: Int = 8, height: Int = 8) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    _ = CGImageDestinationFinalize(destination)
    return data as Data
}

@Suite("Image thumbnails", .serialized)
struct ImageThumbnailTests {
    private let cover = "https://example.test/large-cover.jpg"

    @Test func resizingReplacesAnExistingSizeAndPreservesOtherParameters() throws {
        let url = try #require("http://example.test/cover.jpg?param=2048y2048&version=2".resizedImageURL(96))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.queryItems?.filter { $0.name == "param" }.map(\.value) == ["96y96"])
        #expect(components.queryItems?.first { $0.name == "version" }?.value == "2")
    }

    @Test(arguments: [false, true])
    func originalArtworkIsDecodedAtTheRequestedSize(fromDisk: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try largeCover()
        let url = try #require(cover.resizedImageURL(96))
        if fromDisk { try seed(data, url: url, root: root) }
        let cache = ImageCache(directory: root, offlineArtwork: { _ in data })

        let image = try #require(await cache.image(for: url))
        let pixels = try cgImage(image)
        #expect(pixels.width == 96 && pixels.height == 48)
        #expect(pixels.bytesPerRow * pixels.height <= 96 * 48 * 8)
        #expect(try cgImage(#require(cache.cachedImage(for: url))).width == 96)

        // A row thumbnail must not replace the larger detail rendition.
        let detailURL = try #require(cover.resizedImageURL(768))
        let detail = try #require(await cache.image(for: detailURL))
        #expect(try cgImage(detail).width == 768)
        #expect(try cgImage(#require(cache.cachedImage(for: url))).width == 96)
    }

    @Test(arguments: [false, true])
    func largerFallbackIsBoundedWithoutBeingCachedAsAnExactAnswer(warmMemory: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let largeURL = try #require(cover.resizedImageURL(768))
        try seed(largeCover(), url: largeURL, root: root)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ThumbnailFailureProtocol.self]
        let cache = ImageCache(directory: root, session: URLSession(configuration: config), offlineArtwork: { _ in nil })
        if warmMemory { _ = await cache.image(for: largeURL) }
        let smallURL = try #require(cover.resizedImageURL(96))
        let image = try #require(await cache.image(for: smallURL, onCachedImage: { preview in
            #expect(preview.size.width == 96 && preview.size.height == 48)
        }))
        #expect(try cgImage(image).width == 96)
        #expect(cache.cachedImage(for: smallURL) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 1)
    }

    @Test func smallOriginalIsNotUpscaled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try largeCover(width: 32, height: 16)
        let cache = ImageCache(directory: root, offlineArtwork: { _ in data })
        let url = try #require(cover.resizedImageURL(96))
        let image = try #require(await cache.image(for: url))
        #expect(try cgImage(image).width == 32)
    }

    @Test func fourHangingThumbnailsUseAtMostThreeNetworkSlots() async throws {
        ThumbnailGateProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ImageCache(directory: root, session: gateSession(),
                               thumbnailLimiter: ThumbnailRequestLimiter(limit: 3),
                               offlineArtwork: { _ in nil })
        let urls = try (1...4).map {
            try #require("https://hang.example.test/avatar-\($0).jpg".resizedImageURL(48))
        }

        let tasks = urls.map { url in Task { await cache.image(for: url) } }
        #expect(await waitUntil { ThumbnailGateProtocol.startedCount() == 3 })
        // Give a faulty fourth request time to slip through.
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(ThumbnailGateProtocol.startedCount() == 3)

        let started = try #require(ThumbnailGateProtocol.firstStarted())
        ThumbnailGateProtocol.finish(started)
        #expect(await waitUntil { ThumbnailGateProtocol.startedCount() == 4 })

        for url in urls { ThumbnailGateProtocol.finish(url) }
        for task in tasks { _ = await task.value }
    }

    @Test func cachedThumbnailsDoNotConsumeTheNetworkLimit() async throws {
        ThumbnailGateProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ImageCache(directory: root, session: gateSession(),
                               thumbnailLimiter: ThumbnailRequestLimiter(limit: 1),
                               offlineArtwork: { _ in nil })
        let data = thumbnailTestImageData()
        let warmURL = try #require("https://ok.example.test/warm.jpg".resizedImageURL(48))
        let diskURL = try #require("https://ok.example.test/disk.jpg".resizedImageURL(48))
        try seed(data, url: diskURL, root: root)
        #expect(await cache.image(for: warmURL) != nil)

        // Occupy the only slot with a request that never answers.
        let hangingURL = try #require("https://hang.example.test/avatar.jpg".resizedImageURL(48))
        let hanging = Task { await cache.image(for: hangingURL) }
        #expect(await waitUntil { ThumbnailGateProtocol.hasStarted(hangingURL) })

        // Disk and memory hits return while the network slot is taken.
        #expect(await cache.image(for: diskURL) != nil)
        #expect(await cache.image(for: warmURL) != nil)

        ThumbnailGateProtocol.finish(hangingURL)
        _ = await hanging.value
    }

    @Test func ordinaryImagesAreNotRateLimited() async throws {
        ThumbnailGateProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ImageCache(directory: root, session: gateSession(),
                               thumbnailLimiter: ThumbnailRequestLimiter(limit: 1),
                               offlineArtwork: { _ in nil })
        let hangingURL = try #require("https://hang.example.test/avatar.jpg".resizedImageURL(48))
        let hanging = Task { await cache.image(for: hangingURL) }
        #expect(await waitUntil { ThumbnailGateProtocol.hasStarted(hangingURL) })

        // No `param` hint: artwork, audio and lyrics keep their own path.
        let plainURL = try #require(URL(string: "https://ok.example.test/plain.jpg"))
        #expect(await cache.image(for: plainURL) != nil)

        ThumbnailGateProtocol.finish(hangingURL)
        _ = await hanging.value
    }

    private func gateSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ThumbnailGateProtocol.self]
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func largeCover(width: Int = 2_048, height: Int = 1_024) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func seed(_ data: Data, url: URL, root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let key = Insecure.MD5.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        try data.write(to: root.appendingPathComponent(key))
    }

    private func cgImage(_ image: PlatformImage) throws -> CGImage {
        #if os(macOS)
        return try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #else
        return try #require(image.cgImage)
        #endif
    }
}
