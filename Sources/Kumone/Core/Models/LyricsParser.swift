import Foundation

/// One timed word (or short run) inside a verbatim (yrc) lyric line.
struct LyricWord: Hashable {
    let text: String
    let start: TimeInterval
    let duration: TimeInterval
    var end: TimeInterval { start + duration }
}

struct LyricLine: Identifiable, Hashable {
    let id: Int
    let time: TimeInterval
    let text: String
    var translation: String?
    var romaji: String?
    /// Base text split so each reading sits over the kanji it belongs to.
    /// Nil when there is nothing to annotate.
    var furigana: [RubySegment]?
    /// Per-word timings for karaoke highlighting; nil when only line-level
    /// (lrc) timing is available.
    var words: [LyricWord]?
}

struct ParsedLyrics: Hashable {
    var lines: [LyricLine] = []
    var isInstrumental = false
    var contributor: String?
    var translationContributor: String?

    var isEmpty: Bool { lines.isEmpty }

    /// Index of the active line for a playback position.
    func activeIndex(at time: TimeInterval) -> Int? {
        guard !lines.isEmpty else { return nil }
        var low = 0, high = lines.count - 1, result: Int? = nil
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].time <= time {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }
}

enum LyricsParser {
    /// iOS 15 has no Swift `Regex`, so every pattern goes through
    /// `NSRegularExpression` instead.
    private static func pattern(_ string: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: string, options: [])
    }

    private static func group(
        _ index: Int,
        of match: NSTextCheckingResult,
        in text: String
    ) -> String? {
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
        return String(text[swiftRange])
    }

    private static func allMatches(
        of pattern: NSRegularExpression?,
        in text: String
    ) -> [NSTextCheckingResult] {
        guard let pattern else { return [] }
        return pattern.matches(in: text, options: [], range: NSRange(text.startIndex..<text.endIndex, in: text))
    }

    /// Parses an LRC body into (time, text) pairs. Handles multiple timestamps
    /// per line and both `.` / `:` millisecond separators.
    static func parseLRC(_ lrc: String) -> [(time: TimeInterval, text: String)] {
        var result: [(TimeInterval, String)] = []
        let timeTag = pattern(#"\[(\d+):(\d+)(?:[.:](\d+))?\]"#)

        for rawLine in lrc.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let found = allMatches(of: timeTag, in: line)
            guard !found.isEmpty, let lastMatch = found.last,
                  let upperBound = Range(lastMatch.range, in: line) else { continue }
            let content = String(line[upperBound.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            for match in found {
                let minutes = Double(group(1, of: match, in: line) ?? "") ?? 0
                let seconds = Double(group(2, of: match, in: line) ?? "") ?? 0
                var fraction = 0.0
                if let msText = group(3, of: match, in: line), let ms = Double(msText) {
                    fraction = ms / pow(10, Double(msText.count))
                }
                result.append((minutes * 60 + seconds + fraction, content))
            }
        }
        return result.sorted { $0.0 < $1.0 }
    }

    /// Parses NetEase verbatim `yrc` lyrics: each content line is
    /// `[lineStartMs,lineDurMs](wStartMs,wDurMs,0)word(...)word…`. JSON metadata
    /// (credits) lines at the top don't match the `[num,num]` head and are
    /// skipped.
    static func parseYRC(_ yrc: String) -> [LyricLine] {
        let lineTag = pattern(#"^\[(\d+),(\d+)\]"#)
        let wordTag = pattern(#"\((\d+),(\d+),\d+\)([^(]*)"#)
        var lines: [LyricLine] = []
        var idx = 0
        for raw in yrc.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let head = allMatches(of: lineTag, in: line).first else { continue }
            let lineStart = (Double(group(1, of: head, in: line) ?? "") ?? 0) / 1000
            var words: [LyricWord] = []
            var text = ""
            for word in allMatches(of: wordTag, in: line) {
                let start = (Double(group(1, of: word, in: line) ?? "") ?? 0) / 1000
                let duration = (Double(group(2, of: word, in: line) ?? "") ?? 0) / 1000
                let piece = group(3, of: word, in: line) ?? ""
                words.append(LyricWord(text: piece, start: start, duration: duration))
                text += piece
            }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !words.isEmpty else { continue }
            lines.append(LyricLine(id: idx, time: lineStart, text: trimmed, words: words))
            idx += 1
        }
        return lines
    }

    static func parse(_ response: LyricResponse) -> ParsedLyrics {
        var out = ParsedLyrics()
        out.contributor = response.lyricUser?.nickname
        out.translationContributor = response.transUser?.nickname

        guard let raw = response.lrc?.lyric, !raw.isEmpty else { return out }
        var main = parseLRC(raw)

        // Instrumental marker handling (mirrors YesPlayMusic).
        let instrumentalMarker = "纯音乐，请欣赏"
        if main.count <= 10, main.contains(where: { $0.text.contains(instrumentalMarker) }) {
            out.isInstrumental = true
            main.removeAll { line in
                line.text.contains(instrumentalMarker)
                    || line.text.range(of: #"^作(词|曲)\s*[:：]"#, options: .regularExpression) != nil
            }
            if main.isEmpty {
                return out
            }
        }
        main.removeAll { $0.text.range(of: #"^作(词|曲)\s*[:：]\s*无$"#, options: .regularExpression) != nil }

        var lines = main.enumerated().map { idx, pair in
            LyricLine(id: idx, time: pair.time, text: pair.text)
        }
        // Prefer verbatim (word-by-word) lines when the song has them.
        if let yrcRaw = response.yrc?.lyric, !yrcRaw.isEmpty {
            let yrcLines = parseYRC(yrcRaw)
            if !yrcLines.isEmpty { lines = yrcLines }
        }

        func merge(_ body: String?, into keyPath: WritableKeyPath<LyricLine, String?>) {
            guard let body, !body.isEmpty else { return }
            let secondary = parseLRC(body).filter { !$0.text.isEmpty }
            guard !secondary.isEmpty else { return }
            for i in lines.indices {
                // Nearest secondary line within 0.3s: verbatim (yrc) line times
                // can differ from the lrc-based translation/romaji by a few ms.
                var best: (delta: TimeInterval, text: String)?
                for (time, text) in secondary {
                    let delta = abs(time - lines[i].time)
                    if best == nil || delta < best!.delta { best = (delta, text) }
                }
                if let best, best.delta < 0.3 {
                    lines[i][keyPath: keyPath] = best.text
                }
            }
        }

        merge(response.ytlrc?.lyric ?? response.tlyric?.lyric, into: \.translation)
        merge(response.yromalrc?.lyric ?? response.romalrc?.lyric, into: \.romaji)

        // Readings are only meaningful for Japanese lyrics: fill the romaji
        // gaps Netease left, annotate the kanji, and drop stray annotations on
        // everything else. Both are done here rather than in the view so a line
        // is analysed once per track instead of once per frame.
        if RomajiTranscriber.isJapanese(lines.map(\.text)) {
            for i in lines.indices {
                if lines[i].romaji == nil {
                    lines[i].romaji = RomajiTranscriber.transcribe(lines[i].text)
                }
                lines[i].furigana = Furigana.segments(for: lines[i].text)
            }
        } else {
            for i in lines.indices {
                lines[i].romaji = nil
            }
        }

        out.lines = lines
        return out
    }
}
