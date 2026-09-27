import SwiftUI

// MARK: - Search model

@MainActor
final class PluginsSearchModel: ObservableObject {
    @Published var selectedPlatform: String?
    @Published var items: [PluginMusicItem] = []
    @Published var isSearching = false
    @Published var errorMessage: String?
    @Published private(set) var hasMore = false

    private var page = 1
    private var activeQuery = ""

    func selectFirst() {
        guard selectedPlatform == nil else { return }
        selectedPlatform = PluginManager.shared.plugins.first(where: { $0.enabled })?.platform
            ?? PluginManager.shared.plugins.first?.platform
    }

    func search(query: String) async {
        guard !query.isEmpty, let platform = selectedPlatform else { return }
        activeQuery = query
        page = 1
        isSearching = true
        errorMessage = nil
        defer { isSearching = false }
        // Bilibili BV ids resolve exactly (native view API) so the result can
        // never be a wrong video matched by keyword search.
        if let bvItem = await PluginManager.shared.resolveBilibiliBV(query, platform: platform) {
            items = [bvItem]
            hasMore = false
            return
        }
        do {
            let result = try await PluginManager.shared.search(platform: platform, query: query, page: 1)
            items = result.items
            hasMore = !result.isEnd
        } catch {
            items = []
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard hasMore, !isSearching, !activeQuery.isEmpty, let platform = selectedPlatform else { return }
        page += 1
        isSearching = true
        defer { isSearching = false }
        do {
            let result = try await PluginManager.shared.search(platform: platform, query: activeQuery, page: page)
            items.append(contentsOf: result.items)
            hasMore = !result.isEnd
        } catch {
            hasMore = false
        }
    }

    func play(at index: Int) {
        guard items.indices.contains(index), let platform = selectedPlatform else { return }
        let queue = items.map { Track(pluginItem: $0) }
        PlayerService.shared.play(
            tracks: queue,
            source: .plugins,
            startAt: queue[index],
            context: .plugins(name: platform)
        )
    }
}

// MARK: - Root tab

struct PluginsRootView: View {
    @StateObject private var model = PluginsSearchModel()
    @ObservedObject private var store = ImportedPlaylistStore.shared
    @ObservedObject private var layout = PlaylistLayoutStore.shared
    @Environment(\.openDestination) private var openDestination
    @State private var query = ""
    @State private var showManager = false
    @State private var showWebDAV = false
    @State private var showNewPlaylist = false
    @State private var showReorder = false
    @State private var newPlaylistName = ""

    /// Pinned first, then in the user's own order.
    private var orderedPlaylists: [ImportedPlaylist] { layout.orderedLocal(store.playlists) }

    var body: some View {
        content
            .navigationTitle("插件音源")
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text("在插件音源中搜索")
            )
            .onSubmit(of: .search) {
                Task { await model.search(query: query) }
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showWebDAV = true
                    } label: {
                        Image(systemName: "tray.and.arrow.down")
                    }
                    .accessibilityLabel("从 WebDAV 导入歌单")
                    Menu {
                        Button {
                            showNewPlaylist = true
                        } label: {
                            Label("新建本地歌单", systemImage: "plus")
                        }
                        Button {
                            showReorder = true
                        } label: {
                            Label("调整歌单顺序", systemImage: "arrow.up.arrow.down")
                        }
                        .disabled(orderedPlaylists.count < 2)
                        Button {
                            showManager = true
                        } label: {
                            Label("插件管理", systemImage: "puzzlepiece.extension")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("更多")
                }
            }
            .sheet(isPresented: $showManager) {
                PluginManagerView()
            }
            .sheet(isPresented: $showWebDAV) {
                WebDAVImportView()
            }
            .sheet(isPresented: $showReorder) {
                LocalPlaylistOrderSheet()
            }
            .alert("新建本地歌单", isPresented: $showNewPlaylist) {
                TextField("歌单名称", text: $newPlaylistName)
                Button("创建") {
                    let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
                    newPlaylistName = ""
                    guard !name.isEmpty else { return }
                    do {
                        _ = try ImportedPlaylistStore.shared.createPlaylist(name: name)
                        ToastCenter.shared.show(String(localized: "歌单已创建"))
                    } catch {
                        ToastCenter.shared.show(error.localizedDescription)
                    }
                }
                Button("取消", role: .cancel) { newPlaylistName = "" }
            }
            .onAppear {
                model.selectFirst()
                if model.items.isEmpty, !query.isEmpty {
                    Task { await model.search(query: query) }
                }
            }
    }

    /// Everything on one page: the playlists and the search results, so
    /// neither needs a segmented switch to reach.
    @ViewBuilder
    private var content: some View {
        if PluginManager.shared.plugins.isEmpty {
            EmptyStateView(
                icon: "puzzlepiece.extension",
                title: "还没有安装插件音源",
                subtitle: "点击右上角菜单里的「插件管理」安装音源，兼容 MusicFree 插件生态"
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    pluginPicker
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        playlistSection
                        searchHint
                    } else {
                        searchResults
                        playlistSection
                    }
                }
                .padding(.bottom, 24)
            }
        }
    }

    @ViewBuilder
    private var searchHint: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text("在顶部搜索框输入关键词，结果会直接显示在这里")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }

    private var pluginPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(PluginManager.shared.plugins, id: \.platform) { plugin in
                    pluginChip(plugin)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    private func pluginChip(_ plugin: PluginManager.InstalledPlugin) -> some View {
        let isSelected = model.selectedPlatform == plugin.platform
        return Button {
            model.selectedPlatform = plugin.platform
            model.items = []
            if !query.isEmpty {
                Task { await model.search(query: query) }
            }
        } label: {
            Text(plugin.name)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(isSelected ? Theme.accent.opacity(0.16) : Color.secondary.opacity(0.08)))
                .foregroundStyle(isSelected ? Theme.accent : Color.primary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var searchResults: some View {
        if model.isSearching && model.items.isEmpty {
            HStack { Spacer(); ProgressView(); Spacer() }
                .padding(.vertical, 24)
        } else if let error = model.errorMessage, model.items.isEmpty {
            EmptyStateView(icon: "wifi.exclamationmark", title: "搜索失败", subtitle: LocalizedStringKey(error))
        } else if model.items.isEmpty {
            EmptyStateView(icon: "magnifyingglass", title: "没有找到结果", subtitle: "换个关键词，或换一个音源再试")
        } else {
            LazyVStack(spacing: 0) {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                    PluginTrackRow(item: item, onTap: { model.play(at: index) })
                }
                if model.hasMore {
                    ProgressView()
                        .padding()
                        .task { await model.loadMore() }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    /// Local playlists, pinned first, opened by pushing onto the tab's stack
    /// (they used to be a sheet behind a segmented switch).
    private var playlistSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("我的歌单")
                .font(.headline)
                .padding(.horizontal, 16)

            if orderedPlaylists.isEmpty {
                VStack(spacing: 6) {
                    Text("还没有本地歌单")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("右上角菜单可以新建，也能从 WebDAV 导入 Beans 或 MusicFree 的备份")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            } else {
                ForEach(orderedPlaylists) { playlist in
                    DestinationLink(value: Destination.localPlaylist(playlist)) {
                        HStack(spacing: 10) {
                            Image(systemName: "music.note.list")
                                .foregroundStyle(Theme.accent)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.name)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text("\(playlist.itemCount) 首 · \(playlist.source)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if layout.isPinned(local: playlist.id) {
                                Image(systemName: "pin.fill")
                                    .font(.caption)
                                    .foregroundStyle(Theme.accent)
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            layout.togglePin(local: playlist.id)
                        } label: {
                            Label(layout.isPinned(local: playlist.id) ? "取消置顶" : "置顶",
                                  systemImage: layout.isPinned(local: playlist.id) ? "pin.slash" : "pin")
                        }
                        Button(role: .destructive) {
                            ImportedPlaylistStore.shared.remove(playlist)
                        } label: {
                            Label("删除歌单", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }
}

/// Detail view for a local playlist: play from one, select in bulk, reorder.
///
/// A local playlist holds both kinds of entry — plugin items and NetEase
/// references — so a Beans backup lands here intact.
struct ImportedPlaylistDetailView: View {
    @EnvironmentObject private var player: PlayerService
    let playlist: ImportedPlaylist

    @State private var entries: [LocalTrackEntry] = []
    @State private var filter = ""
    @State private var multiSelectMode = false
    @State private var selectedIDs: Set<String> = []
    @State private var editMode: EditMode = .inactive
    @State private var showCollect = false
    @State private var showDeleteConfirm = false

    private var isReordering: Bool { editMode == .active }

    private var visibleEntries: [LocalTrackEntry] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return entries }
        return entries.filter {
            $0.title.lowercased().contains(query)
                || $0.artist.lowercased().contains(query)
                || $0.album.lowercased().contains(query)
        }
    }

    /// Dragging only makes sense for the unfiltered list: a moved row would
    /// otherwise be re-indexed against a list the user cannot see.
    private var canReorder: Bool {
        visibleEntries.count > 1 && filter.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var selectedTracks: [Track] {
        entries.filter { selectedIDs.contains($0.id) }.map(\.track)
    }

    var body: some View {
        VStack(spacing: 0) {
            if multiSelectMode {
                // Top, not bottom: the floating mini player would cover it.
                PlaylistSelectionSummaryBar(
                    selectedCount: selectedIDs.count,
                    totalCount: visibleEntries.count,
                    onToggleAll: toggleSelectAll
                )
                Divider().opacity(0.4)
                PlaylistSelectionActionBar(
                    selectedCount: selectedIDs.count,
                    canDelete: true,
                    onPlayNext: playSelectedNext,
                    onCollect: { showCollect = true },
                    onDelete: { showDeleteConfirm = true }
                )
                Divider().opacity(0.4)
            }

            List {
                ForEach(visibleEntries) { entry in
                    row(for: entry)
                }
                .onMove(perform: canReorder ? moveEntries : nil)
                .onDelete(perform: multiSelectMode ? nil : deleteEntries)
            }
            .listStyle(.plain)
            .environment(\.editMode, $editMode)
        }
        .navigationTitle(playlist.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .searchable(
            text: $filter,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: Text("搜索歌单内歌曲")
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    toggleMultiSelect()
                } label: {
                    Image(systemName: multiSelectMode ? "xmark.circle" : "checklist")
                        .font(.system(size: 16, weight: .semibold))
                }
                .accessibilityLabel(multiSelectMode ? "退出多选" : "多选")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        toggleMultiSelect()
                    } label: {
                        Label(multiSelectMode ? "退出多选" : "多选", systemImage: "checklist")
                    }
                    Button {
                        editMode = isReordering ? .inactive : .active
                        if isReordering {
                            multiSelectMode = false
                            selectedIDs.removeAll()
                        }
                    } label: {
                        Label(isReordering ? "完成排序" : "调整歌曲顺序",
                              systemImage: isReordering ? "checkmark" : "arrow.up.arrow.down")
                    }
                    .disabled(!isReordering && !canReorder)
                    Button {
                        playAll()
                    } label: {
                        Label("播放全部", systemImage: "play")
                    }
                    .disabled(entries.isEmpty)
                    Button {
                        addCurrent()
                    } label: {
                        Label("把正在播放的歌曲加进来", systemImage: "plus.circle")
                    }
                    .disabled(player.currentTrack == nil)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("更多")
            }
        }
        .sheet(isPresented: $showCollect) {
            AddTracksToPlaylistSheet(tracks: selectedTracks)
        }
        .confirmationDialog(
            "从歌单移除 \(selectedIDs.count) 首？",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("移除", role: .destructive) {
                ImportedPlaylistStore.shared.removeEntries(withIDs: selectedIDs, from: playlist)
                selectedIDs.removeAll()
                multiSelectMode = false
                reload()
            }
            Button("取消", role: .cancel) {}
        }
        .onAppear(perform: reload)
    }

    // MARK: - Rows

    /// Tapping the row plays it; in select mode it toggles the checkbox
    /// instead. `.foregroundStyle(.primary)` is explicit because a tint would
    /// otherwise paint every title in the accent (red) colour.
    private func row(for entry: LocalTrackEntry) -> some View {
        HStack(spacing: 10) {
            if multiSelectMode {
                SelectionCheckmark(isSelected: selectedIDs.contains(entry.id))
            }
            CachedAsyncImage(url: entry.artwork.flatMap(URL.init(string:))) {
                Rectangle().fill(Color.secondary.opacity(0.12))
            }
            .frame(width: 42, height: 42)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(entry.artist) · \(entry.platform)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if entry.durationMS > 0 {
                Text(CompatDuration.mmss(entry.durationMS))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if multiSelectMode {
                toggle(entry)
            } else if !isReordering {
                play(entry)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !multiSelectMode && !isReordering {
                Button(role: .destructive) {
                    ImportedPlaylistStore.shared.removeEntries(withIDs: [entry.id], from: playlist)
                    reload()
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Actions

    private func reload() {
        entries = ImportedPlaylistStore.shared.loadEntries(of: playlist)
    }

    private func toggle(_ entry: LocalTrackEntry) {
        if selectedIDs.contains(entry.id) {
            selectedIDs.remove(entry.id)
        } else {
            selectedIDs.insert(entry.id)
        }
    }

    private func toggleSelectAll() {
        let keys = Set(visibleEntries.map(\.id))
        if selectedIDs.count == keys.count && !keys.isEmpty {
            selectedIDs.removeAll()
        } else {
            selectedIDs = keys
        }
    }

    private func toggleMultiSelect() {
        multiSelectMode.toggle()
        selectedIDs.removeAll()
        if multiSelectMode { editMode = .inactive }
    }

    private func play(_ entry: LocalTrackEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        playFrom(index)
    }

    private func playAll() {
        guard !entries.isEmpty else { return }
        playFrom(0)
    }

    private func playFrom(_ index: Int) {
        guard !entries.isEmpty else { return }
        let queue = entries.map(\.track)
        let start = queue[min(index, queue.count - 1)]
        PlayerService.shared.play(
            tracks: queue,
            source: .plugins,
            startAt: start,
            context: .plugins(name: playlist.name)
        )
    }

    private func playSelectedNext() {
        let tracks = selectedTracks
        guard !tracks.isEmpty else { return }
        player.addToPlayNext(tracks)
        selectedIDs.removeAll()
        multiSelectMode = false
    }

    /// Adds whatever is playing; NetEase songs are stored by id, plugin songs
    /// by their raw item, and both go to the top of the list.
    private func addCurrent() {
        guard let track = player.currentTrack, let entry = LocalTrackEntry(track: track) else { return }
        let added = ImportedPlaylistStore.shared.addEntries([entry], to: playlist)
        reload()
        if added == 0 {
            ToastCenter.shared.show(String(localized: "这首歌已经在歌单里了"))
        } else {
            ToastCenter.shared.show(String(localized: "已添加到「\(playlist.name)」，放在最前面"))
        }
    }

    private func moveEntries(from source: IndexSet, to destination: Int) {
        ImportedPlaylistStore.shared.moveEntries(from: source, to: destination, in: playlist)
        reload()
    }

    private func deleteEntries(at offsets: IndexSet) {
        let ids = Set(offsets.map { visibleEntries[$0].id })
        ImportedPlaylistStore.shared.removeEntries(withIDs: ids, from: playlist)
        reload()
    }
}

/// Drag-to-reorder sheet for local playlists.
struct LocalPlaylistOrderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var layout = PlaylistLayoutStore.shared
    @State private var working: [ImportedPlaylist] = []

    var body: some View {
        AppNavStack {
            List {
                ForEach(working) { playlist in
                    HStack(spacing: 10) {
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.secondary)
                        Text(playlist.name)
                        Spacer()
                        if layout.isPinned(local: playlist.id) {
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
                        layout.setLocalOrder(working)
                        dismiss()
                    }
                }
            }
            .onAppear { working = layout.orderedLocal(ImportedPlaylistStore.shared.playlists) }
        }
    }
}

// MARK: - Row

private struct PluginTrackRow: View {
    let item: PluginMusicItem
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                CachedAsyncImage(url: item.artwork.flatMap(URL.init(string:))) {
                    Rectangle().fill(Color.secondary.opacity(0.12))
                }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 4) {
                    MarqueeText(text: item.title, fontSize: 16, fontWeight: .semibold)
                        .lineLimit(1)
                    Text("\(item.artist) · \(item.album)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if item.durationMS > 0 {
                    Text(CompatDuration.mmss(item.durationMS))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Image(systemName: "play.circle")
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("播放") { onTap() }
        }
    }
}

// MARK: - Manager sheet

struct PluginManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var manager = PluginManager.shared
    @State private var urlText = ""
    @State private var installingName: String?
    @State private var installError: String?

    var body: some View {
        AppNavStack {
            Form {
                installedSection
                presetSection
                customSection
            }
            .navigationTitle("插件管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var installedSection: some View {
        Section {
            if manager.plugins.isEmpty {
                Text("尚未安装插件音源")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(manager.plugins, id: \.platform) { plugin in
                    Toggle(isOn: enabledBinding(for: plugin)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(plugin.name).font(.headline)
                            if let source = plugin.sourceURL {
                                Text(source)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .onDelete { indices in
                    for index in indices.sorted(by: >) {
                        manager.remove(manager.plugins[index])
                    }
                }
            }
        } header: {
            Text("已安装")
        } footer: {
            if let installError {
                Text(installError).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var presetSection: some View {
        Section {
            ForEach(PluginManager.presetSources, id: \.id) { preset in
                Button {
                    Task { await install(preset) }
                } label: {
                    HStack {
                        Text(preset.name)
                            .foregroundStyle(.primary)
                        Spacer()
                        if installingName == preset.name {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.down.circle")
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
        } header: {
            Text("音源商店")
        } footer: {
            Text("插件来自 MusicFree 生态，安装即代表你信任对应插件的作者。")
        }
    }

    @ViewBuilder
    private var customSection: some View {
        Section {
            TextField("https://example.com/plugin.js", text: $urlText)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button {
                Task { await install(url: urlText) }
            } label: {
                if installingName == urlText {
                    HStack {
                        ProgressView()
                        Text("安装中…")
                    }
                } else {
                    Text("从地址安装")
                }
            }
        } header: {
            Text("自定义音源")
        }
    }

    private func enabledBinding(for plugin: PluginManager.InstalledPlugin) -> Binding<Bool> {
        Binding(
            get: { plugin.enabled },
            set: { newValue in manager.setEnabled(newValue, for: plugin) }
        )
    }

    private func install(_ preset: PluginManager.PresetSource) async {
        guard installingName == nil else {
            installError = String(localized: "正在安装其他插件，请稍候")
            return
        }
        installingName = preset.name
        installError = nil
        defer { installingName = nil }
        do {
            try await manager.install(fromMirrors: preset.mirrors)
            urlText = ""
        } catch {
            installError = error.localizedDescription
        }
    }

    private func install(url: String) async {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            installError = String(localized: "请先输入插件地址")
            return
        }
        guard installingName == nil else {
            installError = String(localized: "正在安装其他插件，请稍候")
            return
        }
        installingName = trimmed
        installError = nil
        defer { installingName = nil }
        do {
            try await manager.install(fromMirrors: [trimmed])
            urlText = ""
        } catch {
            installError = error.localizedDescription
        }
    }
}

// MARK: - WebDAV import sheet

struct WebDAVImportView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("webdav.server") private var server = ""
    @AppStorage("webdav.username") private var username = ""
    @AppStorage("webdav.password") private var password = ""

    @State private var entries: [WebDAVEntry] = []
    @State private var path = ""
    /// Absolute URL of the folder being browsed, so 「导出备份」 writes into the
    /// folder the user is looking at instead of the account root.
    @State private var currentDirectoryURL: String?
    @State private var isLoading = false
    @State private var isExporting = false
    @State private var errorMessage: String?
    @State private var importingName: String?

    var body: some View {
        AppNavStack {
            Form {
                Section {
                    TextField("https://dav.jianguoyun.com/dav/", text: $server)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("用户名", text: $username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("密码（应用授权密码）", text: $password)
                    Button {
                        Task { await connect() }
                    } label: {
                        HStack {
                            Text("连接")
                            Spacer()
                            if isLoading { ProgressView() }
                        }
                    }
                } header: {
                    Text("WebDAV 设置")
                } footer: {
                    Text("支持坚果云等 WebDAV 服务。可以直接导入 Beans 的 localLibrary.json，也可以导入 MusicFree 导出的歌单 JSON。「导出备份」把本地歌单写进 KumoneBackup.json，两种音源的歌都在里面。")
                    Text("导出到：" + exportDestination)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        Task { await connect() }
                    } label: {
                        HStack {
                            Text(path.isEmpty ? "刷新根目录" : "刷新当前目录")
                            Spacer()
                            if isLoading { ProgressView() }
                        }
                    }

                    if !entries.isEmpty {
                        ForEach(entries) { entry in
                            entryRow(entry)
                        }
                    }
                } header: {
                    Text(path.isEmpty ? "根目录（连接后显示内容）" : path)
                } footer: {
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("WebDAV 云同步")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("导出备份") {
                        Task { await exportBackup() }
                    }
                    .disabled(ImportedPlaylistStore.shared.playlists.isEmpty || isExporting)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .alert("备份包含 \(backupPluginURLs.count) 个插件", isPresented: $showBackupPluginsOffer) {
                Button("全部安装") {
                    Task { await installBackupPlugins() }
                }
                Button("跳过", role: .cancel) {
                    backupPluginURLs = []
                    dismiss()
                }
            } message: {
                Text("检测到 MusicFree 完整备份：歌单已导入，是否顺便安装备份里的插件？")
            }
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: WebDAVEntry) -> some View {
        if entry.isDirectory {
            Button {
                Task { await connect(into: entry) }
            } label: {
                Label(entry.name, systemImage: "folder")
                    .foregroundStyle(.primary)
            }
        } else {
            Button {
                Task { await importPlaylist(entry) }
            } label: {
                HStack {
                    Label(entry.name, systemImage: "doc.text")
                        .foregroundStyle(.primary)
                    Spacer()
                    if importingName == entry.name {
                        ProgressView()
                    } else {
                        Text(entry.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(importingName != nil)
        }
    }

    private func connect(into directory: WebDAVEntry? = nil) async {
        guard !isLoading else { return }
        let trimmedServer = server.trimmingCharacters(in: .whitespaces)
        guard !trimmedServer.isEmpty, !username.isEmpty, !password.isEmpty else {
            errorMessage = String(localized: "请先填写 WebDAV 地址、用户名和密码")
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let list: [WebDAVEntry]
            if let directory {
                // Navigate via the href the server returned — the server's own
                // encoding is always correct, unlike client-side path building.
                list = try await WebDAVClient.list(
                    urlString: directory.urlString,
                    username: username,
                    password: password
                )
                path = URLComponents(string: directory.urlString)?.path ?? directory.name
                // Keep the collection URL: some servers omit the trailing slash
                // on collection hrefs, and without it a later PUT would land in
                // the parent folder instead.
                currentDirectoryURL = directory.urlString.hasSuffix("/")
                    ? directory.urlString
                    : directory.urlString + "/"
            } else {
                list = try await WebDAVClient.listRoot(
                    server: trimmedServer,
                    username: username,
                    password: password
                )
                path = ""
                currentDirectoryURL = nil
            }
            entries = list
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importPlaylist(_ entry: WebDAVEntry) async {
        guard importingName == nil else { return }
        importingName = entry.name
        errorMessage = nil
        defer { importingName = nil }
        do {
            let data = try await WebDAVClient.download(
                urlString: entry.urlString,
                username: username,
                password: password
            )
            let object = try? JSONSerialization.jsonObject(with: data)

            // Format 0: Beans Music backup — the same file Beans writes to
            // WebDAV, so one backup serves both apps.
            if let backup = object as? [String: Any],
               BeansBackupImporter.looksLikeBeansBackup(backup),
               let parsed = BeansBackupImporter.parse(backup) {
                var importedCount = 0
                for playlist in parsed.playlists {
                    try ImportedPlaylistStore.shared.importEntries(
                        playlist.entries, name: playlist.name, source: "Beans"
                    )
                    importedCount += playlist.entries.count
                }
                guard importedCount > 0 else {
                    errorMessage = String(localized: "这个 Beans 备份里没有可识别的歌曲")
                    return
                }
                var message = String(localized: "已从 Beans 备份导入 \(parsed.playlists.count) 个歌单（\(importedCount) 首）")
                if parsed.skipped > 0 {
                    message += String(localized: "，跳过 \(parsed.skipped) 首（QQ / 酷狗音源这个 App 用不了）")
                }
                ToastCenter.shared.show(message)
                dismiss()
                return
            }

            // Format 1: plain playlist = JSON array of music items.
            if let rawItems = object as? [[String: Any]] {
                let items = rawItems.compactMap { PluginMusicItem(normalizing: $0, platform: "") }
                guard !items.isEmpty else {
                    errorMessage = String(localized: "文件里没有可识别的歌曲")
                    return
                }
                let name = (entry.name as NSString).deletingPathExtension
                try ImportedPlaylistStore.shared.importItems(items, name: name, source: "WebDAV")
                ToastCenter.shared.show(String(localized: "已导入歌单「\(name)」（\(items.count) 首）"))
                dismiss()
                return
            }

            // Format 2: real MusicFree backup = { musicSheets: [...], plugins: [{srcUrl, version}] }.
            // Kumone's own backup writes the same shape (see exportBackup), so a
            // backup written by an older build still restores here and back.
            if let backup = object as? [String: Any] {
                let sheets = (backup["musicSheets"] as? [[String: Any]])
                    ?? (backup["playlists"] as? [[String: Any]]) ?? []
                var importedCount = 0
                for (index, sheet) in sheets.enumerated() {
                    let title = (sheet["title"] as? String) ?? String(localized: "备份歌单 \(index + 1)")
                    let musicList = sheet["musicList"] as? [[String: Any]] ?? []
                    let items = musicList.compactMap { PluginMusicItem(normalizing: $0, platform: "") }
                    if items.isEmpty { continue }
                    try ImportedPlaylistStore.shared.importItems(items, name: title, source: "WebDAV备份")
                    importedCount += items.count
                }

                // Backup plugins are URLs; install via the mirror-fallback path.
                var pluginURLs: [String] = []
                if let array = backup["plugins"] as? [[String: Any]] {
                    for value in array {
                        if let srcUrl = value["srcUrl"] as? String { pluginURLs.append(srcUrl) }
                    }
                } else if let dict = backup["plugins"] as? [String: [String: Any]] {
                    for (_, value) in dict {
                        if let srcUrl = value["srcUrl"] as? String { pluginURLs.append(srcUrl) }
                    }
                }
                if sheets.isEmpty && pluginURLs.isEmpty {
                    errorMessage = String(localized: "不认识的文件格式（既不是歌单也不是 MusicFree 备份）")
                    return
                }
                if importedCount == 0 && pluginURLs.isEmpty {
                    // A silent dismiss here once made Beans backups look like
                    // the import "did nothing" — always say what happened.
                    errorMessage = String(localized: "备份里没有可识别的歌曲")
                    return
                }
                var parts: [String] = []
                if importedCount > 0 { parts.append(String(localized: "\(sheets.count) 个插件歌单（\(importedCount) 首）")) }
                if !parts.isEmpty {
                    ToastCenter.shared.show(String(localized: "已从备份导入 ") + parts.joined(separator: String(localized: "、")))
                }
                if !pluginURLs.isEmpty {
                    backupPluginURLs = pluginURLs
                    showBackupPluginsOffer = true
                } else {
                    dismiss()
                }
                return
            }

            errorMessage = String(localized: "不是有效的 MusicFree 歌单或备份文件")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @State private var backupPluginURLs: [String] = []
    @State private var showBackupPluginsOffer = false

    /// Where 「导出备份」 writes: the folder currently being browsed, or the
    /// address from the settings when none has been opened. Always ends in "/".
    private var exportBase: String {
        var base = currentDirectoryURL ?? server.trimmingCharacters(in: .whitespaces)
        if !base.isEmpty, !base.hasSuffix("/") { base += "/" }
        return base
    }

    /// The full destination, spelled out in the sheet so a mistyped folder is
    /// obvious before the upload fails.
    private var exportDestination: String {
        guard !exportBase.isEmpty else { return String(localized: "（先填 WebDAV 地址）") }
        return WebDAVClient.directoryDescription(of: exportBase + "KumoneBackup.json")
    }

    /// Exports all imported playlists as a MusicFree-format backup JSON and
    /// uploads it to the folder currently being browsed (KumoneBackup.json) —
    /// re-import on any device via this same sheet.
    private func exportBackup() async {
        let trimmedServer = server.trimmingCharacters(in: .whitespaces)
        guard !trimmedServer.isEmpty, !username.isEmpty, !password.isEmpty else {
            errorMessage = String(localized: "请先填写 WebDAV 地址、用户名和密码")
            return
        }
        isExporting = true
        defer { isExporting = false }
        let sheets: [[String: Any]] = ImportedPlaylistStore.shared.playlists.map { playlist in
            let entries = ImportedPlaylistStore.shared.loadEntries(of: playlist)
            return [
                "title": playlist.name,
                "musicList": entries.map(\.dictionary),
            ]
        }
        // A local playlist can hold NetEase entries too; they travel in the
        // same list under their own `kind` marker and survive re-import.
        let backup: [String: Any] = [
            "musicSheets": sheets,
            "plugins": [],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: backup, options: [.prettyPrinted]) else {
            errorMessage = String(localized: "备份序列化失败")
            return
        }
        let base = exportBase
        let target = base + "KumoneBackup.json"
        do {
            try await WebDAVClient.upload(data: data, urlString: target, username: username, password: password)
            ToastCenter.shared.show(
                String(localized: "已备份到 ") + WebDAVClient.directoryDescription(of: target)
            )
            // Refresh the listing so the new file is visible — that also proves
            // the write landed where the user expects.
            entries = (try? await WebDAVClient.list(
                urlString: base,
                username: username,
                password: password
            )) ?? entries
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func installBackupPlugins() async {
        var installed = 0
        for urlString in backupPluginURLs {
            do {
                try await PluginManager.shared.install(fromMirrors: [urlString])
                installed += 1
            } catch {
                // Keep going with the rest.
            }
        }
        if installed > 0 {
            ToastCenter.shared.show(String(localized: "已从备份安装 \(installed) 个插件"))
        }
        backupPluginURLs = []
        showBackupPluginsOffer = false
        dismiss()
    }
}

// MARK: - Plugin debug log

/// Shows the plugin engine's recent HTTP requests (for troubleshooting).
struct PluginLogView: View {
    @State private var entries: [PluginEngine.RequestLogEntry] = []
    @State private var callErrors: [String] = []

    var body: some View {
        List {
            if !callErrors.isEmpty {
                Section("JS 调用失败") {
                    ForEach(callErrors, id: \.self) { line in
                        Text(line)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.red)
                    }
                }
            }
            if entries.isEmpty {
                Text("还没有插件请求记录")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(entry.method) \(entry.status) · \(entry.size)B")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(entry.status >= 400 ? Color.red : Color.secondary)
                        Text(entry.url)
                            .font(.caption2)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("插件调试日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("复制全部") {
                    let text = entries.reversed()
                        .map { "\($0.method) \($0.status) \($0.size)B \($0.url)" }
                        .joined(separator: "\n")
                    Platform.copyToPasteboard(string: text)
                    ToastCenter.shared.show(String(localized: "日志已复制"))
                }
                .disabled(entries.isEmpty)
            }
        }
        .task {
            entries = await PluginEngine.shared.snapshotRequestLog()
            callErrors = await PluginEngine.shared.snapshotCallLog()
        }
    }
}
