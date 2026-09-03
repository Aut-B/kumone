import Foundation

/// A track that originates from a MusicFree-style JS plugin.
/// Stored on `Track.plugin` so the plugin queue can coexist with NetEase tracks.
struct PluginTrackInfo: Codable, Hashable, Sendable {
    let platform: String
    let itemID: String
    /// The full plugin item as JSON — fed back to `getMediaSource` unchanged.
    let rawJSON: String
}

/// Normalized search result row from a plugin.
struct PluginMusicItem: Identifiable, Hashable, Sendable {
    /// Composite stable id: "platform|itemID".
    let id: String
    let platform: String
    let itemID: String
    let title: String
    let artist: String
    let album: String
    let artwork: String?
    let durationMS: Int
    let rawJSON: String

    /// Builds a normalized item from a raw plugin JSON object. Returns nil for
    /// entries without a usable id. `platform` is the fallback when the object
    /// doesn't carry its own (e.g. imported playlists carry it per item).
    init?(normalizing dict: [String: Any], platform: String) {
        guard let itemID = dict["id"] as? String, !itemID.isEmpty else { return nil }
        let resolvedPlatform = (dict["platform"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? platform
        self.platform = resolvedPlatform
        self.itemID = itemID
        id = "\(resolvedPlatform)|\(itemID)"
        title = (dict["title"] as? String) ?? (dict["name"] as? String) ?? itemID
        artist = (dict["artist"] as? String) ?? String(localized: "未知歌手")
        album = (dict["album"] as? String) ?? String(localized: "未知专辑")
        artwork = (dict["artwork"] as? String) ?? (dict["picUrl"] as? String)
        let durationSeconds = (dict["duration"] as? NSNumber)?.doubleValue ?? 0
        durationMS = Int(durationSeconds * 1000)
        rawJSON = (try? JSONSerialization.data(withJSONObject: dict)).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? "{}"
    }
}

/// Playable source resolved by a plugin's `getMediaSource`.
struct PluginMediaSource: Sendable {
    let url: URL?
    let headers: [String: String]?

    init(url: URL?, headers: [String: String]?) {
        self.url = url
        self.headers = headers
    }
}

/// Result of mounting plugin code in the JS engine.
struct PluginMountResult: Sendable {
    let platform: String
    /// `userVariables` declarations from the plugin: [{key, name, defaultValue}].
    let userVariables: [[String: Any]]
}

extension AudioQuality {
    /// Maps Kumone's quality ladder onto MusicFree's plugin quality keys.
    var pluginQuality: String {
        switch self {
        case .standard: return "standard"
        case .higher: return "high"
        case .exhigh, .lossless, .hires: return "super"
        }
    }
}
