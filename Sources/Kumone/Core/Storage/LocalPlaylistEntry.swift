import Foundation

/// A NetEase song kept by reference inside a local playlist.
///
/// Local playlists used to hold plugin items only. Sharing the WebDAV backup
/// with Beans means a local playlist can also contain NetEase songs; they are
/// stored as a thin reference and their URL is resolved again from the song id
/// at play time, so a stale URL never blocks playback.
struct LocalNeteaseSong: Codable, Hashable {
    var id: Int
    var name: String
    var artist: String
    var album: String
    var picUrl: String?
    var durationMS: Int
    var fee: Int
}

/// One entry of a local playlist: a plugin item or a NetEase reference.
enum LocalTrackEntry: Identifiable, Hashable {
    case plugin(PluginMusicItem)
    case netease(LocalNeteaseSong)

    /// Stable key used for selection and de-duplication.
    var id: String {
        switch self {
        case .plugin(let item): return "plugin|\(item.id)"
        case .netease(let song): return "netease|\(song.id)"
        }
    }

    var title: String {
        switch self {
        case .plugin(let item): return item.title
        case .netease(let song): return song.name
        }
    }

    var artist: String {
        switch self {
        case .plugin(let item): return item.artist
        case .netease(let song): return song.artist
        }
    }

    var album: String {
        switch self {
        case .plugin(let item): return item.album
        case .netease(let song): return song.album
        }
    }

    var artwork: String? {
        switch self {
        case .plugin(let item): return item.artwork
        case .netease(let song): return song.picUrl
        }
    }

    var durationMS: Int {
        switch self {
        case .plugin(let item): return item.durationMS
        case .netease(let song): return song.durationMS
        }
    }

    /// Where the audio comes from, shown next to the artist line.
    var platform: String {
        switch self {
        case .plugin(let item): return item.platform
        case .netease: return String(localized: "网易云")
        }
    }

    var isPlugin: Bool {
        if case .plugin = self { return true }
        return false
    }

    /// The playable form handed to `PlayerService`.
    var track: Track {
        switch self {
        case .plugin(let item): return Track(pluginItem: item)
        case .netease(let song): return Track(localSong: song)
        }
    }

    // MARK: - Persistence

    /// Dictionary written into the playlist JSON file.
    ///
    /// Plugin entries keep the FULL original item (bvid/cid/qualities live in
    /// `rawJSON`); a reduced dict loses the fields playback resolution needs.
    var dictionary: [String: Any] {
        switch self {
        case .plugin(let item):
            if let data = item.rawJSON.data(using: .utf8),
               let full = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                var dict = full
                dict["kind"] = "plugin"
                return dict
            }
            return [
                "kind": "plugin",
                "id": item.itemID,
                "platform": item.platform,
                "title": item.title,
                "artist": item.artist,
                "album": item.album,
                "duration": Double(item.durationMS) / 1000,
            ]
        case .netease(let song):
            var dict: [String: Any] = [
                "kind": "netease",
                "id": song.id,
                "name": song.name,
                "artist": song.artist,
                "album": song.album,
                "durationMS": song.durationMS,
                "fee": song.fee,
            ]
            if let picUrl = song.picUrl { dict["picUrl"] = picUrl }
            return dict
        }
    }

    /// Reads back an entry written by `dictionary`.
    ///
    /// Entries without a `kind` are treated as plugin items, which keeps every
    /// playlist imported before this change readable.
    init?(dictionary: [String: Any]) {
        if let kind = dictionary["kind"] as? String, kind == "netease" {
            guard let id = (dictionary["id"] as? NSNumber)?.intValue else { return nil }
            self = .netease(LocalNeteaseSong(
                id: id,
                name: (dictionary["name"] as? String) ?? "",
                artist: (dictionary["artist"] as? String) ?? "",
                album: (dictionary["album"] as? String) ?? "",
                picUrl: dictionary["picUrl"] as? String,
                durationMS: (dictionary["durationMS"] as? NSNumber)?.intValue ?? 0,
                fee: (dictionary["fee"] as? NSNumber)?.intValue ?? 0
            ))
            return
        }
        guard let item = PluginMusicItem(normalizing: dictionary, platform: "") else { return nil }
        self = .plugin(item)
    }
}

extension LocalTrackEntry {
    /// Converts a track back into a storable entry.
    ///
    /// Plugin tracks are rebuilt from their `PluginTrackInfo`; the B 站 case
    /// needs `bvid` kept alongside `id` because that is what the plugin reads.
    init?(track: Track) {
        if let plugin = track.plugin {
            var dict: [String: Any] = [
                "id": plugin.itemID,
                "platform": plugin.platform,
                "title": track.name,
                "artist": track.artistNames,
                "album": track.album.name,
                "duration": track.duration,
                "artwork": track.album.picUrl ?? "",
            ]
            if plugin.itemID.hasPrefix("BV") { dict["bvid"] = plugin.itemID }
            guard let item = PluginMusicItem(normalizing: dict, platform: plugin.platform) else { return nil }
            self = .plugin(item)
            return
        }
        self = .netease(LocalNeteaseSong(
            id: track.id,
            name: track.name,
            artist: track.artistNames,
            album: track.album.name,
            picUrl: track.album.picUrl,
            durationMS: track.durationMS,
            fee: track.fee
        ))
    }
}

extension Array where Element == LocalTrackEntry {
    /// Playable queue in list order.
    var tracks: [Track] { map(\.track) }
}
