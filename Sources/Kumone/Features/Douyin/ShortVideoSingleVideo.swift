import Foundation

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
    /// 站点自己的视频 id（抖音是 `play_addr.uri`）。用它拼出来的播放地址
    /// 不带过期签名，同步到别的手机、或者放几个小时之后都还能播。
    var videoID: String? = nil
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
            "vid": videoID ?? "",
            "updatedAt": updatedAt ?? 0,
            "shareURL": shareURL,
        ]
        if let cover, !cover.isEmpty {
            dict["artwork"] = cover
        }
        return PluginMusicItem(normalizing: dict, platform: platform)
    }

    /// 不带过期签名的播放地址。
    ///
    /// 抖音的 `aweme/v1/play/?video_id=` 会 302 到一个新鲜的 CDN 地址，
    /// 所以不用登录、不用重抓也能一直播——「同步到另一台一首都不能听」
    /// 和「放几个小时陆续不能听」都是签名直链过期导致的，这个地址不会。
    var stablePlayURL: String? {
        guard let videoID, !videoID.isEmpty else { return nil }
        switch platformKind {
        case .douyin:
            return "https://www.iesdouyin.com/aweme/v1/play/?video_id=\(videoID)&ratio=720p&line=0"
        case .tiktok:
            return "https://api16-normal-c-useast1a.tiktokv.com/aweme/v1/play/?video_id=\(videoID)&ratio=720p&line=0"
        }
    }

    func withPlayURL(_ url: String) -> ShortVideo {
        var copy = self
        copy.playURL = url
        copy.updatedAt = Date().timeIntervalSince1970
        return copy
    }
}

enum ShortVideoParser {
    /// 只从响应里扫出所有视频 id，不做完整 JSON 解析。
    ///
    /// 用于 `ingest` 的增量判断：整段响应的 id 都在本地已知集合里时，
    /// 跳过 `JSONSerialization` 与字段映射，收藏多时显著省 CPU。
    /// `__kumoneSeenCount` 只数 `aweme_id` / `item_id`，而 `video(from:)`
    /// 里抖音取 `aweme_id`、TikTok 取 `id`，这里把 `id` 也算上以覆盖两边；
    /// 仅匹配 8 位以上数字，避免误伤杂项字段。
    static func ids(inResponseBody body: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(
            pattern: #""(?:aweme_id|item_id|id)"\s*:\s*"?([0-9]{8,})"#,
            options: []
        ) else { return [] }
        let range = NSRange(body.startIndex..., in: body)
        var result: Set<String> = []
        regex.enumerateMatches(in: body, options: [], range: range) { match, _, _ in
            guard let match, let r = Range(match.range(at: 1), in: body) else { return }
            result.insert(String(body[r]))
        }
        return result
    }

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
        var videoID: String?

        switch platform {
        case .douyin:
            playURL = firstURL(in: video, keys: ["play_addr_h264", "play_addr", "download_addr"])
            videoID = uri(in: video)
            durationMS = number(video["duration"]) ?? 0
            cover = firstURL(in: video, keys: ["cover", "origin_cover", "dynamic_cover"])
        case .tiktok:
            playURL = tiktokPlayURL(video)
            videoID = string(video["id"]) ?? string(video["videoID"])
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
            videoID: videoID,
            updatedAt: Date().timeIntervalSince1970
        )
    }

    /// 抖音的 `video.play_addr.uri`，形如 `v0300fg10000cj2m3k3c77u7v6k0`。
    private static func uri(in video: [String: Any]) -> String? {
        for key in ["play_addr", "play_addr_h264", "download_addr"] {
            if let entry = video[key] as? [String: Any],
               let value = string(entry["uri"]), !value.isEmpty {
                return value
            }
        }
        return nil
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

/// 单条抖音视频的纯逻辑解析。
///
/// 收藏页一次抓一大段 JSON，交给 `ShortVideoParser`；这里处理用户单独贴进来的
/// 分享文案：先拿到 `aweme_id`，再把 iteminfo / detail 的 JSON 映射成 `ShortVideo`。
/// 纯 Foundation 逻辑，macOS 单测和 iOS 共用同一套代码。
enum ShortVideoSingleVideo {
    /// `/video/<id>`、`/share/video/<id>`、`/share/forward/<id>` 与
    /// `?modal_id=<id>` / `?aweme_id=<id>`。分享文案里常有日期和点赞数，
    /// 限制 15-20 位并只认这些上下文，避免把别处的数字当成作品 id。
    private static let idRegex = try? NSRegularExpression(
        pattern: #"(?:douyin\.com/(?:share/)?(?:video|forward)/"#
            + #"|(?:[?&](?:modal_id|aweme_id)=))([0-9]{15,20})"#,
        options: [.caseInsensitive]
    )

    private static let shortLinkRegex = try? NSRegularExpression(
        pattern: #"(?:https?://)?v\.douyin\.com/[A-Za-z0-9_-]+/?"#,
        options: [.caseInsensitive]
    )

    private static let tiktokLinkRegex = try? NSRegularExpression(
        pattern: #"(?:^|[^A-Za-z0-9.-])(?:https?://)?(?:[A-Za-z0-9-]+\.)*tiktok\.com(?:[/?#]|$)"#,
        options: [.caseInsensitive]
    )

    /// B06 实测结论：TikTok 免登录纯 HTTP 拿不到播放直链与 `videoID`，
    /// 因此单链接导入只做识别与回退，不发起任何 TikTok 网络请求。
    /// 未来若实测到可播放地址，再把这个开关与解析路径一起翻案。
    static let supportsTikTokLinkImport = false

    /// 回退文案逐字来自 B06 决策报告，避免 UI 层改写成新的承诺。
    static let tiktokUnavailableTitle = "TikTok 暂不支持按链接添加"
    static let tiktokUnavailableMessage = "TikTok 暂不支持按链接添加单个视频：TikTok 没有提供免登录的播放地址。请先在 TikTok 登录，再用「同步收藏」抓取整份收藏。"
    /// 工具栏或列表里的短提示，完整说明仍用上面的标题与正文。
    static let tiktokUnavailableNotice = "TikTok 单曲暂不可用"

    /// 单条分享文案的导入结论；TikTok 分支不带 id，防止 UI 误落空条目。
    enum LinkImportDecision: Equatable {
        case douyin(id: String)
        case tiktokUnavailable
        case unsupported
    }

    static func importDecision(forShareText text: String) -> LinkImportDecision {
        if let id = awemeID(from: text) { return .douyin(id: id) }
        if containsTikTokLink(text) { return .tiktokUnavailable }
        return .unsupported
    }

    static func containsTikTokLink(_ text: String) -> Bool {
        guard let regex = tiktokLinkRegex else { return false }
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        return regex.firstMatch(in: text, options: [], range: fullRange) != nil
    }

    /// 从完整 URL、短链跳转后的 `Location` 或整段分享文案里取作品 id。
    static func awemeID(from text: String) -> String? {
        guard let regex = idRegex else { return nil }
        let source = text as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        guard let match = regex.firstMatch(in: text, options: [], range: fullRange) else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (15...20).contains(trimmed.count), trimmed.allSatisfy({ $0.isNumber }) else {
                return nil
            }
            return trimmed
        }
        let range = match.range(at: 1)
        guard range.location != NSNotFound else { return nil }
        return source.substring(with: range)
    }

    /// 分享文案里的 `v.douyin.com` 短链；短链本身只有 code，没有作品 id。
    static func shortLink(in text: String) -> URL? {
        guard let regex = shortLinkRegex else { return nil }
        let source = text as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        guard let match = regex.firstMatch(in: text, options: [], range: fullRange) else {
            return nil
        }
        let raw = source.substring(with: match.range)
        let normalized = raw.lowercased().hasPrefix("http") ? raw : "https://" + raw
        return URL(string: normalized)
    }

    /// 解析短链，返回 302 落点；后续用 `awemeID(from:)` 从落点取 id。
    static func resolveShortLink(_ url: URL, timeout: TimeInterval = 8) async -> URL? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 1
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(ShortVideoPlatform.douyin.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = timeout
        do {
            let (_, response) = try await session.data(for: request)
            return response.url
        } catch {
            return nil
        }
    }

    /// 整段分享文案 → 作品 id。先试直链，再按 8 秒超时解析短链。
    static func awemeID(fromShareText text: String,
                        timeout: TimeInterval = 8) async -> String? {
        if let id = awemeID(from: text) { return id }
        guard let link = shortLink(in: text),
              let destination = await resolveShortLink(link, timeout: timeout) else {
            return nil
        }
        return awemeID(from: destination.absoluteString)
    }

    /// 可注入短链解析器的版本，单测用它模拟 302，不碰网络。
    static func awemeID(fromShareText text: String,
                        resolvingShortLink resolve: (URL) async -> URL?) async -> String? {
        if let id = awemeID(from: text) { return id }
        guard let link = shortLink(in: text),
              let destination = await resolve(link) else { return nil }
        return awemeID(from: destination.absoluteString)
    }

    /// iteminfo 的 `aweme_list` / `item_list`，或直接给详情对象。
    static func video(fromItemInfo data: Data,
                      platform: ShortVideoPlatform = .douyin) -> ShortVideo? {
        video(fromJSONData: data, platform: platform)
    }

    /// detail 的 `aweme_detail`，或直接给详情对象。
    static func video(fromDetail data: Data,
                      platform: ShortVideoPlatform = .douyin) -> ShortVideo? {
        video(fromJSONData: data, platform: platform)
    }

    static func video(fromJSONData data: Data,
                      platform: ShortVideoPlatform = .douyin) -> ShortVideo? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return video(fromJSONObject: object, platform: platform)
    }

    static func video(fromJSONObject object: Any,
                      platform: ShortVideoPlatform = .douyin) -> ShortVideo? {
        guard let root = object as? [String: Any] else { return nil }

        for key in ["aweme_detail", "itemInfo", "itemStruct", "item_struct"] {
            if let item = root[key] as? [String: Any],
               let video = ShortVideoParser.video(from: item, platform: platform) {
                return video
            }
        }

        for key in ["aweme_list", "item_list", "itemList", "awemeList"] {
            guard let list = root[key] as? [[String: Any]] else { continue }
            for item in list {
                if let video = ShortVideoParser.video(from: item, platform: platform) {
                    return video
                }
            }
        }

        return ShortVideoParser.video(from: root, platform: platform)
    }
}
