import Foundation
import Testing
@testable import KumoneCore

/// Serves scripted bodies and records what the comment client sent.
private final class BilibiliProtocol: URLProtocol, @unchecked Sendable {
    struct Recorded {
        let url: URL?
        let method: String?
        let userAgent: String?
        let referer: String?
    }

    nonisolated(unsafe) static var bodies: [String] = []
    nonisolated(unsafe) static var requests: [Recorded] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(Recorded(
            url: request.url,
            method: request.httpMethod,
            userAgent: request.value(forHTTPHeaderField: "User-Agent"),
            referer: request.value(forHTTPHeaderField: "Referer")))
        let body = Self.bodies.isEmpty ? #"{"code":-1,"message":"no script"}"# : Self.bodies.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func makeSession(_ bodies: [String]) -> URLSession {
    BilibiliProtocol.bodies = bodies
    BilibiliProtocol.requests = []
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [BilibiliProtocol.self]
    return URLSession(configuration: configuration)
}

private func makeTrack(rawJSON: String, itemID: String = "BV1xx411c7m2") throws -> Track {
    let object: [String: Any] = [
        "id": 7,
        "name": "bilibili video",
        "plugin": ["platform": "bilibili", "itemID": itemID, "rawJSON": rawJSON],
    ]
    let data = try JSONSerialization.data(withJSONObject: object)
    return try JSONDecoder().decode(Track.self, from: data)
}

private func json(_ object: Any) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
}

private func queryItems(_ url: URL?) -> [String: String] {
    guard let url,
          let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return [:] }
    return Dictionary(uniqueKeysWithValues: items.compactMap { item in
        item.value.map { (item.name, $0) }
    })
}

@Suite("Bilibili comments", .serialized)
struct BilibiliCommentsTests {
    @Test func readsAidFromNumbersAndNumericStrings() {
        #expect(BilibiliComments.aid(from: #"{"aid":12345,"bvid":"BV1ab411c7d9"}"#) == 12345)
        #expect(BilibiliComments.aid(from: #"{"aid":"67890"}"#) == 67890)
        #expect(BilibiliComments.aid(from: #"{"aid":null}"#) == nil)
        #expect(BilibiliComments.aid(from: "{}") == nil)
    }

    @Test func readsTrackAidAndBvid() throws {
        let complete = try makeTrack(rawJSON: #"{"aid":42,"bvid":"BV1ab411c7d9","id":"BV1ab411c7d9"}"#)
        #expect(BilibiliComments.aid(for: complete) == 42)
        #expect(BilibiliComments.bvid(for: complete) == "BV1ab411c7d9")

        let older = try makeTrack(rawJSON: "{}", itemID: "BV1xx411c7m2")
        #expect(BilibiliComments.aid(for: older) == nil)
        #expect(BilibiliComments.bvid(for: older) == "BV1xx411c7m2")

        let keyedByID = try makeTrack(rawJSON: #"{"id":"BV1yy411c7m3"}"#)
        #expect(BilibiliComments.bvid(for: keyedByID) == "BV1yy411c7m3")
    }

    @Test func loadsACommentPageAsBrowser() async throws {
        let body = json([
            "code": 0,
            "message": "0",
            "data": [
                "replies": [
                    ["rpid": 1001,
                     "member": ["uname": "alice", "avatar": "https://i0.hdslb.com/a.jpg", "mid": 88],
                     "content": ["message": "好听"],
                     "ctime": 1_700_000_000,
                     "like": 12,
                     "reply_control": ["location": "IP属地：上海"]],
                    ["rpid": "1002",
                     "member": ["uname": "bob"],
                     "content": ["message": "second"],
                     "ctime": "1700000100",
                     "like": "3",
                     "reply_control": ["location": "北京"]],
                ],
                "page": ["num": 2, "size": 20, "count": 45],
                "isEnd": false,
            ],
        ])
        let session = makeSession([body])
        let page = try await BilibiliComments.fetchPage(oid: 99, page: 2, pageSize: 20,
                                                        sort: .hot, using: session)

        try #require(page.hot.count == 2)
        #expect(page.latest.isEmpty)
        #expect(page.total == 45)
        #expect(page.more)
        let first = try #require(page.hot.first)
        #expect(first.id == 1001)
        #expect(first.userID == 88)
        #expect(first.nickname == "alice")
        #expect(first.avatarURL == "https://i0.hdslb.com/a.jpg")
        #expect(first.content == "好听")
        #expect(first.time == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(first.likedCount == 12)
        #expect(first.ipLocation == "上海")
        #expect(page.hot[1].id == 1002)
        #expect(page.hot[1].time == Date(timeIntervalSince1970: 1_700_000_100))
        #expect(page.hot[1].likedCount == 3)
        #expect(page.hot[1].ipLocation == "北京")

        let request = try #require(BilibiliProtocol.requests.first)
        #expect(request.method == "GET")
        #expect(request.userAgent == BilibiliComments.browserUserAgent)
        #expect(request.referer == "https://www.bilibili.com/")
        #expect(request.url?.path == "/x/v2/reply")
        let query = queryItems(request.url)
        #expect(query["type"] == "1")
        #expect(query["oid"] == "99")
        #expect(query["pn"] == "2")
        #expect(query["ps"] == "20")
        #expect(query["sort"] == "2")
    }

    @Test func skipsMalformedReplies() async throws {
        let body = json([
            "code": 0,
            "data": [
                "replies": [
                    ["rpid": 1, "member": ["uname": "kept"],
                     "content": ["message": "ok"], "ctime": 1, "like": 0],
                    ["member": ["uname": "no rpid"], "content": ["message": "dropped"]],
                    ["rpid": 0, "content": ["message": "dropped"]],
                    ["rpid": "not-a-number", "content": ["message": "dropped"]],
                    NSNull(),
                ],
                "page": ["num": 1, "size": 20, "count": 1],
            ],
        ])
        let session = makeSession([body])
        let page = try await BilibiliComments.fetchPage(oid: 5, sort: .time, using: session)

        #expect(page.latest.map(\.id) == [1])
        #expect(queryItems(BilibiliProtocol.requests.first?.url)["sort"] == "0")
    }

    @Test func resolvesBvidToAid() async throws {
        let body = json(["code": 0, "message": "0", "data": ["aid": 24680, "bvid": "BV1ab411c7d9"]])
        let session = makeSession([body])
        let aid = try await BilibiliComments.resolveAID(bvid: "BV1ab411c7d9", using: session)

        #expect(aid == 24680)
        let request = try #require(BilibiliProtocol.requests.first)
        #expect(request.url?.path == "/x/web-interface/view")
        #expect(queryItems(request.url)["bvid"] == "BV1ab411c7d9")
    }

    @Test func loadsCommentsForABvidOnlyTrack() async throws {
        let view = json(["code": 0, "message": "0", "data": ["aid": 24680]])
        let replies = json([
            "code": 0,
            "data": [
                "replies": [["rpid": 9, "content": ["message": "hi"]]],
                "page": ["num": 1, "size": 20, "count": 1],
            ],
        ])
        let session = makeSession([view, replies])
        let track = try makeTrack(rawJSON: #"{"id":"BV1ab411c7d9","bvid":"BV1ab411c7d9"}"#)
        let page = try await BilibiliComments.comments(for: track, sort: .time, using: session)

        #expect(page.latest.map(\.id) == [9])
        try #require(BilibiliProtocol.requests.count == 2)
        #expect(BilibiliProtocol.requests[0].url?.path == "/x/web-interface/view")
        #expect(BilibiliProtocol.requests[1].url?.path == "/x/v2/reply")
        #expect(queryItems(BilibiliProtocol.requests[1].url)["oid"] == "24680")
    }

    @Test func reportsADeclinedReplyRequest() async {
        let session = makeSession([json(["code": -412, "message": "请求被拦截"])])
        do {
            _ = try await BilibiliComments.fetchPage(oid: 5, using: session)
            Issue.record("expected a business failure")
        } catch let error as MusicAPIError {
            guard case .business(let code, let message) = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(code == -412)
            #expect(message == "请求被拦截")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func reportsADeclinedViewRequest() async {
        let session = makeSession([json(["code": -400, "message": "请求错误"])])
        do {
            _ = try await BilibiliComments.resolveAID(bvid: "BV1xx411c7m2", using: session)
            Issue.record("expected a business failure")
        } catch let error as MusicAPIError {
            guard case .business(let code, let message) = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(code == -400)
            #expect(message == "请求错误")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}
