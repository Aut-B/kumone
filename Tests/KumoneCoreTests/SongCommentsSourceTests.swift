import Foundation
import Testing
@testable import KumoneCore

private func makeTrack(id: Int = 42, isCloud: Bool = false, platform: String? = nil,
                       itemID: String = "BV1xx411c7m2",
                       rawJSON: String = "{}") throws -> Track {
    var object: [String: Any] = ["id": id, "name": "track"]
    if isCloud { object["pc"] = [String: String]() }
    if let platform {
        object["plugin"] = ["platform": platform, "itemID": itemID, "rawJSON": rawJSON]
    }
    let data = try JSONSerialization.data(withJSONObject: object)
    return try JSONDecoder().decode(Track.self, from: data)
}

private func json(_ object: Any) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
}

@Suite("Song comment availability")
struct SongCommentAvailabilityTests {
    @Test func cloudTracksHaveNoComments() throws {
        let cloud = try makeTrack(isCloud: true, platform: "bilibili", rawJSON: #"{"aid":123}"#)
        #expect(SongCommentAvailability.source(for: cloud) == .unavailable)
        #expect(!SongCommentAvailability.isAvailable(for: cloud))
    }

    @Test func unknownPluginPlatformsHaveNoComments() throws {
        let unknown = try makeTrack(platform: "kugou", rawJSON: #"{"aid":123}"#)
        #expect(SongCommentAvailability.source(for: unknown) == .unavailable)
        #expect(!SongCommentAvailability.isAvailable(for: unknown))
    }

    @Test func shortVideoFavouritesHaveNoComments() throws {
        let douyin = try makeTrack(platform: "douyin", itemID: "7400000000000000000")
        #expect(SongCommentAvailability.source(for: douyin) == .unavailable)
        #expect(!SongCommentAvailability.isAvailable(for: douyin))
        #expect(SongCommentAvailability.isShortVideoTrack(douyin))

        let tiktok = try makeTrack(platform: "TikTok", itemID: "7400000000000000001")
        #expect(!SongCommentAvailability.isAvailable(for: tiktok))
        #expect(SongCommentAvailability.isShortVideoTrack(tiktok))

        let netease = try makeTrack(id: 186016)
        #expect(!SongCommentAvailability.isShortVideoTrack(netease))
        let bilibili = try makeTrack(platform: "bilibili", rawJSON: #"{"aid":123}"#)
        #expect(!SongCommentAvailability.isShortVideoTrack(bilibili))
    }

    @Test func neteaseTracksNeedASongID() throws {
        let song = try makeTrack(id: 186016)
        #expect(SongCommentAvailability.source(for: song) == .netease)
        #expect(SongCommentAvailability.isAvailable(for: song))

        let empty = try makeTrack(id: 0)
        #expect(SongCommentAvailability.source(for: empty) == .unavailable)
    }

    @Test func bilibiliTracksNeedAPlatformAndAnID() throws {
        let aid = try makeTrack(platform: "bilibili", rawJSON: #"{"aid":123}"#)
        #expect(SongCommentAvailability.source(for: aid) == .bilibili)

        let name = try makeTrack(platform: "哔哩哔哩 (官方)", itemID: "BV1xx411c7m2")
        #expect(SongCommentAvailability.source(for: name) == .bilibili)

        let short = try makeTrack(platform: "B站", rawJSON: #"{"bvid":"BV1xx411c7m2"}"#)
        #expect(SongCommentAvailability.source(for: short) == .bilibili)

        let noID = try makeTrack(platform: "bilibili", itemID: "av42")
        #expect(SongCommentAvailability.source(for: noID) == .unavailable)
    }
}

/// Serves scripted Bilibili bodies and records the query each request used.
private final class BilibiliCommentsProtocol: URLProtocol, @unchecked Sendable {
    struct Recorded: Sendable {
        let path: String
        let query: [String: String]
    }

    typealias Handler = @Sendable (Recorded) -> (status: Int, body: String)

    private nonisolated(unsafe) static var handler: Handler = { _ in (200, #"{"code":0,"data":{}}"#) }
    private nonisolated(unsafe) static var recorded: [Recorded] = []
    /// The first matching request stays in flight until the test answers it,
    /// so slow-page tests need not block a URL loading thread.
    nonisolated(unsafe) private static var deferPredicate: (@Sendable (Recorded) -> Bool)?
    nonisolated(unsafe) private static var deferred: ((Int, String) -> Void)?
    private static let lock = NSLock()

    static func reset(_ handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
        recorded = []
        deferPredicate = nil
        deferred = nil
    }

    static var requests: [Recorded] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    static var hasDeferredRequest: Bool {
        lock.lock(); defer { lock.unlock() }
        return deferred != nil
    }

    static func deferNext(matching predicate: @escaping @Sendable (Recorded) -> Bool) {
        lock.lock(); defer { lock.unlock() }
        deferPredicate = predicate
    }

    static func answerDeferred(status: Int, body: String) {
        lock.lock()
        let answer = deferred
        deferred = nil
        lock.unlock()
        answer?(status, body)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let recorded = Recorded(path: request.url?.path ?? "", query: Self.queryItems(request.url))
        Self.lock.lock()
        Self.recorded.append(recorded)
        let handler = Self.handler
        let shouldDefer = Self.deferPredicate?(recorded) ?? false
        if shouldDefer {
            Self.deferPredicate = nil
            Self.deferred = { [weak self] status, body in
                self?.deliver(status: status, body: body)
            }
        }
        Self.lock.unlock()
        let (status, body) = handler(recorded)
        if shouldDefer { return }
        deliver(status: status, body: body)
    }

    private func deliver(status: Int, body: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func queryItems(_ url: URL?) -> [String: String] {
        guard let url,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return [:] }
        return Dictionary(uniqueKeysWithValues: items.compactMap { item in
            item.value.map { (item.name, $0) }
        })
    }
}

private func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [BilibiliCommentsProtocol.self]
    return URLSession(configuration: configuration)
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<400 {
        if condition() { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    Issue.record("timed out waiting for the expected state")
}

private func biliComment(_ rpid: Int) -> [String: Any] {
    [
        "rpid": rpid,
        "member": ["mid": 7, "uname": "up-\(rpid)", "avatar": "https://example/a.jpg"],
        "content": ["message": "comment-\(rpid)"],
        "ctime": 1_700_000_000,
        "like": 3,
    ]
}

private func biliPage(_ comments: [[String: Any]], count: Int, isEnd: Bool) -> String {
    json([
        "code": 0,
        "data": [
            "replies": comments,
            "page": ["count": count],
            "isEnd": isEnd,
        ],
    ])
}

/// The comment endpoints fetch a day-scoped WBI key pair before their first
/// signed page request; page tests answer that round-trip too.
private func isWBIKeyRequest(_ request: BilibiliCommentsProtocol.Recorded) -> Bool {
    request.path.hasSuffix("GenWebTicket")
}

private func biliWBIKeys() -> String {
    json(["code": 0, "data": ["nav": [
        "img": "https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png",
        "sub": "https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png",
    ]]])
}

@Suite("Song comment sources", .serialized)
@MainActor
struct SongCommentsSourceTests {
    @Test func theSongIDInitializerStaysOnNetease() {
        let content = SongCommentsContent(songID: 186016)
        #expect(content.source == .netease)
        #expect(content.supportsLikes)
    }

    @Test func bilibiliFirstPageAsksHotAndLatestThenPagesLatest() async throws {
        BilibiliCommentsProtocol.reset { request in
            let sort = request.query["sort"]
            let page = request.query["pn"]
            if sort == "2", page == "1" {
                // A repeated rpid must be shown once.
                return (200, biliPage([biliComment(100), biliComment(100), biliComment(101)],
                                      count: 4, isEnd: false))
            }
            if sort == "0", page == "1" {
                return (200, biliPage([biliComment(1), biliComment(2)], count: 4, isEnd: false))
            }
            if sort == "0", page == "2" {
                return (200, biliPage([biliComment(2), biliComment(3)], count: 4, isEnd: true))
            }
            return (500, "")
        }
        let track = try makeTrack(platform: "bilibili", rawJSON: #"{"aid":123}"#)
        let content = SongCommentsContent(track: track, pageSize: 2, session: makeSession())

        await content.loadFirstPage()
        #expect(content.phase == .loaded)
        #expect(content.source == .bilibili)
        #expect(!content.supportsLikes)
        #expect(content.hot.map(\.id) == [100, 101])
        #expect(content.latest.map(\.id) == [1, 2])
        #expect(content.total == 4 && content.hasMore)

        await content.loadMore()
        #expect(content.latest.map(\.id) == [1, 2, 3])
        #expect(!content.hasMore)

        let requests = BilibiliCommentsProtocol.requests
        #expect(requests.map { $0.query["sort"] } == ["2", "0", "0"])
        #expect(requests.map { $0.query["pn"] } == ["1", "1", "2"])
        #expect(requests.allSatisfy {
            $0.path == "/x/v2/reply" && $0.query["type"] == "1"
                && $0.query["oid"] == "123" && $0.query["ps"] == "2"
        })
    }

    @Test func aBVOnlyTrackResolvesTheAIDOnce() async throws {
        BilibiliComments.resetAIDCacheForTesting()
        defer { BilibiliComments.resetAIDCacheForTesting() }
        BilibiliCommentsProtocol.reset { request in
            if request.path == "/x/web-interface/view" {
                return (200, #"{"code":0,"data":{"aid":123}}"#)
            }
            if request.query["sort"] == "2" {
                return (200, biliPage([biliComment(100)], count: 3, isEnd: false))
            }
            if request.query["pn"] == "1" {
                return (200, biliPage([biliComment(1)], count: 3, isEnd: false))
            }
            return (200, biliPage([biliComment(2)], count: 3, isEnd: true))
        }
        let track = try makeTrack(platform: "bilibili", itemID: "BV1aidonly411c7")
        let content = SongCommentsContent(track: track, pageSize: 1, session: makeSession())

        await content.loadFirstPage()
        await content.loadMore()

        let requests = BilibiliCommentsProtocol.requests
        #expect(requests.map(\.path) == ["/x/web-interface/view", "/x/v2/reply", "/x/v2/reply", "/x/v2/reply"])
        #expect(requests.filter { $0.path == "/x/web-interface/view" }.count == 1)
        #expect(requests.filter { $0.path == "/x/v2/reply" }.allSatisfy { $0.query["oid"] == "123" })
        #expect(content.latest.map(\.id) == [1, 2])
    }

    @Test func unavailableTracksLoadEmptyWithoutRequests() async throws {
        BilibiliCommentsProtocol.reset { _ in (200, #"{"code":0,"data":{}}"#) }
        let content = SongCommentsContent(track: try makeTrack(isCloud: true), session: makeSession())

        #expect(content.phase == .loaded && content.source == .unavailable)
        await content.loadFirstPage()
        await content.loadMore()

        #expect(content.phase == .loaded && content.isEmpty && !content.hasMore)
        #expect(BilibiliCommentsProtocol.requests.isEmpty)
    }

    @Test func bilibiliCommentsAreNotLikeable() async throws {
        BilibiliCommentsProtocol.reset { request in
            request.query["sort"] == "2"
                ? (200, biliPage([biliComment(100)], count: 1, isEnd: true))
                : (200, biliPage([biliComment(1)], count: 1, isEnd: true))
        }
        let track = try makeTrack(platform: "bilibili", rawJSON: #"{"aid":123}"#)
        let content = SongCommentsContent(track: track, session: makeSession())
        await content.loadFirstPage()
        let count = BilibiliCommentsProtocol.requests.count

        try await content.toggleLike(commentID: 100)

        #expect(BilibiliCommentsProtocol.requests.count == count)
        #expect(content.hot.first?.liked == false)
        #expect(content.hot.first?.likedCount == 3)
    }

    @Test func hotFirstShowsCommentsWhileLatestIsDelayed() async throws {
        BilibiliCommentsProtocol.reset { request in
            if isWBIKeyRequest(request) { return (200, biliWBIKeys()) }
            if request.query["mode"] == "3" {
                return (200, biliPage([biliComment(100), biliComment(100), biliComment(101)],
                                      count: 4, isEnd: false))
            }
            return (200, biliPage([biliComment(1), biliComment(1), biliComment(2)],
                                  count: 4, isEnd: false))
        }
        BilibiliCommentsProtocol.deferNext { $0.query["mode"] == "2" }
        let track = try makeTrack(id: 9101, platform: "bilibili", rawJSON: #"{"aid":123}"#)
        let content = SongCommentsContent(track: track, pageSize: 2, session: makeSession())

        let load = Task { await content.loadFirstPage() }
        try await waitUntil { BilibiliCommentsProtocol.hasDeferredRequest }
        try await waitUntil { content.phase == .loaded }

        #expect(content.phase == .loaded)
        #expect(content.hot.map(\.id) == [100, 101])
        #expect(content.latest.isEmpty)

        BilibiliCommentsProtocol.answerDeferred(
            status: 200,
            body: biliPage([biliComment(1), biliComment(1), biliComment(2)], count: 4, isEnd: false))
        await load.value

        #expect(content.phase == .loaded)
        #expect(content.hot.map(\.id) == [100, 101])
        #expect(content.latest.map(\.id) == [1, 2])
        #expect(content.total == 4 && content.hasMore)
    }

    @Test func hotSurvivesALatestFailure() async throws {
        BilibiliCommentsProtocol.reset { request in
            if isWBIKeyRequest(request) { return (200, biliWBIKeys()) }
            return request.query["mode"] == "3"
                ? (200, biliPage([biliComment(100)], count: 2, isEnd: false))
                : (500, "")
        }
        let track = try makeTrack(id: 9102, platform: "bilibili", rawJSON: #"{"aid":123}"#)
        let content = SongCommentsContent(track: track, pageSize: 2, session: makeSession())

        await content.loadFirstPage()

        #expect(content.phase == .loaded)
        #expect(content.hot.map(\.id) == [100])
        #expect(content.latest.isEmpty)
    }

    @Test func latestFillsInWhenHotFails() async throws {
        BilibiliCommentsProtocol.reset { request in
            if isWBIKeyRequest(request) { return (200, biliWBIKeys()) }
            return request.query["mode"] == "3"
                ? (500, "")
                : (200, biliPage([biliComment(7)], count: 3, isEnd: true))
        }
        let track = try makeTrack(id: 9103, platform: "bilibili", rawJSON: #"{"aid":123}"#)
        let content = SongCommentsContent(track: track, pageSize: 2, session: makeSession())

        await content.loadFirstPage()

        #expect(content.phase == .loaded)
        #expect(content.hot.isEmpty)
        #expect(content.latest.map(\.id) == [7])
    }

    @Test func cancellingAfterHotKeepsHotLoaded() async throws {
        BilibiliCommentsProtocol.reset { request in
            if isWBIKeyRequest(request) { return (200, biliWBIKeys()) }
            if request.query["mode"] == "3" {
                return (200, biliPage([biliComment(100)], count: 2, isEnd: false))
            }
            return (200, biliPage([biliComment(1)], count: 2, isEnd: false))
        }
        BilibiliCommentsProtocol.deferNext { $0.query["mode"] == "2" }
        let track = try makeTrack(id: 9104, platform: "bilibili", rawJSON: #"{"aid":123}"#)
        let content = SongCommentsContent(track: track, pageSize: 2, session: makeSession())

        let load = Task { await content.loadFirstPage() }
        try await waitUntil { BilibiliCommentsProtocol.hasDeferredRequest }
        try await waitUntil { content.phase == .loaded }
        #expect(content.hot.map(\.id) == [100])

        load.cancel()
        BilibiliCommentsProtocol.answerDeferred(
            status: 200, body: biliPage([biliComment(1)], count: 2, isEnd: false))
        await load.value

        #expect(content.phase == .loaded)
        #expect(content.hot.map(\.id) == [100])
    }

    @Test func staleLatestDoesNotAppendToTheRetriedPage() async throws {
        BilibiliCommentsProtocol.reset { request in
            if isWBIKeyRequest(request) { return (200, biliWBIKeys()) }
            if request.query["mode"] == "3" {
                return (200, biliPage([biliComment(100)], count: 3, isEnd: false))
            }
            return (200, biliPage([biliComment(2)], count: 3, isEnd: false))
        }
        BilibiliCommentsProtocol.deferNext { $0.query["mode"] == "2" }
        let track = try makeTrack(id: 9105, platform: "bilibili", rawJSON: #"{"aid":123}"#)
        let content = SongCommentsContent(track: track, pageSize: 2, session: makeSession())

        let staleLoad = Task { await content.loadFirstPage() }
        try await waitUntil { BilibiliCommentsProtocol.hasDeferredRequest }
        try await waitUntil { content.phase == .loaded }

        await content.loadFirstPage()
        #expect(content.latest.map(\.id) == [2])

        BilibiliCommentsProtocol.answerDeferred(
            status: 200, body: biliPage([biliComment(1)], count: 3, isEnd: false))
        await staleLoad.value

        #expect(content.phase == .loaded)
        #expect(content.hot.map(\.id) == [100])
        #expect(content.latest.map(\.id) == [2])
    }

    @Test func aidCacheServesASecondResolveWithoutAnotherViewRequest() async throws {
        BilibiliComments.resetAIDCacheForTesting()
        defer { BilibiliComments.resetAIDCacheForTesting() }
        let bvid = "BV1cache411c7m1"
        BilibiliCommentsProtocol.reset { request in
            guard request.path == "/x/web-interface/view" else { return (500, "") }
            return (200, json(["code": 0, "data": ["aid": 987_654]]))
        }
        let session = makeSession()

        let first = try await BilibiliComments.resolveAID(bvid: bvid, using: session)
        let second = try await BilibiliComments.resolveAID(bvid: bvid, using: session)

        #expect(first == 987_654)
        #expect(second == first)
        #expect(BilibiliCommentsProtocol.requests.filter {
            $0.path == "/x/web-interface/view"
        }.count == 1)
    }

    @Test func aidCacheKeepsDifferentBvidsAndResetsForTests() async throws {
        BilibiliComments.resetAIDCacheForTesting()
        defer { BilibiliComments.resetAIDCacheForTesting() }
        let firstBVID = "BV1cache411c7m2"
        let secondBVID = "BV1cache411c7m3"
        BilibiliCommentsProtocol.reset { request in
            let aid = request.query["bvid"] == firstBVID ? 111 : 222
            return (200, json(["code": 0, "data": ["aid": aid]]))
        }
        let session = makeSession()

        let first = try await BilibiliComments.resolveAID(bvid: firstBVID, using: session)
        let second = try await BilibiliComments.resolveAID(bvid: secondBVID, using: session)
        let cachedFirst = try await BilibiliComments.resolveAID(bvid: firstBVID, using: session)

        #expect([first, second, cachedFirst] == [111, 222, 111])
        #expect(BilibiliCommentsProtocol.requests.count == 2)

        BilibiliComments.resetAIDCacheForTesting()
        let refetched = try await BilibiliComments.resolveAID(bvid: firstBVID, using: session)

        #expect(refetched == 111)
        #expect(BilibiliCommentsProtocol.requests.count == 3)
    }
}
