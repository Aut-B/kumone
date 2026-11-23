import Foundation

/// Where a song's comments can be read from.
enum SongCommentSource: Equatable, Sendable {
    /// No comment thread this build can read.
    case unavailable
    /// NetEase Cloud Music's `R_SO_4_<id>` thread.
    case netease
    /// A Bilibili video's comment thread.
    case bilibili

    /// Only NetEase's thread can be liked for the signed-in listener.
    var supportsLikes: Bool { self == .netease }

    var isAvailable: Bool { self != .unavailable }
}

/// Decides which comment backend a track can use.
enum SongCommentAvailability {
    static func source(for track: Track) -> SongCommentSource {
        // Cloud uploads have no public thread, whatever their plugin says.
        guard !track.isCloud else { return .unavailable }
        guard let plugin = track.plugin else {
            return track.id > 0 ? .netease : .unavailable
        }
        guard isBilibili(plugin.platform),
              BilibiliComments.aid(for: track) != nil || BilibiliComments.bvid(for: track) != nil else {
            return .unavailable
        }
        return .bilibili
    }

    static func isAvailable(for track: Track) -> Bool {
        isAvailable(source(for: track))
    }

    static func isAvailable(_ source: SongCommentSource) -> Bool {
        source.isAvailable
    }

    /// Plugin platforms carry their mounted plugin's name, e.g. "bilibili",
    /// "哔哩哔哩 (官方)" or "B站".
    private static func isBilibili(_ platform: String) -> Bool {
        let name = platform.lowercased()
        return name.contains("bili") || name.contains("哔哩") || name.contains("b站")
    }
}
