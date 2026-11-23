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
    private static let lock = NSLock()

    static func reset(_ handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
        recorded = []
    }

    static var requests: [Recorded] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let recorded = Recorded(path: request.url?.path ?? "", query: Self.queryItems(request.url))
        Self.lock.lock()
        Self.recorded.append(recorded)
        let handler = Self.handler
        Self.lock.unlock()
        let (status, body) = handler(recorded)
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
        let track = try makeTrack(platform: "bilibili", itemID: "BV1xx411c7m2")
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
}
