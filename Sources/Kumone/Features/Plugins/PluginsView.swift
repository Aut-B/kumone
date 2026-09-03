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
    @State private var query = ""
    @State private var showManager = false

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
                ToolbarItem(placement: .topBarTrailing) {
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
                subtitle: "点击右上角按钮安装音源，兼容 MusicFree 插件生态"
            )
        } else {
            VStack(spacing: 0) {
                pluginPicker
                resultList
            }
        }
    }

    private var pluginPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(PluginManager.shared.plugins) { plugin in
                    let isSelected = model.selectedPlatform == plugin.platform
                    Button {
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
                            .background(
                                Capsule().fill(isSelected ? Color.accent.opacity(0.16) : Color.secondary.opacity(0.08))
                            )
                            .foregroundStyle(isSelected ? Color.accent : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private var resultList: some View {
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
                    MarqueeText(item.title, fontSize: 16, fontWeight: .semibold)
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
    @State private var installingURL: String?
    @State private var installError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if manager.plugins.isEmpty {
                        Text("尚未安装插件音源")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(manager.plugins) { plugin in
                            HStack {
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

                Section {
                    ForEach(PluginManager.presetSources) { preset in
                        Button {
                            Task { await install(url: preset.url) }
                        } label: {
                            HStack {
                                Text(preset.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if installingURL == preset.url {
                                    ProgressView()
                                } else {
                                    Image(systemName: "arrow.down.circle")
                                        .foregroundStyle(Color.accent)
                                }
                            }
                        }
                        .disabled(installingURL != nil)
                    }
                } header: {
                    Text("音源商店")
                } footer: {
                    Text("插件来自 MusicFree 生态，安装即代表你信任对应插件的作者。")
                }

                Section {
                    TextField("https://example.com/plugin.js", text: $urlText)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button {
                        Task { await install(url: urlText) }
                    } label: {
                        Text("从地址安装")
                    }
                    .disabled(urlText.isEmpty || installingURL != nil)
                } header: {
                    Text("自定义音源")
                }
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

    private func enabledBinding(for plugin: PluginManager.InstalledPlugin) -> Binding<Bool> {
        Binding(
            get: { plugin.enabled },
            set: { newValue in manager.setEnabled(newValue, for: plugin) }
        )
    }

    private func install(url: String) async {
        guard installingURL == nil else { return }
        installingURL = url
        installError = nil
        defer { installingURL = nil }
        do {
            try await manager.install(from: url)
            urlText = ""
        } catch {
            installError = error.localizedDescription
        }
    }
}
