import SwiftUI

/// Picks a target plugin for one or more playlist entries.
///
/// Matching happens in `SourceSwitchService`; this view only gathers the
/// target, writes the matched entries back in one batch, and reports the
/// result. Entries that cannot be matched stay exactly as they were.
struct SourceSwitchTargetSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var pluginManager = PluginManager.shared

    let entries: [LocalTrackEntry]
    private let playlist: ImportedPlaylist?
    let onFinished: () -> Void

    @State private var isSwitching = false
    @State private var switchingPlatform: String?

    init(entries: [LocalTrackEntry], onFinished: @escaping () -> Void) {
        self.init(entries: entries, playlist: nil, onFinished: onFinished)
    }

    init(
        entries: [LocalTrackEntry],
        playlist: ImportedPlaylist?,
        onFinished: @escaping () -> Void
    ) {
        self.entries = entries
        self.playlist = playlist
        self.onFinished = onFinished
    }

    private var targets: [SourceSwitchTarget] {
        pluginManager.plugins
            .filter(\.enabled)
            .filter { plugin in
                !entries.allSatisfy {
                    SourceSwitchService.isSameSource(platform: plugin.platform, entry: $0)
                }
            }
            .map { .plugin($0.platform) }
    }

    /// The detail view passes its playlist directly. For callers that only
    /// have entries, find the playlist holding the first entry as a fallback.
    private var destinationPlaylist: ImportedPlaylist? {
        if let playlist { return playlist }
        guard let firstID = entries.first?.id else { return nil }
        return ImportedPlaylistStore.shared.playlists.first { candidate in
            ImportedPlaylistStore.shared.loadEntries(of: candidate).contains { $0.id == firstID }
        }
    }

    var body: some View {
        AppNavStack {
            Group {
                if targets.isEmpty {
                    EmptyStateView(
                        icon: "arrow.triangle.2.circlepath",
                        title: "没有可用的换源目标",
                        subtitle: "先安装并启用其他插件音源，或这首歌曲已经来自当前所有可用音源。"
                    )
                } else {
                    List {
                        Section {
                            ForEach(targets) { target in
                                targetRow(target)
                            }
                        } footer: {
                            Text("只替换匹配到的这一条，歌单顺序和其他歌曲都不变。")
                        }
                    }
                }
            }
            .navigationTitle("换源")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if !targets.isEmpty {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                            .disabled(isSwitching)
                    }
                }
                #if os(macOS)
                if targets.isEmpty {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }
                    }
                }
                #endif
            }
        }
    }

    private func targetRow(_ target: SourceSwitchTarget) -> some View {
        Button {
            performSwitch(target)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.body)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.title)
                        .foregroundStyle(.primary)
                    Text("插件音源")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isSwitching, switchingPlatform == target.platform {
                    ProgressView()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSwitching)
    }

    private func performSwitch(_ target: SourceSwitchTarget) {
        guard !isSwitching else { return }
        guard let destination = destinationPlaylist else {
            ToastCenter.shared.show(String(localized: "找不到这条歌曲所在的歌单，未做改动"))
            dismiss()
            return
        }

        isSwitching = true
        switchingPlatform = target.platform
        Task { @MainActor in
            var replacements: [String: LocalTrackEntry] = [:]
            var failure: SourceSwitchError?

            for entry in entries {
                let outcome = await SourceSwitchService.shared.switchEntry(
                    entry,
                    to: target.platform
                )
                if outcome.isSuccess, let replacement = outcome.replacement {
                    replacements[entry.id] = replacement
                } else if let error = outcome.error {
                    failure = error
                }
            }

            isSwitching = false
            switchingPlatform = nil

            guard !replacements.isEmpty else {
                showFailure(failure)
                dismiss()
                return
            }

            let result = ImportedPlaylistStore.shared.replaceEntries(
                replacements,
                in: destination
            )
            if result.replacedCount > 0 {
                onFinished()
            } else {
                ToastCenter.shared.show(String(localized: "未找到可替换条目，已保留原样"))
            }
            dismiss()
        }
    }

    private func showFailure(_ error: SourceSwitchError?) {
        if let error, error != .notFound {
            ToastCenter.shared.show(error.localizedDescription)
        } else {
            ToastCenter.shared.show(String(localized: "未找到可替换条目，已保留原样"))
        }
    }
}
