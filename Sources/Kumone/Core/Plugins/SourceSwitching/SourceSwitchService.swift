import Foundation

/// Matches one playlist entry against a target plugin's search results.
///
/// The service is deliberately read-only: it searches and matches, but the
/// playlist write stays with the caller. `search` and `probe` are injected so
/// tests never need a mounted JS plugin; `throttleNanoseconds` is the spacing
/// later batch switches use between requests.
@MainActor
final class SourceSwitchService {
    typealias Search = @MainActor (String, String, Int) async throws -> (isEnd: Bool, items: [PluginMusicItem])
    typealias Probe = @MainActor (String, PluginMusicItem) async -> PluginMediaSource

    static let shared = SourceSwitchService()

    private let search: Search
    private let probe: Probe
    /// Spacing between requests; batch callers use it to keep older devices
    /// from firing every search at once.
    let throttleNanoseconds: UInt64

    init(
        search: Search? = nil,
        probe: Probe? = nil,
        throttleNanoseconds: UInt64 = 700_000_000
    ) {
        if let search {
            self.search = search
        } else {
            self.search = { platform, query, page in
                try await PluginManager.shared.search(platform: platform, query: query, page: page)
            }
        }
        if let probe {
            self.probe = probe
        } else {
            self.probe = { platform, item in
                await PluginManager.shared.getMediaSource(
                    platform: platform,
                    item: item,
                    quality: SettingsManager.shared.audioQuality.pluginQuality
                )
            }
        }
        self.throttleNanoseconds = throttleNanoseconds
    }

    func switchEntry(_ entry: LocalTrackEntry, to platform: String) async -> SourceSwitchOutcome {
        let targetName = SourceSwitchTarget.plugin(platform).title
        guard !Self.isSameSource(platform: platform, entry: entry) else {
            return failure(entry, targetName: targetName, error: .samePlatform)
        }

        let query = "\(entry.title) \(entry.artist)"
            .trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let page = try await search(platform, query, 1)
            let candidates = page.items.map(\.sourceCandidate)
            let match = SourceMatcher.bestMatch(
                for: SourceMatchQuery(entry: entry),
                among: candidates
            )
            guard let match,
                  let item = page.items.first(where: { $0.sourceCandidate.identity == match.identity })
            else {
                return failure(entry, targetName: targetName, error: .notFound)
            }
            return SourceSwitchOutcome(
                sourceID: entry.id,
                sourceTitle: entry.title,
                sourceArtist: entry.artist,
                targetName: targetName,
                replacementID: match.identity,
                error: nil,
                replacement: Self.storableEntry(from: item, platform: platform)
            )
        } catch {
            return failure(
                entry,
                targetName: targetName,
                error: .searchFailed(error.localizedDescription)
            )
        }
    }

    /// A plugin's search payload does not carry the routing key — that lives in
    /// the caller's context. Playlist storage reloads plugin entries from
    /// `rawJSON` alone, so persist the platform with the payload or the entry
    /// becomes unroutable after a relaunch.
    private static func storableEntry(
        from item: PluginMusicItem,
        platform: String
    ) -> LocalTrackEntry {
        let data = item.rawJSON.data(using: .utf8)
        guard let object = data.flatMap({ try? JSONSerialization.jsonObject(with: $0) }),
              var dict = object as? [String: Any]
        else {
            return .plugin(item)
        }
        if (dict["id"] as? String)?.isEmpty != false {
            dict["id"] = item.itemID
        }
        dict["platform"] = platform
        guard let stored = PluginMusicItem(normalizing: dict, platform: platform) else {
            return .plugin(item)
        }
        return .plugin(stored)
    }

    /// NetEase entries store a localized display name rather than a registry
    /// key, so every NetEase spelling counts as the same source.
    nonisolated static func isSameSource(platform: String, entry: LocalTrackEntry) -> Bool {
        let target = platform.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return false }

        switch entry {
        case .netease:
            return isNeteaseSource(platform: target)
        case .plugin(let item):
            return target.lowercased() == item.platform.lowercased()
        }
    }

    nonisolated static func isNeteaseSource(platform: String) -> Bool {
        let trimmed = platform.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lowered = trimmed.lowercased()
        return lowered.contains("netease")
            || lowered.contains("163")
            || trimmed.contains("网易")
    }

    private func failure(
        _ entry: LocalTrackEntry,
        targetName: String,
        error: SourceSwitchError
    ) -> SourceSwitchOutcome {
        SourceSwitchOutcome(
            sourceID: entry.id,
            sourceTitle: entry.title,
            sourceArtist: entry.artist,
            targetName: targetName,
            replacementID: nil,
            error: error
        )
    }
}
