/// Outcome of replacing playlist entries in place.
///
/// `replacedIDs` are the original entry ids that were replaced, in playlist
/// order. `skippedIDs` are originals whose replacement would have introduced a
/// duplicate id; those positions keep their previous entry.
struct LocalPlaylistReplaceResult: Equatable {
    let entries: [LocalTrackEntry]
    let replacedIDs: [String]
    let skippedIDs: [String]

    var replacedCount: Int { replacedIDs.count }
}

/// Pure, order-preserving replacement of whole playlist entries.
enum LocalPlaylistReplacement {
    static func apply(
        _ replacements: [String: LocalTrackEntry],
        to entries: [LocalTrackEntry]
    ) -> LocalPlaylistReplaceResult {
        guard !replacements.isEmpty else {
            return LocalPlaylistReplaceResult(entries: entries, replacedIDs: [], skippedIDs: [])
        }

        var proposed = entries
        var candidateIndexes: [Int] = []
        for index in entries.indices {
            guard let replacement = replacements[entries[index].id] else { continue }
            proposed[index] = replacement
            candidateIndexes.append(index)
        }
        guard !candidateIndexes.isEmpty else {
            return LocalPlaylistReplaceResult(entries: entries, replacedIDs: [], skippedIDs: [])
        }

        var occurrences: [String: Int] = [:]
        for entry in proposed {
            occurrences[entry.id, default: 0] += 1
        }

        var skipped = Set<String>()
        for index in candidateIndexes where (occurrences[proposed[index].id] ?? 0) > 1 {
            proposed[index] = entries[index]
            skipped.insert(entries[index].id)
        }

        let replacedIDs = entries
            .filter { replacements[$0.id] != nil && !skipped.contains($0.id) }
            .map(\.id)
        let skippedIDs = entries
            .filter { replacements[$0.id] != nil && skipped.contains($0.id) }
            .map(\.id)
        return LocalPlaylistReplaceResult(
            entries: proposed,
            replacedIDs: replacedIDs,
            skippedIDs: skippedIDs
        )
    }
}
