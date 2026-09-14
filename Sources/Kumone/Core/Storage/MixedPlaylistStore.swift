import Foundation

/// A hand-built playlist that may hold **both** worlds' songs.
///
/// Kumone ships two separate playlist kinds and neither can hold the other's
/// entries: the NetEase account's playlists live server-side (their entries are
/// NetEase song ids, added through `NeteaseAPI.playlistTracks`), and the
/// MusicFree playlists imported under the Plugins tab hold plugin items only.
/// This store adds a third, purely local kind.
///
/// Entries are persisted as `Track` JSON, which is exactly the shape playback
/// already understands, so one list can carry both:
///
///   • a NetEase entry keeps `plugin == nil` → resolved by `NeteaseAPI` and
///     `UnblockService`, with lyrics and scrobbling intact;
///   • a plugin entry keeps its `PluginTrackInfo` → resolved by that plugin's
///     `getMediaSource`.
///
/// `PlayerService` resolves each track on its own, so a queue built from this
/// store plays the two kinds back to back with no special casing.
///
/// Nothing here is ever written back into a NetEase playlist or into an
/// imported plugin playlist — this is a third list, not a merge of those two.
struct MixedPlaylist: Codable, Identifiable, Hashable {
    var id: Int
    var name: String
    var fileName: String
    var itemCount: Int
    var createdAt: Date
}

enum MixedPlaylistError: LocalizedError {
    case duplicate
    case writeFailed
    case missingPlaylist

    var errorDescription: String? {
        switch self {
        case .duplicate: return String(localized: "这首歌已经在歌单里了")
        case .writeFailed: return String(localized: "歌单写入失败")
        case .missingPlaylist: return String(localized: "歌单不存在")
        }
    }
}

@MainActor
final class MixedPlaylistStore: ObservableObject {
    static let shared = MixedPlaylistStore()

    @Published private(set) var playlists: [MixedPlaylist] = []

    private var directory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MixedPlaylists", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    private init() {
        load()
    }

    // MARK: - Identity

    /// Cross-world identity, used for de-duplication and for `ForEach` ids.
    ///
    /// A plugin item is keyed by platform + item id, a NetEase song by its song
    /// id, so the two namespaces can never collide. Deliberately not
    /// `Track.id`: that is a hash for plugin items and a real song id for
    /// NetEase items, and the two could in principle coincide.
    /// `nonisolated` so SwiftUI view code (whose helper properties aren't
    /// `@MainActor` like `body` is) can compute row ids without hopping actors.
    nonisolated static func identity(of track: Track) -> String {
        if let plugin = track.plugin {
            return "plugin|\(plugin.platform)|\(plugin.itemID)"
        }
        return "netease|\(track.id)"
    }

    // MARK: - Playlist CRUD

    func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([MixedPlaylist].self, from: data) else { return }
        playlists = list
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(playlists) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    func playlist(id: Int) -> MixedPlaylist? {
        playlists.first { $0.id == id }
    }

    /// Copies this playlist into a plugin playlist, dropping NetEase entries.
    ///
    /// A plugin playlist file only stores plugin items (id/platform/rawJSON),
    /// so a NetEase song has no representation there at all. The caller is
    /// told how many were skipped so it can say so rather than silently
    /// dropping half the list.
    ///
    /// Returns `(imported, skipped)`.
    @discardableResult
    func exportPluginItems(from playlist: MixedPlaylist, to target: ImportedPlaylist) throws -> (imported: Int, skipped: Int) {
        let source = tracks(of: playlist)
        let items = pluginItems(in: source)
        // One write for the whole batch; entries already present are skipped.
        let imported = try ImportedPlaylistStore.shared.addItems(items, to: target)
        return (imported, source.count - items.count)
    }

    /// The plugin items of a mixed playlist, in list order. Used when the
    /// playlist is mirrored into a plugin playlist.
    func pluginItems(of playlist: MixedPlaylist) -> [PluginMusicItem] {
        pluginItems(in: tracks(of: playlist))
    }

    /// Extracts the plugin entries from an already-loaded track list.
    ///
    /// Prefers `plugin.rawJSON`, which is the item exactly as the plugin
    /// returned it — `bvid`/`cid`/`qualities` live there and playback
    /// resolution needs them. The `Track` fields alone are not enough to play
    /// the song back, so the reconstructed dict is only a fallback for items
    /// whose raw JSON failed to parse.
    private func pluginItems(in source: [Track]) -> [PluginMusicItem] {
        source.compactMap { track -> PluginMusicItem? in
            guard let plugin = track.plugin else { return nil }
            if let data = plugin.rawJSON.data(using: .utf8),
               let full = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let item = PluginMusicItem(normalizing: full, platform: plugin.platform) {
                return item
            }
            return PluginMusicItem(
                normalizing: [
                    "id": plugin.itemID,
                    "platform": plugin.platform,
                    "title": track.name,
                    "artist": track.artistNames,
                    "album": track.album.name,
                    "duration": track.duration,
                    "artwork": track.album.picUrl ?? "",
                ],
                platform: plugin.platform
            )
        }
    }

    @discardableResult
    func createPlaylist(name: String) -> MixedPlaylist {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileName = UUID().uuidString + ".json"
        writeTracks([], fileName: fileName)
        let playlist = MixedPlaylist(
            id: (playlists.map(\.id).max() ?? 0) + 1,
            name: trimmed.isEmpty ? String(localized: "新建歌单") : trimmed,
            fileName: fileName,
            itemCount: 0,
            createdAt: Date()
        )
        playlists.insert(playlist, at: 0)
        persist()
        return playlist
    }

    func rename(_ playlist: MixedPlaylist, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[index].name = trimmed
        persist()
    }

    func remove(_ playlist: MixedPlaylist) {
        playlists.removeAll { $0.id == playlist.id }
        persist()
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(playlist.fileName))
    }

    // MARK: - Tracks

    func tracks(of playlist: MixedPlaylist) -> [Track] {
        loadTracks(fileName: playlist.fileName)
    }

    /// Reloads a mixed queue — used by `PlayerService.resolve` when the user
    /// picks the playlist again from "最近播放".
    func tracks(playlistID: Int) -> [Track] {
        guard let playlist = playlist(id: playlistID) else { return [] }
        return tracks(of: playlist)
    }

    func contains(_ track: Track, in playlist: MixedPlaylist) -> Bool {
        let key = Self.identity(of: track)
        return tracks(of: playlist).contains { Self.identity(of: $0) == key }
    }

    func add(_ track: Track, to playlist: MixedPlaylist) throws {
        var items = tracks(of: playlist)
        let key = Self.identity(of: track)
        guard !items.contains(where: { Self.identity(of: $0) == key }) else {
            throw MixedPlaylistError.duplicate
        }
        items.append(track)
        try writeTracksOrThrow(items, fileName: playlist.fileName)
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[index].itemCount = items.count
        persist()
    }

    func add(_ track: Track, toPlaylistWithID id: Int) throws {
        guard let playlist = playlist(id: id) else { throw MixedPlaylistError.missingPlaylist }
        try add(track, to: playlist)
    }

    /// Replaces (or creates) a playlist from a backup payload.
    ///
    /// Used by the WebDAV restore path. Entries arrive as decoded `Track`
    /// values, so the NetEase/plugin split is already resolved by
    /// `Track`'s own decoder. De-duplicates within the incoming list by the
    /// cross-world identity key, so a corrupted backup with repeats still
    /// yields a usable playlist.
    ///
    /// Returns how many tracks landed.
    @discardableResult
    func restorePlaylist(name: String, tracks incoming: [Track]) throws -> Int {
        var seen = Set<String>()
        let unique = incoming.filter { seen.insert(Self.identity(of: $0)).inserted }
        guard !unique.isEmpty else { return 0 }

        // Reuse the existing same-named playlist so a re-import refreshes it
        // instead of piling up duplicates.
        let target = playlists.first { $0.name == name } ?? createPlaylist(name: name)
        try writeTracksOrThrow(unique, fileName: target.fileName)
        guard let index = playlists.firstIndex(where: { $0.id == target.id }) else { return 0 }
        playlists[index].itemCount = unique.count
        persist()
        return unique.count
    }

    func removeTrack(at index: Int, from playlist: MixedPlaylist) {
        var items = tracks(of: playlist)
        guard items.indices.contains(index) else { return }
        items.remove(at: index)
        writeTracks(items, fileName: playlist.fileName)
        guard let position = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[position].itemCount = items.count
        persist()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int, in playlist: MixedPlaylist) {
        var items = tracks(of: playlist)
        items.move(fromOffsets: source, toOffset: destination)
        writeTracks(items, fileName: playlist.fileName)
    }

    // MARK: - Storage

    private func loadTracks(fileName: String) -> [Track] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else { return [] }
        return (try? JSONDecoder().decode([Track].self, from: data)) ?? []
    }

    private func writeTracks(_ tracks: [Track], fileName: String) {
        guard let data = try? JSONEncoder().encode(tracks) else { return }
        try? data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
    }

    private func writeTracksOrThrow(_ tracks: [Track], fileName: String) throws {
        guard let data = try? JSONEncoder().encode(tracks) else { throw MixedPlaylistError.writeFailed }
        do {
            try data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
        } catch {
            throw MixedPlaylistError.writeFailed
        }
    }
}
