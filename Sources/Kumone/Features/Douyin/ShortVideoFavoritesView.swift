#if os(iOS)
import Combine
import SwiftUI
import WebKit

/// 抖音 / TikTok 收藏夹：在网页里登录一次，抓下来，然后用普通的播放队列听
/// （后台、锁屏都走 Kumone 原有的音频通道）。
struct ShortVideoFavoritesView: View {
    let platform: ShortVideoPlatform

    @StateObject private var collector: ShortVideoCollector
    @Environment(\.dismiss) private var dismiss
    @State private var showWeb = false
    @State private var showClearConfirm = false
    @State private var showSyncSettings = false
    @State private var syncMessage: String?

    init(platform: ShortVideoPlatform) {
        self.platform = platform
        _collector = StateObject(wrappedValue: ShortVideoCollector(platform: platform))
    }

    var body: some View {
        AppNavStack {
            Group {
                if showWeb || collector.videos.isEmpty {
                    webPane
                } else {
                    listPane
                }
            }
            .navigationTitle(platform.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        showSyncSettings = true
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.icloud")
                    }
                    .accessibilityLabel("收藏同步")

                    Button {
                        showWeb.toggle()
                    } label: {
                        Image(systemName: showWeb ? "list.bullet" : "safari")
                    }
                    .accessibilityLabel(showWeb ? "收藏列表" : "打开网页")

                    Button {
                        playAll()
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .disabled(collector.videos.isEmpty)
                    .accessibilityLabel("全部播放")
                }
            }
            .onAppear {
                collector.loadFavoritesPageIfNeeded()
                Task { await autoSync() }
            }
            .onDisappear {
                if collector.isCollecting { collector.stopCollecting() }
            }
            .onChange(of: collector.phase) { phase in
                guard phase == .finished else { return }
                Task { await pushAfterCollect() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .shortVideoDidSync)) { _ in
                collector.applyRemote(ShortVideoStore.load(platform))
            }
            .confirmationDialog("清空已抓取的收藏？", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("清空", role: .destructive) { collector.clear() }
                Button("取消", role: .cancel) {}
            }
            .sheet(isPresented: $showSyncSettings) {
                ShortVideoSyncSettingsView()
            }
        }
    }

    // MARK: - 网页

    private var webPane: some View {
        VStack(spacing: 0) {
            ShortVideoWebView(webView: collector.webView)
                .overlay(alignment: .top) {
                    if collector.isCollecting {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在抓取 \(collector.videos.count) 条")
                                .font(.footnote)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.top, 10)
                    }
                }

            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: collector.loggedIn ? "checkmark.circle.fill" : "person.crop.circle.badge.exclamationmark")
                        .font(.footnote)
                        .foregroundStyle(collector.loggedIn ? Color.green : Color.secondary)
                    Text(collector.loggedIn ? "已登录 \(platform.albumName)" : "未登录：在网页里点「登录」")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                Text(collector.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 10) {
                    if collector.isCollecting {
                        Button {
                            collector.stopCollecting()
                        } label: {
                            Label("停止抓取", systemImage: "stop.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button {
                            collector.startCollecting()
                        } label: {
                            Label("开始抓取", systemImage: "arrow.down.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Button {
                        collector.openHomePage()
                    } label: {
                        Image(systemName: "house")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("打开首页登录")

                    Button {
                        collector.openLoginPage()
                    } label: {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("打开登录页")

                    Button {
                        collector.reloadPage()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("重新加载收藏页")

                    if !collector.videos.isEmpty {
                        Button {
                            showWeb = false
                        } label: {
                            Image(systemName: "list.bullet")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("收藏列表")
                    }
                }
            }
            .padding(12)
            .background(.bar)
        }
    }

    // MARK: - 列表

    private var listPane: some View {
        List {
            Section {
                ForEach(collector.videos) { video in
                    Button {
                        play(video)
                    } label: {
                        row(video)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("\(collector.videos.count) 条 · \(collector.status)")
            }
        }
        .listStyle(.plain)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if let syncMessage {
                    Text(syncMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 12) {
                    Button {
                        saveAsPlaylist()
                    } label: {
                        Label("存为歌单", systemImage: "text.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        showClearConfirm = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(12)
            .background(.bar)
        }
    }

    private func row(_ video: ShortVideo) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: video.cover.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.secondary.opacity(0.15)
            }
            .frame(width: 54, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(video.title)
                    .font(.subheadline)
                    .lineLimit(2)
                Text(video.author.isEmpty ? platform.albumName : video.author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(durationText(video.durationMS))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

            Image(systemName: "play.circle.fill")
                .font(.title3)
                .foregroundStyle(.tint)
        }
        .contentShape(Rectangle())
    }

    // MARK: - 操作

    private func play(_ video: ShortVideo) {
        guard let item = video.pluginItem else { return }
        let track = Track(pluginItem: item)
        PlayerService.shared.repeatMode = .one
        PlayerService.shared.play(
            tracks: [track],
            source: .plugins,
            context: .plugins(name: platform.displayName)
        )
    }

    private func playAll() {
        let tracks = collector.videos.compactMap { $0.pluginItem }.map { Track(pluginItem: $0) }
        guard !tracks.isEmpty else { return }
        PlayerService.shared.repeatMode = .all
        PlayerService.shared.play(
            tracks: tracks,
            source: .plugins,
            context: .plugins(name: platform.displayName)
        )
    }

    private func saveAsPlaylist() {
        let items = collector.videos.compactMap { $0.pluginItem }
        guard !items.isEmpty else { return }
        do {
            try ImportedPlaylistStore.shared.importItems(
                items,
                name: platform.displayName,
                source: platform.albumName
            )
            ToastCenter.shared.show("已保存到本地歌单「\(platform.displayName)」")
        } catch {
            ToastCenter.shared.show("保存失败：\(error.localizedDescription)")
        }
    }

    private func durationText(_ milliseconds: Int) -> String {
        guard milliseconds > 0 else { return "--:--" }
        let total = milliseconds / 1000
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - 同步

    private func autoSync() async {
        let config = ShortVideoSyncConfig.load()
        guard config.isValid else { return }
        do {
            try await ShortVideoSyncService.synchronize(config)
            collector.applyRemote(ShortVideoStore.load(platform))
            syncMessage = "已与 WebDAV 同步（\(collector.videos.count) 条）"
        } catch {
            syncMessage = "同步失败：\(error.localizedDescription)"
        }
    }

    private func pushAfterCollect() async {
        let config = ShortVideoSyncConfig.load()
        guard config.isValid else { return }
        do {
            try await ShortVideoSyncService.synchronize(config)
            syncMessage = "已同步到 WebDAV"
        } catch {
            syncMessage = "同步失败：\(error.localizedDescription)"
        }
    }
}

private struct ShortVideoWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif