import SwiftUI

/// In-memory search inside a list you already have.
///
/// Playlist screens hold every song already — filtering needs no request, just
/// the fields a listener actually remembers: title, artist, album. Matching is
/// case-insensitive and ignores surrounding whitespace so "周杰伦 " finds
/// everything of his.
enum TrackFilter {
    static func query(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func matches(_ track: Track, by raw: String) -> Bool {
        let q = query(raw)
        guard !q.isEmpty else { return true }
        return track.name.lowercased().contains(q)
            || track.artistNames.lowercased().contains(q)
            || track.album.name.lowercased().contains(q)
    }

    static func filter(_ tracks: [Track], by raw: String) -> [Track] {
        let q = query(raw)
        guard !q.isEmpty else { return tracks }
        return tracks.filter { matches($0, by: q) }
    }

    /// Same pass for the plugin-only lists, which hand out `PluginMusicItem`
    /// rather than `Track`.
    static func filterItems(_ items: [PluginMusicItem], by raw: String) -> [PluginMusicItem] {
        let q = query(raw)
        guard !q.isEmpty else { return items }
        return items.filter { item in
            item.title.lowercased().contains(q)
                || item.artist.lowercased().contains(q)
                || item.album.lowercased().contains(q)
        }
    }
}

/// The capsule search field every playlist screen puts above its songs.
///
/// Not `.searchable`: these screens build their own header above the list, and
/// a navigation-bar search field collapses into the title on the compact widths
/// the app is mostly used at.
struct TrackFilterField: View {
    @Binding var text: String
    var prompt: LocalizedStringKey = "搜索歌单内歌曲"

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isFocused)
                .submitLabel(.search)
            #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            #endif

            if !text.isEmpty {
                Button {
                    text = ""
                    isFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.primary.opacity(0.05), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(.primary.opacity(isFocused ? 0.14 : 0.06), lineWidth: 0.5)
        }
    }
}
