import Foundation

/// The fields a source switch compares: what we are looking for and what a
/// target source returned.
struct SourceMatchQuery: Hashable, Sendable {
    let title: String
    let artist: String
    let album: String
    let durationMS: Int

    init(title: String, artist: String, album: String = "", durationMS: Int) {
        self.title = title
        self.artist = artist
        self.album = album
        self.durationMS = durationMS
    }

    init(entry: LocalTrackEntry) {
        self.init(
            title: entry.title,
            artist: entry.artist,
            album: entry.album,
            durationMS: entry.durationMS
        )
    }
}

/// One result row from a target source, detached from its storage model.
struct SourceCandidate: Hashable, Identifiable, Sendable {
    let identity: String
    let title: String
    let artist: String
    let album: String
    let durationMS: Int

    var id: String { identity }
}

/// Conservative title/artist/duration matching shared by plugin and NetEase
/// source switching.
///
/// A false negative is a report row; a false positive replaces a song with the
/// wrong recording. The scorer therefore gates on artist overlap and refuses
/// to choose between two close candidates sung by different artists.
enum SourceMatcher {
    static func normalize(_ raw: String) -> String {
        var text = halfwidth(raw).lowercased()
        text = stripFeaturingSuffix(text)
        text = stripBracketed(text)
        text = stripDashSubtitle(text)
        text = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return text.trimmingCharacters(in: trimmingSet)
    }

    static func score(query: SourceMatchQuery, candidate: SourceCandidate) -> Double {
        let queryTitle = normalize(query.title)
        let candidateTitle = normalize(candidate.title)
        guard !queryTitle.isEmpty, !candidateTitle.isEmpty else { return 0 }

        let queryArtist = normalize(query.artist)
        let candidateArtist = normalize(candidate.artist)
        let artistScore = artistSimilarity(queryArtist, candidateArtist)
        if !queryArtist.isEmpty, !candidateArtist.isEmpty, artistScore == 0 {
            return 0
        }

        let titleScore = bigramDice(queryTitle, candidateTitle)
        let durationScore = durationProximity(query.durationMS, candidate.durationMS)
        return titleScore * 0.65 + artistScore * 0.25 + durationScore * 0.10
    }

    static func bestMatch(
        for query: SourceMatchQuery,
        among candidates: [SourceCandidate]
    ) -> SourceCandidate? {
        let ranked = candidates
            .map { (candidate: $0, score: score(query: query, candidate: $0)) }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.candidate.identity < $1.candidate.identity
            }

        guard let best = ranked.first, best.score >= 0.6 else { return nil }

        if ranked.count > 1 {
            let runnerUp = ranked[1]
            let difference = best.score - runnerUp.score
            let artistsDiffer = normalize(best.candidate.artist)
                != normalize(runnerUp.candidate.artist)
            if difference < 0.05 - 1e-9, artistsDiffer {
                return nil
            }
        }
        return best.candidate
    }

    // MARK: - Scoring pieces

    private static func bigramDice(_ lhs: String, _ rhs: String) -> Double {
        let left = lhs.filter { !$0.isWhitespace }
        let right = rhs.filter { !$0.isWhitespace }
        if left == right { return 1 }

        let leftChars = Array(left)
        let rightChars = Array(right)
        guard leftChars.count > 1, rightChars.count > 1 else { return 0 }

        var remaining: [String: Int] = [:]
        for index in 0..<(leftChars.count - 1) {
            let gram = String(leftChars[index...index + 1])
            remaining[gram, default: 0] += 1
        }

        var overlap = 0
        for index in 0..<(rightChars.count - 1) {
            let gram = String(rightChars[index...index + 1])
            if let count = remaining[gram], count > 0 {
                overlap += 1
                remaining[gram] = count - 1
            }
        }
        return 2.0 * Double(overlap) / Double(leftChars.count + rightChars.count - 2)
    }

    /// Exact or containment only; fuzzy artist names are too easy to confuse
    /// with a different act that shares a word.
    private static func artistSimilarity(_ lhs: String, _ rhs: String) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        if lhs == rhs { return 1 }

        let left = lhs.filter { !$0.isWhitespace }
        let right = rhs.filter { !$0.isWhitespace }
        if left == right { return 1 }
        if left.count >= 2, right.contains(left) { return 0.8 }
        if right.count >= 2, left.contains(right) { return 0.8 }
        return 0
    }

    private static func durationProximity(_ lhs: Int, _ rhs: Int) -> Double {
        guard lhs > 0, rhs > 0 else { return 0.5 }
        let delta = abs(lhs - rhs)
        guard delta <= 10_000 else { return 0 }
        return 1.0 - Double(delta) / 10_000.0
    }

    // MARK: - Normalization

    private static let trimmingSet = CharacterSet(
        charactersIn: " -–—·•,，.。:：;；!?！？~～\"'“”‘’"
    )

    private static let openingBrackets: Set<Character> = [
        "(", "[", "{", "【", "「", "『", "〈", "《", "〔",
    ]

    private static let closingBrackets: Set<Character> = [
        ")", "]", "}", "】", "」", "』", "〉", "》", "〕",
    ]

    private static func halfwidth(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0xFF01...0xFF5E:
                result.unicodeScalars.append(UnicodeScalar(scalar.value - 0xFEE0)!)
            case 0x3000, 0x3001, 0x2026, 0x00B7, 0x30FB:
                result.append(" ")
            case 0x3002:
                result.append(".")
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private static func stripBracketed(_ text: String) -> String {
        var result = ""
        var depth = 0
        for character in text {
            if openingBrackets.contains(character) {
                depth += 1
                continue
            }
            if closingBrackets.contains(character) {
                if depth > 0 { depth -= 1 }
                continue
            }
            if depth == 0 { result.append(character) }
        }
        return result
    }

    private static func stripFeaturingSuffix(_ text: String) -> String {
        for marker in [" feat. ", " feat ", " ft. ", " ft ", " featuring "] {
            if let range = text.range(of: marker) {
                return String(text[..<range.lowerBound])
            }
        }
        return text
    }

    private static func stripDashSubtitle(_ text: String) -> String {
        for separator in [" – ", " — ", " –", " —", "–", "—", " - "] {
            if let range = text.range(of: separator) {
                return String(text[..<range.lowerBound])
            }
        }
        return text
    }
}

extension PluginMusicItem {
    var sourceCandidate: SourceCandidate {
        SourceCandidate(
            identity: id,
            title: title,
            artist: artist,
            album: album,
            durationMS: durationMS
        )
    }
}

extension Track {
    var sourceCandidate: SourceCandidate {
        let identity = plugin.map { "\($0.platform)|\($0.itemID)" } ?? "netease|\(id)"
        return SourceCandidate(
            identity: identity,
            title: name,
            artist: artistNames,
            album: album.name,
            durationMS: durationMS
        )
    }
}
