import SwiftUI

// MARK: - Playlist list

/// The third playlist kind: a local list that mixes NetEase songs and plugin
/// songs in one place.
///
/// Kept deliberately separate from the two lists Kumone already had — songs
/// added here are never written into the NetEase account's playlists nor into
/// an imported MusicFree playlist.
struct MixedPlaylistsView: View {
    /// What the name alert is currently editing.
    private enum Editor: Identifiable {
        case create
        case rename(MixedPlaylist)

        var id: String {
            switch self {
            case .create: return "create"
            case .rename(let playlist): return "rename-\(playlist.id)"
            }
        }

        var title: String {
            switch self {
            case .create: return String(localized: "新建混装歌单")
            case .rename: return String(localized: "重命名歌单")
            }
        }
    }

    @ObservedObject private var store = MixedPlaylistStore.shared
    @State private var editor: Editor? = nil
    @State private var nameField = ""
    @State private var showWebDAVSync = false

    var body: some View {
        List {
            Section {
                if store.playlists.isEmpty {
                    EmptyStateView(
                        icon: "square.stack.3d.up",
                        title: "还没有混装歌单",
                        subtitle: "新建一个，把网易云的歌和插件音源的歌放进去连着听"
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(store.playlists) { playlist in
                        NavigationLink(value: Destination.mixedPlaylist(playlist.id)) {
                            HStack(spacing: 10) {
                                Image(systemName: "square.stack.3d.up.fill")
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 26)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(playlist.name)
                                        .font(.system(size: 15))
                                        .lineLimit(1)
                                    Text("\(playlist.itemCount) 首")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                store.remove(playlist)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            Button {
                                nameField = playlist.name
                                editor = .rename(playlist)
                            } label: {
                                Label("重命名", systemImage: "pencil")
                            }
                            .tint(Theme.accent)
                        }
                    }
                }
            } footer: {
                Text("混装歌单保存在本机，不会写进你的网易云歌单，也不会写进插件歌单。")
            }

            // The whole-list sync entry. It is deliberately its own row rather
            // than a toolbar icon: backing up the mixed playlists is the main
            // reason to have them, and a bare icon is easy to miss.
            Section {
                Button {
                    showWebDAVSync = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "icloud.and.arrow.up")
                            .foregroundStyle(Theme.accent)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("云同步（WebDAV）")
                                .font(.system(size: 15))
                                .foregroundStyle(.primary)
                            Text("备份 / 恢复整个歌单")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("备份到 WebDAV 后，在另一台手机登录同一帐号恢复即可，网易云的歌也会一起过去，不需要先把它们搬进插件歌单。")
            }

            Section {
                PlayerClearanceSpacer().listRowBackground(Color.clear)
            }
        }
        .navigationTitle("混装歌单")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    nameField = ""
                    editor = .create
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("新建混装歌单")
            }
        }
        .sheet(isPresented: $showWebDAVSync) {
            WebDAVImportView()
        }
        .alert(editorTitle, isPresented: editorBinding) {
            TextField("歌单名称", text: $nameField)
            Button("保存") { commitEditor() }
            Button("取消", role: .cancel) { editor = nil }
        }
    }

    private var editorTitle: String {
        editor?.title ?? String(localized: "新建混装歌单")
    }

    private var editorBinding: Binding<Bool> {
        Binding(
            get: { editor != nil },
            set: { if !$0 { editor = nil } }
        )
    }

    private func commitEditor() {
        let name = nameField.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = editor
        editor = nil
        guard !name.isEmpty, let current else { return }
        switch current {
        case .create:
            let playlist = MixedPlaylistStore.shared.createPlaylist(name: name)
            ToastCenter.shared.show(String(localized: "已创建「\(playlist.name)」"))
        case .rename(let playlist):
            store.rename(playlist, to: name)
        }
    }
}

// MARK: - Playlist detail

/// One mixed playlist. The queue built here is what makes the feature work:
/// `PlayerService` resolves each track on its own, so NetEase entries play
/// through the NetEase API (with lyrics and scrobbling) while plugin entries
/// play through the plugin engine — in a single, uninterrupted queue.
struct MixedPlaylistDetailView: View {
    let playlistID: Int

    @ObservedObject private var store = MixedPlaylistStore.shared
    @State private var tracks: [Track] = []
    /// Presents the "copy into a plugin playlist" flow.
    @State private var exportTarget: ExportTarget? = nil
    /// Presents the whole-list WebDAV backup / restore sheet.
    @State private var showWebDAVSync = false

    /// What the export flow is doing: either it needs a destination, or the
    /// copy already ran and the result is worth reporting.
    private enum ExportTarget: Identifiable {
        case pick(ImportableSnapshot)
        case report(ImportableSnapshot, ImportedPlaylist, imported: Int, skipped: Int)

        var id: String {
            switch self {
            case .pick(let snapshot): return "pick-\(snapshot.playlistID)"
            case .report(let snapshot, _, _, _): return "report-\(snapshot.playlistID)"
            }
        }
    }

    /// Everything the copy needs, captured up front so the sheet does not have
    /// to read the store while the playlist is being mutated. The id is
    /// carried so the copy targets the exact playlist even if two share a name.
    struct ImportableSnapshot: Identifiable {
        let playlistID: Int
        let playlistName: String
        let items: [PluginMusicItem]
        let total: Int

        var id: Int { playlistID }
        var skipped: Int { total - items.count }
    }

    private var playlist: MixedPlaylist? { store.playlist(id: playlistID) }

    /// `ForEach` needs an id unique across both worlds: a plugin item's
    /// `Track.id` is a hash and a NetEase song's is a real song id, so the two
    /// could in principle coincide. The identity key cannot.
    private struct PlaylistRow: Identifiable {
        let key: String
        let track: Track

        var id: String { key }
    }

    private var rows: [PlaylistRow] {
        tracks.map { PlaylistRow(key: MixedPlaylistStore.identity(of: $0), track: $0) }
    }

    var body: some View {
        Group {
            if let playlist {
                List {
                    if rows.isEmpty {
                        EmptyStateView(
                            icon: "music.note",
                            title: "这个歌单还是空的",
                            subtitle: "在歌曲的「更多」菜单里选「添加到混装歌单」"
                        )
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            TrackRow(
                                track: row.track,
                                index: index + 1,
                                playability: .playable,
                                sourceTag: sourceTag(for: row.track),
                                onRemoveLocal: { remove(at: index) },
                                onPlay: { play(from: index) }
                            )
                        }
                        .onMove { source, destination in
                            tracks.move(fromOffsets: source, toOffset: destination)
                            store.move(fromOffsets: source, toOffset: destination, in: playlist)
                        }
                        .onDelete { offsets in
                            for index in offsets.sorted(by: >) { remove(at: index) }
                        }
                    }

                    Section {
                        PlayerClearanceSpacer().listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .navigationTitle(playlist.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarLeading) {
                        Button {
                            play(from: 0)
                        } label: {
                            Image(systemName: "play.circle")
                        }
                        .disabled(rows.isEmpty)
                        .accessibilityLabel("播放全部")
                        EditButton()
                            .disabled(rows.isEmpty)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                showWebDAVSync = true
                            } label: {
                                Label("云同步（WebDAV）", systemImage: "icloud.and.arrow.up")
                            }
                            Button {
                                beginExport()
                            } label: {
                                Label("复制插件曲到插件歌单", systemImage: "square.and.arrow.down.on.square")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .disabled(rows.isEmpty)
                        .accessibilityLabel("更多")
                    }
                }
                .sheet(item: $exportTarget) { target in
                    switch target {
                    case .pick(let snapshot):
                        PluginPlaylistExportSheet(
                            snapshot: snapshot,
                            onFinish: { playlist, imported, skipped in
                                exportTarget = .report(snapshot, playlist, imported: imported, skipped: skipped)
                            },
                            onCancel: { exportTarget = nil }
                        )
                    case .report(_, let playlist, let imported, let skipped):
                        PluginPlaylistExportResultSheet(
                            playlistName: playlist.name,
                            imported: imported,
                            skipped: skipped,
                            onDone: { exportTarget = nil }
                        )
                    }
                }
                .onAppear { reload() }
            } else {
                EmptyStateView(icon: "questionmark.folder", title: "歌单不存在")
            }
        }
        // Kept off the List so the two sheets never share one presenter.
        .sheet(isPresented: $showWebDAVSync) {
            WebDAVImportView()
        }
    }

    private func reload() {
        guard let playlist else {
            tracks = []
            return
        }
        tracks = store.tracks(of: playlist)
    }

    private func play(from index: Int) {
        guard let playlist, tracks.indices.contains(index) else { return }
        PlayerService.shared.play(
            tracks: tracks,
            source: .mixedPlaylist,
            startAt: tracks[index],
            context: .localPlaylist(id: playlist.id, name: playlist.name)
        )
    }

    private func remove(at index: Int) {
        guard let playlist, tracks.indices.contains(index) else { return }
        store.removeTrack(at: index, from: playlist)
        reload()
    }

    /// Small chip telling the two kinds apart inside one list.
    private func sourceTag(for track: Track) -> String {
        guard let plugin = track.plugin else { return String(localized: "网易云") }
        return plugin.platform
    }

    /// Snapshots the playlist, then asks where the plugin items should go.
    ///
    /// Nothing is written until a destination is chosen — a NetEase-only list
    /// has nothing to copy and is refused before the sheet even opens.
    private func beginExport() {
        guard let playlist else { return }
        let items = store.pluginItems(of: playlist)
        guard !items.isEmpty else {
            ToastCenter.shared.show(String(localized: "这个歌单里没有插件音源的歌，无法导入插件歌单"))
            return
        }
        let snapshot = ImportableSnapshot(
            playlistID: playlist.id,
            playlistName: playlist.name,
            items: items,
            total: store.tracks(of: playlist).count
        )
        exportTarget = .pick(snapshot)
    }
}

// MARK: - Picker sheet

/// Picks (or creates) a mixed playlist and appends the given track.
/// Works for NetEase tracks and plugin tracks alike.
struct MixedPlaylistPickerSheet: View {
    let track: Track

    @ObservedObject private var store = MixedPlaylistStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if store.playlists.isEmpty {
                        Text("还没有混装歌单，先在下面新建一个")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.playlists) { playlist in
                            Button {
                                add(to: playlist)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "square.stack.3d.up")
                                        .foregroundStyle(Theme.accent)
                                        .frame(width: 26)
                                    Text(playlist.name)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Spacer()
                                    Text("\(playlist.itemCount)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("选择歌单")
                } footer: {
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    } else {
                        Text(sourceFooter)
                    }
                }

                Section {
                    TextField("歌单名称", text: $newName)
                    Button("新建并添加") { createAndAdd() }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("新建歌单")
                }
            }
            .navigationTitle("添加到混装歌单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private var sourceFooter: String {
        if let plugin = track.plugin {
            return String(localized: "将添加插件音源《\(track.name)》（\(plugin.platform)）")
        }
        return String(localized: "将添加网易云《\(track.name)》")
    }

    private func add(to playlist: MixedPlaylist) {
        do {
            try store.add(track, to: playlist)
            ToastCenter.shared.show(String(localized: "已添加到「\(playlist.name)」"))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createAndAdd() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        add(to: store.createPlaylist(name: name))
    }
}

// MARK: - Copy a mixed playlist into a plugin playlist

/// Picks the plugin playlist to receive a mixed playlist's plugin items.
///
/// Only plugin entries can cross over: a plugin playlist file has no way to
/// describe a NetEase song, so those are listed as "will be skipped" rather
/// than silently dropped.
private struct PluginPlaylistExportSheet: View {
    let snapshot: MixedPlaylistDetailView.ImportableSnapshot
    let onFinish: (ImportedPlaylist, Int, Int) -> Void
    let onCancel: () -> Void

    @ObservedObject private var store = ImportedPlaylistStore.shared
    @State private var newName = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if store.playlists.isEmpty {
                        Text("还没有插件歌单，先在下面新建一个")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.playlists) { playlist in
                            Button {
                                run(exportingTo: playlist)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "music.note.list")
                                        .foregroundStyle(Theme.accent)
                                        .frame(width: 26)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(playlist.name)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text("\(playlist.itemCount) 首 · \(playlist.source)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                            }
                        }
                    }
                } header: {
                    Text("选择插件歌单")
                } footer: {
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    } else {
                        Text(summaryFooter)
                    }
                }

                Section {
                    TextField("歌单名称", text: $newName)
                    Button("新建并导入") { createAndRun() }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("新建插件歌单")
                }
            }
            .navigationTitle("导入到插件歌单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { onCancel() }
                }
            }
        }
    }

    private var summaryFooter: String {
        let base = String(localized: "将把「\(snapshot.playlistName)」里的 \(snapshot.items.count) 首插件音源歌曲复制进插件歌单。")
        guard snapshot.skipped > 0 else { return base }
        return base + String(
            localized: "另有 \(snapshot.skipped) 首网易云的歌，插件歌单存不下，会被跳过。这只是把插件曲复制一份，不能用来同步——要同步整个歌单请退出这里，用混装歌单页的「云同步（WebDAV）」。"
        )
    }

    private func run(exportingTo playlist: ImportedPlaylist) {
        guard let source = MixedPlaylistStore.shared.playlist(id: snapshot.playlistID) else {
            errorMessage = String(localized: "歌单不存在")
            return
        }
        do {
            let result = try MixedPlaylistStore.shared.exportPluginItems(from: source, to: playlist)
            onFinish(playlist, result.imported, result.skipped)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createAndRun() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            let playlist = try store.createPlaylist(name: name)
            run(exportingTo: playlist)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Reports what the copy actually did.
private struct PluginPlaylistExportResultSheet: View {
    let playlistName: String
    let imported: Int
    let skipped: Int
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("已导入", value: "\(imported) 首")
                    if skipped > 0 {
                        LabeledContent("已跳过", value: "\(skipped) 首")
                    }
                } footer: {
                    if skipped > 0 {
                        Text("跳过的 \(skipped) 首是网易云歌曲，插件歌单存不下它们——它们仍完整保留在混装歌单里。")
                    } else {
                        Text("这个歌单会随插件歌单的 WebDAV 备份一起同步。")
                    }
                }
            }
            .navigationTitle("导入完成")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { onDone() }
                }
            }
        }
    }
}
