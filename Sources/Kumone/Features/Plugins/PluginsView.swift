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
    enum Section: Hashable {
        case search, playlists
    }

    @StateObject private var model = PluginsSearchModel()
    @State private var query = ""
    @State private var showManager = false
    @State private var showWebDAV = false
    @State private var section: Section = .search

    var body: some View {
        content
            .navigationTitle("插件音源")
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text("在插件音源中搜索")
            )
            .onSubmit(of: .search) {
                section = .search
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
                    Button {
                        showManager = true
                    } label: {
                        Image(systemName: "puzzlepiece.extension")
                    }
                    .accessibilityLabel("插件管理")
                }
            }
            .sheet(isPresented: $showManager) {
                PluginManagerView()
            }
            .sheet(isPresented: $showWebDAV) {
                WebDAVImportView()
            }
            .onAppear {
                model.selectFirst()
                if model.items.isEmpty, !query.isEmpty {
                    Task { await model.search(query: query) }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if PluginManager.shared.plugins.isEmpty {
            EmptyStateView(
                icon: "puzzlepiece.extension",
                title: "还没有安装插件音源",
                subtitle: "点击右上角拼图按钮安装音源，兼容 MusicFree 插件生态"
            )
        } else {
            VStack(spacing: 0) {
                Picker("", selection: $section) {
                    Text("搜索").tag(Section.search)
                    Text("歌单").tag(Section.playlists)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                switch section {
                case .search:
                    pluginPicker
                    searchResults
                case .playlists:
                    playlistList
                }
            }
        }
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
            Spacer()
            ProgressView()
            Spacer()
        } else if let error = model.errorMessage, model.items.isEmpty {
            Spacer()
            EmptyStateView(icon: "wifi.exclamationmark", title: "搜索失败", subtitle: LocalizedStringKey(error))
            Spacer()
        } else if model.items.isEmpty {
            Spacer()
            EmptyStateView(icon: "magnifyingglass", title: "输入关键词开始搜索")
            Spacer()
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        PluginTrackRow(item: item) {
                            model.play(at: index)
                        }
                    }
                    if model.hasMore {
                        ProgressView()
                            .padding()
                            .task { await model.loadMore() }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 80)
            }
        }
    }

    @ViewBuilder
    private var playlistList: some View {
        let playlists = ImportedPlaylistStore.shared.playlists
        if playlists.isEmpty {
            Spacer()
            EmptyStateView(
                icon: "music.note.list",
                title: "还没有导入歌单",
                subtitle: "点击右上角下载图标，从你的 WebDAV 导入 MusicFree 备份歌单"
            )
            Spacer()
        } else {
            List {
                ForEach(playlists) { playlist in
                    Button {
                        play(playlist)
                    } label: {
                        HStack {
                            Image(systemName: "music.note.list")
                                .foregroundStyle(Theme.accent)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.name).font(.body.weight(.medium))
                                Text("\(playlist.itemCount) 首 · \(playlist.source)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            ImportedPlaylistStore.shared.remove(playlist)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private func play(_ playlist: ImportedPlaylist) {
        let items = ImportedPlaylistStore.shared.loadItems(of: playlist)
        guard !items.isEmpty else {
            ToastCenter.shared.show(String(localized: "歌单为空或解析失败"))
            return
        }
        let queue = items.map { Track(pluginItem: $0) }
        PlayerService.shared.play(
            tracks: queue,
            source: .plugins,
            startAt: queue[0],
            context: .plugins(name: playlist.name)
        )
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
                    Text(Duration.milliseconds(item.durationMS).formatted(.time(pattern: .minuteSecond)))
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
        NavigationStack {
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
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var importingName: String?

    var body: some View {
        NavigationStack {
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
                    Text("支持坚果云等 WebDAV 服务。把 MusicFree 导出的歌单 JSON 备份到任意目录后在此导入。")
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
            .navigationTitle("WebDAV 导入歌单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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
            } else {
                list = try await WebDAVClient.listRoot(
                    server: trimmedServer,
                    username: username,
                    password: password
                )
                path = ""
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
                if importedCount > 0 {
                    ToastCenter.shared.show(String(localized: "已从备份导入 \(sheets.count) 个歌单（\(importedCount) 首）"))
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
