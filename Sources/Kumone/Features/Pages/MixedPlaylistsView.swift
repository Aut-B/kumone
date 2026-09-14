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
                }
                .onAppear { reload() }
            } else {
                EmptyStateView(icon: "questionmark.folder", title: "歌单不存在")
            }
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
