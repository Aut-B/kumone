import SwiftUI

/// The lyric itself, with furigana over the kanji when the reader asked for it
/// and the line has kanji worth annotating.
///
/// Every other case falls through to a plain `Text`, so lyrics that are not
/// Japanese, and the two annotation modes that are not furigana, keep exactly
/// the rendering they had.
struct LyricText: View {
    let line: LyricLine
    let size: CGFloat
    var weight: Font.Weight = .regular
    var color: Color = .primary
    var alignment: NSTextAlignment = .left
    var rounded: Bool = false

    @EnvironmentObject private var settings: SettingsManager

    var body: some View {
        if settings.lyricsAnnotation == .furigana, let furigana = line.furigana {
            RubyText(
                segments: furigana,
                size: size,
                weight: weight,
                color: color,
                rubyColor: color.opacity(0.72),
                alignment: alignment,
                rounded: rounded
            )
        } else {
            Text(line.text.isEmpty ? "♪" : line.text)
                .font(.system(size: size, weight: weight, design: rounded ? .rounded : .default))
                .foregroundStyle(color)
        }
    }
}
