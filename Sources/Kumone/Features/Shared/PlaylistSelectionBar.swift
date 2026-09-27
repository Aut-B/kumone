import SwiftUI

// MARK: - Selection chrome

/// "已选择 N 项" + 全选 / 取消全选.
struct PlaylistSelectionSummaryBar: View {
    let selectedCount: Int
    let totalCount: Int
    let onToggleAll: () -> Void

    private var allSelected: Bool { totalCount > 0 && selectedCount == totalCount }

    var body: some View {
        HStack(spacing: 10) {
            Text("已选择 \(selectedCount) 项")
                .font(.subheadline.weight(.medium))
            Spacer()
            Button {
                onToggleAll()
            } label: {
                Text(allSelected ? "取消全选" : "全选")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(.primary.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(totalCount == 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// The batch action bar: 下一首播放 / 添加到歌单 / 删除.
///
/// There is deliberately no download button — this app has no download
/// library, only a playback cache.
struct PlaylistSelectionActionBar: View {
    let selectedCount: Int
    var canDelete = true
    let onPlayNext: () -> Void
    let onCollect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            actionButton(
                icon: "text.line.first.and.arrowtriangle.forward",
                label: "下一首播放",
                tint: .primary,
                action: onPlayNext
            )
            actionButton(
                icon: "folder.badge.plus",
                label: "添加到歌单",
                tint: .primary,
                action: onCollect
            )
            if canDelete {
                actionButton(
                    icon: "trash",
                    label: "删除",
                    tint: .red,
                    action: onDelete
                )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func actionButton(icon: String, label: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                Text(label)
                    .font(.caption2)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(selectedCount == 0)
        .opacity(selectedCount == 0 ? 0.45 : 1)
    }
}

/// The round checkbox drawn in front of a row while selecting.
struct SelectionCheckmark: View {
    let isSelected: Bool

    var body: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(isSelected ? Theme.accent : Color.secondary.opacity(0.55))
            .frame(width: 26)
    }
}

// MARK: - Batch collect

/// Collects several tracks at once into a cloud or a local playlist.
///
/// Plugin tracks have no NetEase id, so cloud targets only receive the
/// NetEase ones; local playlists take both.
struct AddTracksToPlaylistSheet: View {
    let tracks: [Track]

    @EnvironmentObject private var account: AccountStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var layout = PlaylistLayoutStore.shared
    @State private var newName = ""
    @State private var working = false
    @State private var errorMessage: String?

    private var neteaseIDs: [Int] {
        tracks.filter { $0.plugin == nil }.map(\.id)
    }

    private var localEntries: [LocalTrackEntry] {
        tracks.compactMap { LocalTrackEntry(track: $0) }
    }

    var body: some View {
        AppNavStack {
            List {
                if account.createdPlaylists.isEmpty && ImportedPlaylistStore.shared.playlists.isEmpty {
                    Text("还没有可用的歌单，先在下面新建一个")
                        .foregroundStyle(.secondary)
                }

                if !account.createdPlaylists.isEmpty {
                    Section {
                        ForEach(layout.orderedCloud(account.createdPlaylists)) { playlist in
                            Button {
                                addToCloud(playlist)
                            } label: {
                                playlistRow(
                                    title: playlist.name,
                                    subtitle: neteaseIDs.isEmpty
                                        ? "插件音源的歌加不进网易云歌单"
                                        : "\(neteaseIDs.count) 首",
                                    systemImage: "music.note.list"
                                )
                            }
                            .disabled(neteaseIDs.isEmpty || working)
                        }
                    } header: {
                        Text("网易云歌单")
                    }
                }

                if !ImportedPlaylistStore.shared.playlists.isEmpty {
                    Section {
                        ForEach(layout.orderedLocal(ImportedPlaylistStore.shared.playlists)) { playlist in
                            Button {
                                addToLocal(playlist)
                            } label: {
                                playlistRow(
                                    title: playlist.name,
                                    subtitle: "\(localEntries.count) 首",
                                    systemImage: "square.stack.3d.up.fill"
                                )
                            }
                            .disabled(working)
                        }
                    } header: {
                        Text("本地歌单")
                    }
                }

                Section {
                    TextField("新建本地歌单", text: $newName)
                    Button {
                        createLocalAndAdd()
                    } label: {
                        Text("创建本地歌单并添加")
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || working)
                } header: {
                    Text("新建")
                } footer: {
                    Text("本地歌单两种音源的歌都能放；网易云歌单只收得下网易云自己的歌。")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("添加到歌单")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func playlistRow(title: String, subtitle: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(Theme.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func addToCloud(_ playlist: PlaylistSummary) {
        guard !neteaseIDs.isEmpty else { return }
        working = true
        Task {
            defer { working = false }
            do {
                try await NeteaseAPI.playlistTracks(op: "add", playlistID: playlist.id, trackIDs: neteaseIDs)
                ToastCenter.shared.show(String(localized: "已添加 \(neteaseIDs.count) 首到「\(playlist.name)」"))
                await account.refreshLibrary()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func addToLocal(_ playlist: ImportedPlaylist) {
        working = true
        let entries = localEntries
        let count = ImportedPlaylistStore.shared.addEntries(entries, to: playlist)
        working = false
        if count == 0 {
            ToastCenter.shared.show(String(localized: "这些歌已经在「\(playlist.name)」里了"))
        } else {
            ToastCenter.shared.show(String(localized: "已添加 \(count) 首到「\(playlist.name)」，放在最前面"))
        }
        dismiss()
    }

    private func createLocalAndAdd() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            let playlist = try ImportedPlaylistStore.shared.createPlaylist(name: name)
            addToLocal(playlist)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Playlist ordering

/// Drag-to-reorder sheet for cloud (NetEase) playlists.
///
/// Only the local display order changes — NetEase keeps its own order on the
/// server and offers no write API for it.
struct CloudPlaylistOrderSheet: View {
    let playlists: [PlaylistSummary]

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var layout = PlaylistLayoutStore.shared
    @State private var working: [PlaylistSummary] = []

    var body: some View {
        AppNavStack {
            List {
                ForEach(working) { playlist in
                    HStack(spacing: 10) {
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.secondary)
                        Text(playlist.name)
                        Spacer()
                        if layout.isPinned(cloud: playlist.id) {
                            Image(systemName: "pin.fill")
                                .font(.caption)
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
                .onMove { offsets, destination in
                    working.move(fromOffsets: offsets, toOffset: destination)
                }
            }
            .listStyle(.plain)
            .environment(\.editMode, .constant(.active))
            .navigationTitle("调整歌单顺序")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        layout.setCloudOrder(working)
                        dismiss()
                    }
                }
            }
            .onAppear { working = layout.orderedCloud(playlists) }
        }
    }
}
