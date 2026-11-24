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

/// 抖音 / TikTok 收藏的「按需缓存」开关。
///
/// 收藏夹的网页直链带两小时签名，放久了就会过期；而 TikTok 没有可用
/// 的 `video_id` 长期地址，所以保留本地文件才能保证跨设备也能一直播。
/// 目的是：
/// - 抖音：默认关闭（省本地空间，在线播也稳定，长期地址靠 video_id）；
/// - TikTok：默认打开（没本地文件就迟早播不了）。
/// 打开后这个平台就变成「抓过的、同步过来的、播过的」都留本地，需要下哪些再下哪些。
enum ShortVideoCachePolicy: String {
    /// 收藏夹的网页直链哪来哪去，播时现解现拉，不落盘到本地。
    case onlineOnly = "onlineOnly"
    /// 抓过的、同步过来的、播过的条目都留在本地，保证以后能按时播放。
    case cacheOnDemand = "cacheOnDemand"

    var isCachingEnabled: Bool { self == .cacheOnDemand }

    /// 没有缓存相关时的存储类，放在这里供 iOS / macOS 共用。
    /// 默认：抖音按需缓存关，TikTok 按需缓存开。
    static func `default`(for platform: ShortVideoPlatform) -> ShortVideoCachePolicy {
        switch platform {
        case .douyin: return .onlineOnly
        case .tiktok: return .cacheOnDemand
        }
    }

    private static func storageKey(for platform: ShortVideoPlatform) -> String {
        "shortVideoCachePolicy.\(platform.rawValue)"
    }

    static func load(for platform: ShortVideoPlatform) -> ShortVideoCachePolicy {
        guard let raw = UserDefaults.standard.string(forKey: storageKey(for: platform)),
              let policy = ShortVideoCachePolicy(rawValue: raw) else {
            return `default`(for: platform)
        }
        return policy
    }

    func save(for platform: ShortVideoPlatform) {
        UserDefaults.standard.set(rawValue, forKey: Self.storageKey(for: platform))
    }
}

#if os(iOS)

/// 每个平台一份本地缓存，同时是 WebDAV 同步的本地副本（iOS）。
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
                if (merged.videoID ?? "").isEmpty { merged.videoID = existing.videoID }
                if (merged.videoID ?? "").isEmpty { merged.videoID = video.videoID }
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
