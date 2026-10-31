import Foundation

/// 抖音 / TikTok 共用的平台描述。
///
/// 两个站的网页版结构几乎一样：都是 React 前端 + 需要签名的 JSON 接口。
/// 所以抓取、解析、播放都共用一套代码，只在这里区分 URL、UA 和字段名。
enum ShortVideoPlatform: String, CaseIterable, Identifiable, Codable {
    case douyin
    case tiktok

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .douyin: return String(localized: "抖音收藏")
        case .tiktok: return String(localized: "TikTok 收藏")
        }
    }

    var albumName: String {
        switch self {
        case .douyin: return "抖音"
        case .tiktok: return "TikTok"
        }
    }

    /// 抓取用的收藏页。
    var favoritesURLString: String {
        switch self {
        case .douyin: return "https://www.douyin.com/user/self?showTab=favorite_collection"
        case .tiktok: return "https://www.tiktok.com/@me"
        }
    }

    /// 入口页：先在能正常工作的首页登录，再回收藏页抓。
    /// 抖音的 `/user/self` 在未登录时是个半残页面，登录按钮都点不动。
    var homeURLString: String {
        switch self {
        case .douyin: return "https://www.douyin.com/"
        case .tiktok: return "https://www.tiktok.com/@me"
        }
    }

    var referer: String {
        switch self {
        case .douyin: return "https://www.douyin.com/"
        case .tiktok: return "https://www.tiktok.com/"
        }
    }

    /// 两边都用 Safari 桌面 UA：WKWebView 就是 WebKit，冒充 Chrome 会让站点
    /// 走到只对 Chrome 成立的代码路径（抖音的搜索、个人页、登录面板都会静默
    /// 失效）。TikTok 用这个 UA 已实测可以登录 + 抓取。
    var userAgent: String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
    }

    /// 站点自己的登录页。桌面版右上角「登录」按钮在某些 WebView 里点不动，
    /// 直接跳到登录页最省事；登录完 cookie 落在同一个域上，回收藏页即可。
    var loginURLString: String {
        switch self {
        case .douyin: return "https://sso.douyin.com/"
        case .tiktok: return "https://www.tiktok.com/login"
        }
    }

    /// 桌面版登录不了时的兜底：手机版页面用短信登录，登录态是同域的 cookie，
    /// 回到桌面版照样有效。
    var mobileUserAgent: String {
        "Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.0 Mobile/15E148 Safari/604.1"
    }

    /// 登录态 cookie 必须按域名判断：两个站都用 `sessionid` / `sid_guard`
    /// 这类名字，而 WKWebView 的 cookie 是全 App 共享的，不区分域名就会
    /// 「登录了 TikTok，抖音也说自己已登录」。
    var cookieDomainNeedle: String {
        switch self {
        case .douyin: return "douyin.com"
        case .tiktok: return "tiktok.com"
        }
    }

    /// 收藏 tab 的可能文案，注入脚本按文本自动点开。
    var tabTitles: [String] {
        switch self {
        case .douyin: return ["收藏", "收藏夹"]
        case .tiktok: return ["收藏", "Favorites", "Favorite"]
        }
    }

    /// 响应体里出现这些键才值得回传。
    var payloadMarkers: [String] {
        switch self {
        case .douyin: return ["aweme_list", "aweme_detail"]
        case .tiktok: return ["itemList", "itemStruct", "item_list"]
        }
    }

    func shareURL(for id: String) -> String {
        switch self {
        case .douyin: return "https://www.douyin.com/video/\(id)"
        case .tiktok: return "https://www.tiktok.com/@i/video/\(id)"
        }
    }
}

#if os(iOS)

/// 一条短视频。字段名和 WebDAV 同步用的 JSON 一一对应，
/// 这样 Kumone 和 PiliPlus 可以读写同一个远端文件。
struct ShortVideo: Identifiable, Hashable, Codable {
    let id: String
    var platform: String
    let desc: String
    let author: String
    let cover: String?
    let durationMS: Int
    var playURL: String
    var updatedAt: Double?

    /// 跨 App 的唯一键（不同平台的数字 id 会撞）。
    var key: String { "\(platform):\(id)" }

    var title: String {
        let trimmed = desc.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "短视频" : trimmed
    }

    var shareURL: String {
        (ShortVideoPlatform(rawValue: platform) ?? .douyin).shareURL(for: id)
    }

    var platformKind: ShortVideoPlatform {
        ShortVideoPlatform(rawValue: platform) ?? .douyin
    }

    var touch: Double { updatedAt ?? 0 }

    /// 包成插件条目，借用现有的插件队列 / 播放器 / 本地歌单。
    /// `url` 会被 `PluginManager.getMediaSource` 直接读走，不走 JS 引擎。
    var pluginItem: PluginMusicItem? {
        var dict: [String: Any] = [
            "id": id,
            "platform": platform,
            "title": title,
            "artist": author,
            "album": platformKind.albumName,
            "duration": Double(durationMS) / 1000.0,
            "url": playURL,
            "shareURL": shareURL,
        ]
        if let cover, !cover.isEmpty {
            dict["artwork"] = cover
        }
        return PluginMusicItem(normalizing: dict, platform: platform)
    }

    func withPlayURL(_ url: String) -> ShortVideo {
        var copy = self
        copy.playURL = url
        copy.updatedAt = Date().timeIntervalSince1970
        return copy
    }
}

enum ShortVideoParser {
    /// 解析网页里截获的一段 JSON。
    ///
    /// 抖音是 `aweme_list` / `aweme_detail`，TikTok 是 `itemList` / `itemStruct`；
    /// 两边的 `video` 字段名也不同（`play_addr` vs `playAddr`），
    /// `duration` 一个是毫秒一个是秒。
    static func videos(fromResponseBody body: String,
                       platform: ShortVideoPlatform) -> [ShortVideo] {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        return videos(fromJSONObject: object, platform: platform)
    }

    static func videos(fromJSONObject object: Any,
                       platform: ShortVideoPlatform) -> [ShortVideo] {
        guard let root = object as? [String: Any] else { return [] }
        for key in ["aweme_list", "itemList", "item_list", "awemeList"] {
            if let list = root[key] as? [[String: Any]] {
                return list.compactMap { video(from: $0, platform: platform) }
            }
        }
        for key in ["aweme_detail", "itemStruct", "itemInfo"] {
            if let detail = root[key] as? [String: Any],
               let video = video(from: detail, platform: platform) {
                return [video]
            }
        }
        return []
    }

    static func video(from item: [String: Any],
                      platform: ShortVideoPlatform) -> ShortVideo? {
        guard let id = string(item["aweme_id"]) ?? string(item["id"]),
              !id.isEmpty else { return nil }
        guard let video = item["video"] as? [String: Any] else { return nil }

        var playURL: String?
        var durationMS = 0
        var cover: String?

        switch platform {
        case .douyin:
            playURL = firstURL(in: video, keys: ["play_addr_h264", "play_addr", "download_addr"])
            durationMS = number(video["duration"]) ?? 0
            cover = firstURL(in: video, keys: ["cover", "origin_cover", "dynamic_cover"])
        case .tiktok:
            playURL = tiktokPlayURL(video)
            // TikTok 的 duration 是秒。
            durationMS = (number(video["duration"]) ?? 0) * 1000
            cover = string(video["cover"]) ?? string(video["originCover"])
                ?? firstURL(in: video, keys: ["cover", "origin_cover"])
        }

        guard let playURL, !playURL.isEmpty else { return nil }

        let author = item["author"] as? [String: Any]
        return ShortVideo(
            id: id,
            platform: platform.rawValue,
            desc: string(item["desc"]) ?? "",
            author: string(author?["nickname"]) ?? string(author?["uniqueId"]) ?? "",
            cover: cover,
            durationMS: durationMS,
            playURL: playURL,
            updatedAt: Date().timeIntervalSince1970
        )
    }

    private static func tiktokPlayURL(_ video: [String: Any]) -> String? {
        if let direct = string(video["playAddr"]), !direct.isEmpty { return direct }
        if let download = string(video["downloadAddr"]), !download.isEmpty { return download }
        if let bitrates = video["bitrateInfo"] as? [[String: Any]] {
            for entry in bitrates {
                if let play = entry["PlayAddr"] as? [String: Any],
                   let list = play["UrlList"] as? [String],
                   let hit = list.first(where: { !$0.isEmpty }) {
                    return hit
                }
            }
        }
        return firstURL(in: video, keys: ["play_addr", "download_addr"])
    }

    private static func firstURL(in container: [String: Any]?, keys: [String]) -> String? {
        guard let container else { return nil }
        for key in keys {
            guard let entry = container[key] as? [String: Any],
                  let list = entry["url_list"] as? [String] else { continue }
            if let hit = list.first(where: { !$0.isEmpty }) { return hit }
        }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func number(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(Double(text) ?? 0) }
        return nil
    }
}

/// 每个平台一份本地缓存，同时是 WebDAV 同步的本地副本。
enum ShortVideoStore {
    private static var directory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShortVideo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func fileURL(_ platform: ShortVideoPlatform) -> URL {
        directory.appendingPathComponent("\(platform.rawValue).json")
    }

    static func load(_ platform: ShortVideoPlatform) -> [ShortVideo] {
        guard let data = try? Data(contentsOf: fileURL(platform)),
              let list = try? JSONDecoder().decode([ShortVideo].self, from: data) else { return [] }
        return list
    }

    static func save(_ videos: [ShortVideo], for platform: ShortVideoPlatform) {
        guard let data = try? JSONEncoder().encode(videos) else { return }
        try? data.write(to: fileURL(platform), options: .atomic)
    }
}

/// 两个 App 共用的远端文件格式。
struct ShortVideoSyncDocument: Codable {
    var version: Int = 1
    var updatedAt: Double = Date().timeIntervalSince1970
    var items: [ShortVideo] = []
}

enum ShortVideoMerge {
    /// 按 `platform:id` 取并集；同一条以 `updatedAt` 更新的为准。
    /// 胜出的那条如果播放直链是空的，用另一条的直链补上。
    static func merge(_ local: [ShortVideo], _ remote: [ShortVideo]) -> [ShortVideo] {
        var order: [String] = []
        var byKey: [String: ShortVideo] = [:]

        for video in local + remote {
            let key = video.key
            if var existing = byKey[key] {
                let winner = video.touch > existing.touch ? video : existing
                var merged = winner
                if merged.playURL.isEmpty { merged.playURL = existing.playURL }
                if merged.playURL.isEmpty { merged.playURL = video.playURL }
                byKey[key] = merged
            } else {
                byKey[key] = video
                order.append(key)
            }
        }

        return order.compactMap { byKey[$0] }
    }
}

#endif