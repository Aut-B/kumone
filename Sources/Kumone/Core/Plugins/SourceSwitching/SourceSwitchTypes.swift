import Foundation

/// A destination for a source switch.
///
/// Smart probes every enabled plugin in registration order and takes the first
/// one whose `getMediaSource` returns a URL; the plugin case names one
/// destination explicitly. NetEase is searched through `MusicAPI` directly so
/// the target list never duplicates an installed NetEase plugin row.
enum SourceSwitchTarget: Identifiable, Hashable {
    case smart
    case netease
    case plugin(String)

    var isSmart: Bool {
        if case .smart = self { return true }
        return false
    }

    /// Routing key of a plugin target; nil for the targets that do not route
    /// through `PluginManager`.
    var platform: String? {
        switch self {
        case .smart: return nil
        case .netease: return nil
        case .plugin(let platform): return platform
        }
    }

    var id: String {
        switch self {
        case .smart: return "smart"
        case .netease: return "netease"
        case .plugin(let platform): return "plugin:\(platform)"
        }
    }

    /// The plugin's display name, falling back to its routing key.
    @MainActor
    var title: String {
        switch self {
        case .smart:
            return String(localized: "智能换源")
        case .netease:
            return String(localized: "网易云")
        case .plugin(let platform):
            return PluginManager.shared.plugins
                .first(where: { $0.platform == platform })?.name ?? platform
        }
    }
}

/// Why a source switch did not produce a replacement.
enum SourceSwitchError: Error, Equatable, LocalizedError {
    case notFound
    case samePlatform
    case sourceUnavailable(String)
    case searchFailed(String)
    case allSourcesFailed(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return String(localized: "未找到可替换条目")
        case .samePlatform:
            return String(localized: "目标平台与当前来源相同")
        case .sourceUnavailable(let name):
            return String(localized: "「\(name)」暂时不可用")
        case .searchFailed(let message):
            return String(localized: "搜索失败：\(message)")
        case .allSourcesFailed(let details):
            return details
        }
    }
}

/// Result of matching one playlist entry against one target source.
struct SourceSwitchOutcome: Equatable {
    let sourceID: String
    let sourceTitle: String
    let sourceArtist: String
    let targetName: String
    let replacementID: String?
    let error: SourceSwitchError?
    /// The matched item in storable form; present only on success.
    let replacement: LocalTrackEntry?

    var isSuccess: Bool { replacementID != nil && error == nil }

    init(
        sourceID: String,
        sourceTitle: String,
        sourceArtist: String,
        targetName: String,
        replacementID: String?,
        error: SourceSwitchError?,
        replacement: LocalTrackEntry? = nil
    ) {
        self.sourceID = sourceID
        self.sourceTitle = sourceTitle
        self.sourceArtist = sourceArtist
        self.targetName = targetName
        self.replacementID = replacementID
        self.error = error
        self.replacement = replacement
    }
}
