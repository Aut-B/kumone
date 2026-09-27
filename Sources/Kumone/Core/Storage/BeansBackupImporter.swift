import Foundation

/// Reads the backup file Beans Music writes to WebDAV (`localLibrary.json`),
/// so both apps can share one backup instead of keeping two.
///
/// Beans shape:
/// ```json
/// { "schema": 1, "app": "Beans Music", "updatedAt": "...", "device": "",
///   "playlists": [ { "id": "...", "name": "...", "songs": [ Song ], "createdAt": "..." } ] }
/// ```
/// A `Song` carries `source` = `netease` / `qq` / `kugou` / `plugin`; plugin
/// songs also carry `pluginPlatform` / `pluginItemID` / `pluginRawJSON`.
enum BeansBackupImporter {
    struct Playlist {
        let name: String
        let entries: [LocalTrackEntry]
    }

    struct Backup {
        let playlists: [Playlist]
        /// Songs of a source this app cannot play (QQ / 酷狗), counted so the
        /// import can say what it dropped instead of silently shrinking a list.
        let skipped: Int
    }

    /// Recognising `app` first matters: handed to the MusicFree parser instead,
    /// `source: "plugin"` would be read as a platform name and every plugin id
    /// would be lost.
    static func looksLikeBeansBackup(_ object: [String: Any]) -> Bool {
        (object["app"] as? String) == "Beans Music" && object["playlists"] is [[String: Any]]
    }

    static func parse(_ object: [String: Any]) -> Backup? {
        guard let rawPlaylists = object["playlists"] as? [[String: Any]] else { return nil }
        var playlists: [Playlist] = []
        var skipped = 0
        for (index, raw) in rawPlaylists.enumerated() {
            let name = (raw["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? String(localized: "Beans 歌单 \(index + 1)")
            let songs = raw["songs"] as? [[String: Any]] ?? []
            var entries: [LocalTrackEntry] = []
            for song in songs {
                if let entry = entry(from: song) {
                    entries.append(entry)
                } else {
                    skipped += 1
                }
            }
            guard !entries.isEmpty else { continue }
            playlists.append(Playlist(name: name, entries: entries))
        }
        return Backup(playlists: playlists, skipped: skipped)
    }

    // MARK: - Song

    private static func entry(from song: [String: Any]) -> LocalTrackEntry? {
        let name = (song["name"] as? String) ?? ""
        guard !name.isEmpty else { return nil }
        let artists = (song["artists"] as? String) ?? ""
        let album = (song["album"] as? String) ?? ""
        let cover = song["coverURL"] as? String
        let rawDuration = (song["duration"] as? NSNumber)?.doubleValue ?? 0
        // Beans stores seconds; a value that large can only be milliseconds.
        let durationMS = rawDuration > 1000 ? Int(rawDuration) : Int(rawDuration * 1000)
        let fee = (song["fee"] as? NSNumber)?.intValue ?? 0
        let source = (song["source"] as? String) ?? "netease"

        if source == "plugin" {
            let platform = (song["pluginPlatform"] as? String) ?? ""
            var dict: [String: Any] = [:]
            if let raw = song["pluginRawJSON"] as? String,
               let data = raw.data(using: .utf8),
               let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                dict = parsed
            }
            // Fill in whatever the raw payload is missing, otherwise the plugin
            // would be handed an item without an id and refuse to resolve it.
            if (dict["id"] as? String)?.isEmpty != false {
                dict["id"] = (song["pluginItemID"] as? String) ?? ""
            }
            if (dict["platform"] as? String)?.isEmpty != false { dict["platform"] = platform }
            if (dict["title"] as? String)?.isEmpty != false { dict["title"] = name }
            if (dict["artist"] as? String)?.isEmpty != false { dict["artist"] = artists }
            if (dict["album"] as? String)?.isEmpty != false { dict["album"] = album }
            if dict["duration"] == nil { dict["duration"] = Double(durationMS) / 1000 }
            if (dict["artwork"] as? String)?.isEmpty != false { dict["artwork"] = cover ?? "" }
            guard let item = PluginMusicItem(normalizing: dict, platform: platform) else { return nil }
            return .plugin(item)
        }

        guard source == "netease" else { return nil }   // QQ / 酷狗 have no source here
        guard let id = (song["id"] as? NSNumber)?.intValue else { return nil }
        return .netease(LocalNeteaseSong(
            id: id,
            name: name,
            artist: artists,
            album: album,
            picUrl: cover,
            durationMS: durationMS,
            fee: fee
        ))
    }
}
