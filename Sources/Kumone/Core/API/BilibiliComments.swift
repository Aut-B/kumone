import Foundation

/// Read-only Bilibili comment API. Bilibili keys a video's comment thread by
/// its numeric aid (`oid`), while plugin items may only carry a BV id, which
/// `/x/web-interface/view` resolves. No credentials are sent.
enum BilibiliComments {
    /// `sort=0` is time-ordered; `sort=2` is Bilibili's engagement ordering.
    enum Sort: Int, Sendable {
        case time = 0
        case hot = 2
    }

    static let browserUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/89.0.4389.90 Safari/537.36"
    static let referer = "https://www.bilibili.com/"

    private static let replyURL = "https://api.bilibili.com/x/v2/reply"
    private static let viewURL = "https://api.bilibili.com/x/web-interface/view"

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
        let url = endpoint(replyURL, [
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "oid", value: String(oid)),
            URLQueryItem(name: "pn", value: String(page)),
            URLQueryItem(name: "ps", value: String(pageSize)),
            URLQueryItem(name: "sort", value: String(sort.rawValue)),
        ])
        let object = try await get(url, using: session)
        guard let data = object["data"] as? [String: Any] else { return SongCommentsPage() }
        let replies = (data["replies"] as? [Any]) ?? []
        let comments = replies.compactMap { $0 as? [String: Any] }.compactMap(comment(from:))
        let pageInfo = (data["page"] as? [String: Any]) ?? [:]
        let total = int(pageInfo["count"]).flatMap { $0 > 0 ? $0 : nil } ?? comments.count
        let more: Bool
        if let isEnd = data["isEnd"] as? Bool {
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
