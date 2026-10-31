import Foundation

/// Platform-neutral bits shared with the plugin resolver.
enum DouyinPlatform {
    /// Pseudo platform name. It is not a mounted MusicFree plugin, so the
    /// engine is never asked to resolve it.
    static let identifier = "douyin"

    static let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
}
#if os(iOS)

/// One video taken from the Douyin favourites list.
///
/// The fields come straight from the web app's `aweme_list` payload, which the
/// collector captures inside a `WKWebView`. Keeping the original play URL lets
/// the existing player stream the video's audio track without a resolver.
struct DouyinVideo: Identifiable, Hashable, Codable {
    let id: String
    let desc: String
    let author: String
    let cover: String?
    let durationMS: Int
    let playURL: String

    var title: String {
        let trimmed = desc.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "抖音视频" : trimmed
    }

    var shareURL: String { "https://www.douyin.com/video/\(id)" }

    /// Wraps the video as a plugin-style item so it can ride the existing
    /// plugin queue, player and local playlists. `url` is read back by
    /// `PluginManager.getMediaSource` without touching the JS engine.
    var pluginItem: PluginMusicItem? {
        var dict: [String: Any] = [
            "id": id,
            "platform": DouyinPlatform.identifier,
            "title": title,
            "artist": author,
            "album": "抖音",
            "duration": Double(durationMS) / 1000.0,
            "url": playURL,
            "shareURL": shareURL,
        ]
        if let cover, !cover.isEmpty {
            dict["artwork"] = cover
        }
        return PluginMusicItem(normalizing: dict, platform: DouyinPlatform.identifier)
    }
}

enum DouyinParser {
    /// Parses a raw API response body captured from the web app.
    static func videos(fromResponseBody body: String) -> [DouyinVideo] {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        return videos(fromJSONObject: object)
    }

    static func videos(fromJSONObject object: Any) -> [DouyinVideo] {
        guard let root = object as? [String: Any] else { return [] }
        if let list = root["aweme_list"] as? [[String: Any]] {
            return list.compactMap(video(from:))
        }
        if let detail = root["aweme_detail"] as? [String: Any],
           let video = video(from: detail) {
            return [video]
        }
        return []
    }

    static func video(from item: [String: Any]) -> DouyinVideo? {
        guard let id = string(item["aweme_id"]) ?? string(item["awemeId"]), !id.isEmpty else {
            return nil
        }
        let video = item["video"] as? [String: Any]
        guard let playURL = firstURL(in: video, keys: ["play_addr_h264", "play_addr", "download_addr"]),
              !playURL.isEmpty else { return nil }

        let desc = string(item["desc"]) ?? ""
        let author = string((item["author"] as? [String: Any])?["nickname"]) ?? ""
        let cover = firstURL(in: video, keys: ["cover", "origin_cover", "dynamic_cover"])
        let duration = number(video?["duration"]) ?? 0

        return DouyinVideo(
            id: id,
            desc: desc,
            author: author,
            cover: cover,
            durationMS: duration,
            playURL: playURL
        )
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
        if let text = value as? String { return Int(text) }
        return nil
    }
}

/// On-disk copy of the last successful scrape, so opening the page does not
/// always require a fresh pass through the web view.
enum DouyinStore {
    private static var directory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Douyin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var fileURL: URL { directory.appendingPathComponent("favorites.json") }

    static func load() -> [DouyinVideo] {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([DouyinVideo].self, from: data) else { return [] }
        return list
    }

    static func save(_ videos: [DouyinVideo]) {
        guard let data = try? JSONEncoder().encode(videos) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
#endif