import SwiftUI

/// Picks a target source for one or more playlist entries.
///
/// Matching happens in `SourceSwitchService`; this view only gathers the
/// target, runs the requests one at a time, writes every match back in one
/// batch, and reports what stayed behind. Entries that cannot be matched keep
/// their previous value and position.
struct SourceSwitchTargetSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var pluginManager = PluginManager.shared

    let entries: [LocalTrackEntry]
    private let playlist: ImportedPlaylist?
    let onFinished: () -> Void

    @State private var isSwitching = false
    @State private var switchingTargetID: String?
    @State private var progressDone = 0
    @State private var progressTotal = 0
    @State private var report: [SourceSwitchOutcome] = []

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

    private var isBatch: Bool { entries.count > 1 }

    /// Smart comes first and never disappears; a playlist with no enabled
    /// plugins still gets a (failing) report instead of an unreachable sheet.
    private var targets: [SourceSwitchTarget] {
        var result: [SourceSwitchTarget] = [.smart]
        for plugin in pluginManager.plugins where plugin.enabled {
            let sameForAll = entries.allSatisfy {
                SourceSwitchService.isSameSource(platform: plugin.platform, entry: $0)
            }
            if !sameForAll {
                result.append(.plugin(plugin.platform))
            }
        }
        return result
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
                if !report.isEmpty {
                    reportList
                } else if isSwitching, isBatch {
                    progressView
                } else {
                    targetList
                }
            }
            .navigationTitle(report.isEmpty ? "换源" : "换源结果")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if report.isEmpty {
                        Button("取消") { dismiss() }
                            .disabled(isSwitching)
                    } else {
                        Button("完成") { dismiss() }
                    }
                }
            }
        }
    }

    private var targetList: some View {
        List {
            Section {
                ForEach(targets) { target in
                    targetRow(target)
                }
            } footer: {
                Text(
                    isBatch
                        ? "逐首换源，成功后一次性写回；未找到的条目保持原样。"
                        : "只替换匹配到的这一条，歌单顺序和其他歌曲都不变。"
                )
            }
        }
    }

    private var progressView: some View {
        VStack(spacing: 14) {
            ProgressView(
                value: Double(progressDone),
                total: Double(max(progressTotal, 1))
            )
            .progressViewStyle(.linear)
            .frame(maxWidth: 280)
            Text("正在换源… \(progressDone)/\(progressTotal)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            Text("逐首搜索，请保持页面开启")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var successes: [SourceSwitchOutcome] {
        report.filter(\.isSuccess)
    }

    private var notFound: [SourceSwitchOutcome] {
        report.filter { $0.error == .notFound }
    }

    private var otherFailures: [SourceSwitchOutcome] {
        report.filter { !$0.isSuccess && $0.error != .notFound }
    }

    private var reportList: some View {
        List {
            Section {
                Text("成功 \(successes.count) / 未找到 \(notFound.count)")
                    .font(.headline)
            }

            if !notFound.isEmpty {
                Section("未找到") {
                    ForEach(notFound, id: \.sourceID) { outcome in
                        reportRow(outcome, showsReason: false)
                    }
                }
            }

            if !otherFailures.isEmpty {
                Section("其他未替换") {
                    ForEach(otherFailures, id: \.sourceID) { outcome in
                        reportRow(outcome, showsReason: true)
                    }
                }
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
                    Text(target.isSmart ? "自动尝试所有已启用的插件音源" : "插件音源")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isSwitching, switchingTargetID == target.id {
                    ProgressView()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSwitching)
    }

    private func reportRow(_ outcome: SourceSwitchOutcome, showsReason: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(outcome.sourceTitle)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(outcome.sourceArtist)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if showsReason, let error = outcome.error {
                Text(error.localizedDescription)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func performSwitch(_ target: SourceSwitchTarget) {
        guard !isSwitching else { return }
        guard let destination = destinationPlaylist else {
            ToastCenter.shared.show(String(localized: "找不到这条歌曲所在的歌单，未做改动"))
            dismiss()
            return
        }

        let snapshot = entries
        isSwitching = true
        switchingTargetID = target.id
        progressDone = 0
        progressTotal = snapshot.count
        report = []

        Task { @MainActor in
            let outcomes: [SourceSwitchOutcome]
            if target.isSmart {
                outcomes = await switchSmart(snapshot)
            } else if let platform = target.platform {
                outcomes = await SourceSwitchService.shared.switchEntries(
                    snapshot,
                    to: platform
                ) { done, total in
                    progressDone = done
                    progressTotal = total
                }
            } else {
                outcomes = []
            }

            isSwitching = false
            switchingTargetID = nil

            var replacements: [String: LocalTrackEntry] = [:]
            for outcome in outcomes {
                if outcome.isSuccess, let replacement = outcome.replacement {
                    replacements[outcome.sourceID] = replacement
                }
            }
            if !replacements.isEmpty {
                _ = ImportedPlaylistStore.shared.replaceEntries(replacements, in: destination)
                onFinished()
            }

            if snapshot.count > 1 || target.isSmart {
                report = outcomes
            } else if let failure = outcomes.first(where: { !$0.isSuccess })?.error {
                showFailure(failure)
                dismiss()
            } else {
                dismiss()
            }
        }
    }

    private func switchSmart(_ snapshot: [LocalTrackEntry]) async -> [SourceSwitchOutcome] {
        var outcomes: [SourceSwitchOutcome] = []
        outcomes.reserveCapacity(snapshot.count)
        for (index, entry) in snapshot.enumerated() {
            outcomes.append(await SourceSwitchService.shared.switchEntrySmart(entry))
            progressDone = index + 1
            progressTotal = snapshot.count
        }
        return outcomes
    }

    private func showFailure(_ error: SourceSwitchError) {
        if error != .notFound {
            ToastCenter.shared.show(error.localizedDescription)
        } else {
            ToastCenter.shared.show(String(localized: "未找到可替换条目，已保留原样"))
        }
    }
}
