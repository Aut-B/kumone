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
    typealias PluginList = @MainActor () -> [PluginManager.InstalledPlugin]
    typealias NeteaseSearch = @MainActor (String) async throws -> MusicAPI.SearchResult

    static let shared = SourceSwitchService()

    private let search: Search
    private let probe: Probe
    private let availablePlugins: PluginList
    /// Direct NetEase search; the plugin JS path would duplicate the NetEase
    /// row in the target list, so this one is injected separately.
    let neteaseSearch: NeteaseSearch
    /// Spacing between requests; batch callers use it to keep older devices
    /// from firing every search at once.
    let throttleNanoseconds: UInt64

    init(
        search: Search? = nil,
        probe: Probe? = nil,
        plugins: PluginList? = nil,
        neteaseSearch: NeteaseSearch? = nil,
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
        if let plugins {
            self.availablePlugins = plugins
        } else {
            self.availablePlugins = { PluginManager.shared.plugins }
        }
        if let neteaseSearch {
            self.neteaseSearch = neteaseSearch
        } else {
            self.neteaseSearch = { query in
                try await Self.searchNeteaseSongs(query)
            }
        }
        self.throttleNanoseconds = throttleNanoseconds
    }

    func switchEntry(_ entry: LocalTrackEntry, to platform: String) async -> SourceSwitchOutcome {
        let targetName = SourceSwitchTarget.plugin(platform).title
        guard !Self.isSameSource(platform: platform, entry: entry) else {
            return failure(entry, targetName: targetName, error: .samePlatform)
        }

        let query = Self.searchQuery(for: entry)
        guard Self.hasSearchableTitle(entry) else {
            return failure(
                entry,
                targetName: targetName,
                error: .searchFailed(String(localized: "歌曲信息不完整，无法搜索"))
            )
        }
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

    /// Switches several entries to one target, strictly one request at a time.
    ///
    /// Older devices stutter when a whole selection hits the JS engine at once,
    /// so each song waits for the previous one and for the shared throttle
    /// before it starts. `progress` is called after every finished song with
    /// `(done, total)`; entries that cannot be matched keep their old value.
    func switchEntries(
        _ entries: [LocalTrackEntry],
        to platform: String,
        progress: @escaping (Int, Int) -> Void
    ) async -> [SourceSwitchOutcome] {
        guard !entries.isEmpty else { return [] }

        let total = entries.count
        var outcomes: [SourceSwitchOutcome] = []
        outcomes.reserveCapacity(total)
        for (index, entry) in entries.enumerated() {
            if index > 0 {
                try? await Task.sleep(nanoseconds: throttleNanoseconds)
            }
            let outcome = await switchEntry(entry, to: platform)
            outcomes.append(outcome)
            progress(index + 1, total)
        }
        return outcomes
    }

    /// Probes every enabled plugin in registration order and adopts the first
    /// one whose media source actually resolves to a URL.
    ///
    /// A search error, a missing match, or a source without a URL only rules
    /// out that plugin; the next one gets a turn. When every plugin is ruled
    /// out the outcome carries a line per source so the report can explain
    /// exactly why nothing was replaced.
    func switchEntrySmart(_ entry: LocalTrackEntry) async -> SourceSwitchOutcome {
        let targetName = SourceSwitchTarget.smart.title
        let plugins = availablePlugins().filter(\.enabled)
        guard !plugins.isEmpty else {
            return failure(
                entry,
                targetName: targetName,
                error: .allSourcesFailed(String(localized: "没有启用的插件音源"))
            )
        }

        let query = Self.searchQuery(for: entry)
        guard Self.hasSearchableTitle(entry) else {
            return failure(
                entry,
                targetName: targetName,
                error: .searchFailed(String(localized: "歌曲信息不完整，无法搜索"))
            )
        }
        var failures: [String] = []
        var attempted = 0

        for plugin in plugins {
            guard !Self.isSameSource(platform: plugin.platform, entry: entry) else { continue }
            attempted += 1

            do {
                let page = try await search(plugin.platform, query, 1)
                let candidates = page.items.map(\.sourceCandidate)
                guard let match = SourceMatcher.bestMatch(
                    for: SourceMatchQuery(entry: entry),
                    among: candidates
                ), let item = page.items.first(where: { $0.sourceCandidate.identity == match.identity })
                else {
                    failures.append(
                        "\(plugin.name)：\(String(localized: "未找到匹配条目"))"
                    )
                    continue
                }

                let source = await probe(plugin.platform, item)
                guard source.url != nil else {
                    let reason = source.failureReason ?? String(localized: "未取得播放地址")
                    failures.append("\(plugin.name)：\(reason)")
                    continue
                }

                return SourceSwitchOutcome(
                    sourceID: entry.id,
                    sourceTitle: entry.title,
                    sourceArtist: entry.artist,
                    targetName: plugin.name,
                    replacementID: match.identity,
                    error: nil,
                    replacement: Self.storableEntry(from: item, platform: plugin.platform)
                )
            } catch {
                failures.append("\(plugin.name)：\(error.localizedDescription)")
            }
        }

        let details: String
        if attempted == 0 {
            details = String(localized: "没有可用的其他音源")
        } else {
            details = failures.joined(separator: "\n")
        }
        return failure(entry, targetName: targetName, error: .allSourcesFailed(details))
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

    /// Trimmed "<title> <artist>" pair sent to every source.
    nonisolated static func searchQuery(for entry: LocalTrackEntry) -> String {
        "\(entry.title) \(entry.artist)"
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A blank title makes any match a guess, so every source search skips it.
    nonisolated static func hasSearchableTitle(_ entry: LocalTrackEntry) -> Bool {
        !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Hides an installed NetEase-family plugin in favour of the direct row.
    ///
    /// Some builds expose an opaque platform name ("元力WY"), so the source
    /// URL is checked as a second signal; every preset NetEase build ships as
    /// `wy.js`.
    nonisolated static func isNeteasePlugin(platform: String, sourceURL: String?) -> Bool {
        if isNeteaseSource(platform: platform) { return true }
        guard let sourceURL else { return false }
        let path = sourceURL.lowercased().split(separator: "?").first.map(String.init) ?? ""
        return path.hasSuffix("/wy.js")
    }

    nonisolated static func isNeteaseSource(platform: String) -> Bool {
        let trimmed = platform.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lowered = trimmed.lowercased()
        return lowered.contains("netease")
            || lowered.contains("163")
            || trimmed.contains("网易")
            || lowered == "wy"
            || lowered == "元力wy"
    }

    func failure(
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
