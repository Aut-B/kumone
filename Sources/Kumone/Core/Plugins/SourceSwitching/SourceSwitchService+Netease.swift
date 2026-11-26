import Foundation

extension SourceSwitchService {
    /// Direct `MusicAPI` song search: 10 rows are enough for the matcher to
    /// pick from without downloading a page of noise.
    static func searchNeteaseSongs(_ query: String) async throws -> MusicAPI.SearchResult {
        try await MusicAPI.search(query, type: .songs, limit: 10)
    }

    /// Switches one entry to a NetEase song reference.
    ///
    /// This talks to `MusicAPI` instead of the NetEase plugin's JS search so
    /// the target list keeps a single, always-available NetEase row. A match is
    /// stored as a thin `.netease` reference: the URL is resolved again from
    /// the song id at play time, so lyrics and comments keep working.
    func switchEntryToNetease(_ entry: LocalTrackEntry) async -> SourceSwitchOutcome {
        let targetName = SourceSwitchTarget.netease.title
        if case .netease = entry {
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
            let result = try await neteaseSearch(query)
            let tracks = result.songs ?? []
            let candidates = tracks.map(\.sourceCandidate)
            guard let match = SourceMatcher.bestMatch(
                for: SourceMatchQuery(entry: entry),
                among: candidates
            ), let track = tracks.first(where: { $0.sourceCandidate.identity == match.identity })
            else {
                return failure(entry, targetName: targetName, error: .notFound)
            }

            let song = LocalNeteaseSong(
                id: track.id,
                name: track.name,
                artist: track.artists.map(\.name).joined(separator: " / "),
                album: track.album.name,
                picUrl: track.album.picUrl,
                durationMS: track.durationMS,
                fee: track.fee
            )
            let replacement = LocalTrackEntry.netease(song)
            return SourceSwitchOutcome(
                sourceID: entry.id,
                sourceTitle: entry.title,
                sourceArtist: entry.artist,
                targetName: targetName,
                replacementID: replacement.id,
                error: nil,
                replacement: replacement
            )
        } catch {
            return failure(
                entry,
                targetName: targetName,
                error: .searchFailed(error.localizedDescription)
            )
        }
    }

    /// NetEase counterpart of `switchEntries`: one request at a time, spaced
    /// by the shared throttle. Entries that miss keep their old value.
    func switchEntriesToNetease(
        _ entries: [LocalTrackEntry],
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
            outcomes.append(await switchEntryToNetease(entry))
            progress(index + 1, total)
        }
        return outcomes
    }
}
