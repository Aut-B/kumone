import Foundation

/// A destination for a source switch.
///
/// This batch exposes installed plugins only; later batches add the smart
/// probe and NetEase targets without changing how callers name a target.
enum SourceSwitchTarget: Identifiable, Hashable {
    case plugin(String)

    var platform: String {
        switch self {
        case .plugin(let platform): return platform
        }
    }

    var id: String { "plugin:\(platform)" }

    /// The plugin's display name, falling back to its routing key.
    @MainActor
    var title: String {
        PluginManager.shared.plugins
            .first(where: { $0.platform == platform })?
            .name ?? platform
    }
}

/// Why a source switch did not produce a replacement.
enum SourceSwitchError: Error, Equatable, LocalizedError {
    case notFound
    case samePlatform
    case sourceUnavailable(String)
    case searchFailed(String)

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
