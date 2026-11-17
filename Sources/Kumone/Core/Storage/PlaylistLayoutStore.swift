import Foundation
import SwiftUI

/// Display-only layout preferences: pinned playlists, the order playlists are
/// listed in, and the manual track order inside a NetEase playlist.
///
/// NetEase exposes no write API for "reorder the tracks of a playlist", so the
/// track order here is a **local view override**: it changes what you see and
/// play on this device, never the server's order. Local (plugin) playlists are
/// stored on device, so their order is the real one.
/// Deliberately not `@MainActor`: views hold it as an `@ObservedObject`
/// property, and a main-actor-isolated `shared` cannot be read from a
/// property initialiser without a concurrency warning. Every call happens on
/// the main thread anyway.
final class PlaylistLayoutStore: ObservableObject {
    static let shared = PlaylistLayoutStore()

    struct Snapshot: Codable {
        var pinnedCloud: [Int] = []
        var pinnedLocal: [String] = []
        var cloudOrder: [Int] = []
        var localOrder: [String] = []
        /// Keyed by the playlist id as a string — JSON object keys must be.
        var trackOrder: [String: [Int]] = [:]
    }

    @Published private(set) var snapshot: Snapshot

    private let storageKey = "kumone.playlistLayout.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(Snapshot.self, from: data) {
            snapshot = decoded
        } else {
            snapshot = Snapshot()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    // MARK: - Pinning

    func isPinned(cloud id: Int) -> Bool { snapshot.pinnedCloud.contains(id) }
    func isPinned(local id: UUID) -> Bool { snapshot.pinnedLocal.contains(id.uuidString) }

    func togglePin(cloud id: Int) {
        if let index = snapshot.pinnedCloud.firstIndex(of: id) {
            snapshot.pinnedCloud.remove(at: index)
        } else {
            snapshot.pinnedCloud.append(id)
        }
        save()
    }

    func togglePin(local id: UUID) {
        let key = id.uuidString
        if let index = snapshot.pinnedLocal.firstIndex(of: key) {
            snapshot.pinnedLocal.remove(at: index)
        } else {
            snapshot.pinnedLocal.append(key)
        }
        save()
    }

    // MARK: - Ordering helper

    /// Sorts by position in `order`, keeping the incoming relative order for
    /// anything not recorded yet (Swift's sort is not stable).
    private func arranged<T>(_ items: [T], key: (T) -> String, order: [String]) -> [T] {
        let ranked = items.enumerated().map { index, item in
            (item: item, rank: order.firstIndex(of: key(item)) ?? Int.max, index: index)
        }
        return ranked.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.index < rhs.index
        }.map(\.item)
    }

    private func partitioned<T>(_ items: [T], key: (T) -> String, order: [String], pinned: Set<String>) -> [T] {
        let leading = arranged(items.filter { pinned.contains(key($0)) }, key: key, order: order)
        let trailing = arranged(items.filter { !pinned.contains(key($0)) }, key: key, order: order)
        return leading + trailing
    }

    // MARK: - Cloud playlists

    func orderedCloud(_ playlists: [PlaylistSummary]) -> [PlaylistSummary] {
        partitioned(
            playlists,
            key: { String($0.id) },
            order: snapshot.cloudOrder.map(String.init),
            pinned: Set(snapshot.pinnedCloud.map(String.init))
        )
    }

    /// Rewrites the stored cloud order from the list the user just dragged.
    func setCloudOrder(_ playlists: [PlaylistSummary]) {
        snapshot.cloudOrder = playlists.map(\.id)
        save()
    }

    // MARK: - Local playlists

    func orderedLocal(_ playlists: [ImportedPlaylist]) -> [ImportedPlaylist] {
        partitioned(
            playlists,
            key: \.id.uuidString,
            order: snapshot.localOrder,
            pinned: Set(snapshot.pinnedLocal)
        )
    }

    func setLocalOrder(_ playlists: [ImportedPlaylist]) {
        snapshot.localOrder = playlists.map(\.id.uuidString)
        save()
    }

    /// Forgets layout entries of local playlists that no longer exist.
    func pruneLocal(keeping playlists: [ImportedPlaylist]) {
        let live = Set(playlists.map(\.id.uuidString))
        snapshot.localOrder.removeAll { !live.contains($0) }
        snapshot.pinnedLocal.removeAll { !live.contains($0) }
        save()
    }

    // MARK: - Tracks inside a NetEase playlist

    /// Applies the locally saved order; tracks missing from it keep their
    /// incoming position and are appended after the known ones.
    func orderedTracks(_ tracks: [Track], playlistID: Int) -> [Track] {
        guard let order = snapshot.trackOrder[String(playlistID)], !order.isEmpty else { return tracks }
        var byID: [Int: Track] = [:]
        for track in tracks { byID[track.id] = track }
        var result: [Track] = []
        var used: Set<Int> = []
        for id in order {
            if let track = byID[id] {
                result.append(track)
                used.insert(id)
            }
        }
        result.append(contentsOf: tracks.filter { !used.contains($0.id) })
        return result
    }

    func setTrackOrder(_ tracks: [Track], playlistID: Int) {
        snapshot.trackOrder[String(playlistID)] = tracks.map(\.id)
        save()
    }

    func clearTrackOrder(playlistID: Int) {
        snapshot.trackOrder.removeValue(forKey: String(playlistID))
        save()
    }

    func hasCustomTrackOrder(playlistID: Int) -> Bool {
        snapshot.trackOrder[String(playlistID)] != nil
    }
}
