import Foundation

/// Readings the system analyser gets wrong for song lyrics.
///
/// Two kinds of entries live here. Some words have several readings that no
/// analyser can disambiguate, because the surface form is identical and only
/// the register differs: 私 is わたくし in the dictionary but わたし in every
/// song. Others are simply mis-segmented, like 一日 coming back as 一/いち plus
/// 日/にち. Both are fixed by forcing the surface and its reading before
/// tokenisation runs.
enum ReadingOverrides {
    static let table: [String: String] = [
        // Register: the dictionary form is the formal one, lyrics use the
        // contracted one.
        "私": "わたし",
        "私達": "わたしたち",
        "私たち": "わたしたち",

        // Ambiguous readings with no contextual signal.
        "明日": "あした",
        // 君 is くん as an honorific and きみ as "you"; lyrics mean the latter.
        "君": "きみ",
        "日本": "にほん",
        // 隙 is ひま in the dictionary but すき in ordinary modern use.
        "隙": "すき",

        // Mis-segmented by the tokenizer.
        "一日": "いちにち",
        "一日中": "いちにちじゅう",
        // Read as two words, which loses the rendaku: き + つき, not きづき.
        "気付": "きづ",
        "一昨日": "おととい",
        "十分": "じゅうぶん",
    ]

    /// Longest first, so 私達 wins over 私.
    private static let sortedKeys: [String] = table.keys.sorted { $0.count > $1.count }

    /// Longest match starting at `index`.
    static func match(_ characters: [Character], at index: Int) -> (surface: String, reading: String)? {
        for key in sortedKeys {
            let length = key.count
            guard index + length <= characters.count else { continue }
            if String(characters[index..<(index + length)]) == key, let reading = table[key] {
                return (key, reading)
            }
        }
        return nil
    }

    /// Rewrites every overridden word as its kana reading. Feeding the result
    /// back to the tokenizer is what makes 私 transcribe as `watashi` rather
    /// than the dictionary's `watakushi`.
    static func applied(to text: String) -> String {
        guard Kana.containsKanji(text) else { return text }
        var result = ""
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            if let hit = match(characters, at: index) {
                result += hit.reading
                index += hit.surface.count
            } else {
                result.append(characters[index])
                index += 1
            }
        }
        return result
    }
}
