import CryptoKit
import Foundation

/// Read-only Bilibili comment API. Bilibili keys a video's comment thread by
/// its numeric aid (`oid`), while plugin items may only carry a BV id, which
/// `/x/web-interface/view` resolves. No credentials are sent.
///
/// The legacy `/x/v2/reply` endpoint now answers `replies: null` for unsigned
/// callers, so comments go through `/x/v2/reply/wbi/main`, which requires the
/// WBI request signature (`w_rid`): a day-scoped key pair (fetched through the
/// web ticket + nav endpoints), a fixed key-table permutation, and MD5 over
/// the sorted encoded query. Mirrors the reference plugin implementation in
/// `Tools/plugin-js/test_bili_official.js`.
enum BilibiliComments {
    /// `hot` is Bilibili's engagement ordering (`mode=3`); `time` is
    /// time-ordered (`mode=2`).
    enum Sort: Int, Sendable {
        case time = 0
        case hot = 2
    }

    /// WBI `mode` values differ from the legacy `sort` numbers.
    private enum WBIMode: Int {
        case time = 2
        case hot = 3
    }

    static let browserUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/89.0.4389.90 Safari/537.36"
    static let referer = "https://www.bilibili.com/"

    private static let replyURL = "https://api.bilibili.com/x/v2/reply/wbi/main"
    private static let viewURL = "https://api.bilibili.com/x/web-interface/view"

    /// The fixed permutation table of the WBI mixin key, from
    /// bilibili-API-collect; the same 64 indexes the reference plugin uses.
    private static let mixinKeyEncTab: [Int] = [
        46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5,
        49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55,
        40, 61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57,
        62, 11, 36, 20, 34, 44, 52,
    ]

    private struct WBIKeys: Sendable {
        let img: String
        let sub: String
        let day: Int
    }

    /// Day-scoped, so the ticket/nav round-trip runs at most once a day.
    nonisolated(unsafe) private static var wbiKeysCache: WBIKeys?

    /// The numeric aid of a plugin track.
    static func aid(for track: Track) -> Int? {
        guard let rawJSON = track.plugin?.rawJSON else { return nil }
        return aid(from: rawJSON)
    }

    /// The plugin writes `aid` as a JSON number, but saved playlists may hold
    /// a numeric string instead.
    static func aid(from rawJSON: String) -> Int? {
        guard let data = rawJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let aid = int(object["aid"]), aid > 0 else { return nil }
        return aid
    }

    /// A BV id from the plugin item, falling back to the item id for older
    /// saved playlists that keyed the track by BV id.
    static func bvid(for track: Track) -> String? {
        if let rawJSON = track.plugin?.rawJSON,
           let data = rawJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["bvid", "id"] {
                if let value = object[key] as? String, value.hasPrefix("BV") { return value }
            }
        }
        guard let itemID = track.plugin?.itemID, itemID.hasPrefix("BV") else { return nil }
        return itemID
    }

    /// Resolves a BV id to its aid through `/x/web-interface/view`.
    static func resolveAID(bvid: String, using session: URLSession = .shared) async throws -> Int {
        guard !bvid.isEmpty else {
            throw MusicAPIError.business(code: 400, message: String(localized: "无法识别这个视频"))
        }
        let url = endpoint(viewURL, [
            URLQueryItem(name: "bvid", value: bvid),
        ])
        let object = try await get(url, using: session)
        guard let data = object["data"] as? [String: Any],
              let aid = int(data["aid"]), aid > 0 else {
            throw MusicAPIError.decoding("view: missing data.aid")
        }
        return aid
    }

    /// One page of a video's comments, keyed by aid. A hot page fills `hot`;
    /// time-ordered pages fill `latest`, as `SongCommentsPage` expects.
    static func fetchPage(oid: Int, page: Int = 1, pageSize: Int = 20,
                          sort: Sort = .hot,
                          using session: URLSession = .shared) async throws -> SongCommentsPage {
        guard oid > 0, page > 0, pageSize > 0 else {
            throw MusicAPIError.business(code: 400, message: String(localized: "无法识别这个视频"))
        }
        let params: [String: String] = [
            "type": "1",
            "mode": String(sort == .hot ? WBIMode.hot.rawValue : WBIMode.time.rawValue),
            "oid": String(oid),
            "next": String(page - 1),
            "plat": "1",
            "ps": String(pageSize),
            "web_location": "1315875",
            "wts": String(Int(Date().timeIntervalSince1970)),
        ]
        let keys = try await wbiKeys(using: session)
        let url = URL(string: "https://api.bilibili.com/x/v2/reply/wbi/main?" + signedQuery(params, keys: keys))!
        let object = try await get(url, using: session)
        guard let data = object["data"] as? [String: Any] else { return SongCommentsPage() }
        let replies = (data["replies"] as? [Any]) ?? []
        let comments = replies.compactMap { $0 as? [String: Any] }.compactMap(comment(from:))
        let pageInfo = (data["page"] as? [String: Any]) ?? [:]
        let total = int(pageInfo["count"]).flatMap { $0 > 0 ? $0 : nil } ?? comments.count
        let more: Bool
        let cursor = (data["cursor"] as? [String: Any]) ?? [:]
        if let isEnd = cursor["is_end"] as? Bool {
            more = !isEnd
        } else if let isEnd = data["isEnd"] as? Bool {
            more = !isEnd
        } else if let number = int(pageInfo["num"]), let size = int(pageInfo["size"]), size > 0 {
            more = number * size < total
        } else {
            more = comments.count >= pageSize
        }
        return sort == .hot
            ? SongCommentsPage(hot: comments, total: total, more: more)
            : SongCommentsPage(latest: comments, total: total, more: more)
    }

    /// A page of comments for a track, resolving the aid from its BV id when
    /// the plugin item predates `aid` in raw JSON.
    static func comments(for track: Track, page: Int = 1, pageSize: Int = 20,
                         sort: Sort = .hot,
                         using session: URLSession = .shared) async throws -> SongCommentsPage {
        if let aid = aid(for: track) {
            return try await fetchPage(oid: aid, page: page, pageSize: pageSize,
                                       sort: sort, using: session)
        }
        guard let bvid = bvid(for: track) else {
            throw MusicAPIError.business(code: 400, message: String(localized: "这个视频没有可用的评论 id"))
        }
        let aid = try await resolveAID(bvid: bvid, using: session)
        return try await fetchPage(oid: aid, page: page, pageSize: pageSize,
                                   sort: sort, using: session)
    }

    // MARK: - WBI signature

    /// The day-scoped WBI key pair: the web ticket endpoint signs a timestamp
    /// with a fixed secret and answers a `nav` object carrying the key URLs.
    private static func fetchWBIKeys(using session: URLSession) async throws -> (img: String, sub: String) {
        let timestamp = Int(Date().timeIntervalSince1970)
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data("ts\(timestamp)".utf8),
            using: SymmetricKey(data: Data("XgwSnGZ1p".utf8))
        )
        let hexSign = mac.map { String(format: "%02x", $0) }.joined()
        let url = URL(string: "https://api.bilibili.com/bapis/bilibili.api.ticket.v1.Ticket/GenWebTicket" +
            "?key_id=ec02&hexsign=\(hexSign)&context[ts]=\(timestamp)&csrf=")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0 (X11; Linux x86_64; rv:109.0) Gecko/20100101 Firefox/115.0",
                         forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["data"] as? [String: Any],
              let nav = payload["nav"] as? [String: Any],
              let img = nav["img"] as? String, let sub = nav["sub"] as? String else {
            throw MusicAPIError.decoding("ticket: missing data.nav keys")
        }
        return (strippedKey(img), strippedKey(sub))
    }

    /// "…/wbi/<key>.png" reads as "<key>".
    private static func strippedKey(_ url: String) -> String {
        guard let start = url.lastIndex(of: "/"), let end = url.lastIndex(of: "."), start < end else {
            return url
        }
        return String(url[url.index(after: start)..<end])
    }

    private static func wbiKeys(using session: URLSession) async throws -> (img: String, sub: String) {
        let day = Calendar(identifier: .gregorian).ordinality(of: .day, in: .year, for: Date()) ?? 0
        if let cache = wbiKeysCache, cache.day == day {
            return (cache.img, cache.sub)
        }
        let keys = try await fetchWBIKeys(using: session)
        wbiKeysCache = WBIKeys(img: keys.img, sub: keys.sub, day: day)
        return keys
    }

    /// The fixed-table permutation of "img+sub", truncated to 32 characters.
    private static func mixinKey(_ raw: String) -> String {
        var picked: [Character] = []
        for index in mixinKeyEncTab {
            guard index < raw.count else { continue }
            picked.append(raw[raw.index(raw.startIndex, offsetBy: index)])
        }
        return String(picked.prefix(32))
    }

    /// JavaScript's `encodeURIComponent`: leaves alphanumerics and `-_.~`,
    /// percent-encodes everything else as UTF-8.
    private static func encodeURIComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// Sorted, cleaned, encoded query with the trailing `w_rid` MD5, matching
    /// the reference implementation's `getRid`.
    private static func signedQuery(_ params: [String: String], keys: (img: String, sub: String)) -> String {
        let mixin = mixinKey(keys.img + keys.sub)
        let encoded: [String] = params.keys.sorted().map { key in
            let value = params[key] ?? ""
            let cleaned = value.replacingOccurrences(of: "[!'()*]",
                                                     with: "", options: .regularExpression)
            return encodeURIComponent(key) + "=" + encodeURIComponent(cleaned)
        }
        let query = encoded.joined(separator: "&")
        let digest = Insecure.MD5.hash(data: Data((query + mixin).utf8))
        let wRid = digest.map { String(format: "%02x", $0) }.joined()
        return query + "&w_rid=" + wRid
    }

    private static func endpoint(_ base: String, _ query: [URLQueryItem]) -> URL {
        var components = URLComponents(string: base)!
        components.queryItems = query
        return components.url!
    }

    private static func get(_ url: URL, using session: URLSession) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MusicAPIError.http(-1) }
        guard (200..<300).contains(http.statusCode) else { throw MusicAPIError.http(http.statusCode) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MusicAPIError.decoding("not a JSON object")
        }
        let code = int(object["code"]) ?? -1
        guard code == 0 else {
            let message = (object["message"] as? String) ?? (object["msg"] as? String)
            throw MusicAPIError.business(code: code, message: message)
        }
        return object
    }

    private static func comment(from reply: [String: Any]) -> SongComment? {
        guard let rpid = int(reply["rpid"]), rpid > 0 else { return nil }
        let member = (reply["member"] as? [String: Any]) ?? [:]
        let content = (reply["content"] as? [String: Any]) ?? [:]
        let ctime = int(reply["ctime"]) ?? 0
        let location = ((reply["reply_control"] as? [String: Any])?["location"] as? String)
            .flatMap { normalizedLocation($0) }
        return SongComment(
            id: rpid,
            userID: int(member["mid"]) ?? 0,
            nickname: (member["uname"] as? String) ?? "",
            avatarURL: (member["avatar"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            content: (content["message"] as? String) ?? "",
            time: ctime > 0 ? Date(timeIntervalSince1970: TimeInterval(ctime)) : nil,
            likedCount: max(0, int(reply["like"]) ?? 0),
            ipLocation: location
        )
    }

    /// "IP属地：上海" reads as "来自 IP属地：上海" otherwise.
    private static func normalizedLocation(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = trimmed.hasPrefix("IP属地：") ? String(trimmed.dropFirst(5))
            : trimmed.hasPrefix("IP属地:") ? String(trimmed.dropFirst(4))
            : trimmed
        let location = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        return location.isEmpty ? nil : location
    }

    /// JSON numbers bridge to NSNumber; saved values may be numeric strings.
    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}
