#if os(iOS)
import SwiftUI
import WebKit

/// Douyin favourites: log in inside the embedded web page, scrape the list,
/// then play it with the normal queue (audio only, screen off included).
struct DouyinFavoritesView: View {
    @StateObject private var collector = DouyinCollector()
    @Environment(\.dismiss) private var dismiss
    @State private var showWeb = false
    @State private var showClearConfirm = false

    var body: some View {
        AppNavStack {
            Group {
                if showWeb || collector.videos.isEmpty {
                    webPane
                } else {
                    listPane
                }
            }
            .navigationTitle("抖音收藏")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
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
            .onAppear { collector.loadFavoritesPageIfNeeded() }
            .onDisappear {
                if collector.isCollecting { collector.stopCollecting() }
            }
            .confirmationDialog("清空已抓取的收藏？", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("清空", role: .destructive) { collector.clear() }
                Button("取消", role: .cancel) {}
            }
        }
    }

    // MARK: - Web pane

    private var webPane: some View {
        VStack(spacing: 0) {
            DouyinWebView(webView: collector.webView)
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
                Text(collector.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 12) {
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
                        collector.reloadPage()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)

                    if !collector.videos.isEmpty {
                        Button {
                            showWeb = false
                        } label: {
                            Image(systemName: "list.bullet")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding(12)
            .background(.bar)
        }
    }

    // MARK: - List pane

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
            .padding(12)
            .background(.bar)
        }
    }

    private func row(_ video: DouyinVideo) -> some View {
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
                Text(video.author.isEmpty ? "抖音" : video.author)
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

    // MARK: - Actions

    private func play(_ video: DouyinVideo) {
        guard let item = video.pluginItem else { return }
        let track = Track(pluginItem: item)
        PlayerService.shared.repeatMode = .one
        PlayerService.shared.play(
            tracks: [track],
            source: .plugins,
            context: .plugins(name: "抖音收藏")
        )
    }

    private func playAll() {
        let tracks = collector.videos.compactMap { $0.pluginItem }.map { Track(pluginItem: $0) }
        guard !tracks.isEmpty else { return }
        PlayerService.shared.repeatMode = .all
        PlayerService.shared.play(
            tracks: tracks,
            source: .plugins,
            context: .plugins(name: "抖音收藏")
        )
    }

    private func saveAsPlaylist() {
        let items = collector.videos.compactMap { $0.pluginItem }
        guard !items.isEmpty else { return }
        do {
            try ImportedPlaylistStore.shared.importItems(items, name: "抖音收藏", source: "抖音")
            ToastCenter.shared.show("已保存到本地歌单「抖音收藏」")
        } catch {
            ToastCenter.shared.show("保存失败：\(error.localizedDescription)")
        }
    }

    private func durationText(_ milliseconds: Int) -> String {
        guard milliseconds > 0 else { return "--:--" }
        let total = milliseconds / 1000
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct DouyinWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif