import SwiftUI

#if os(iOS)
public struct IOSMainWindow: View {
    @StateObject private var player = PlayerService.shared
    @StateObject private var account = AccountStore.shared
    @StateObject private var settings = SettingsManager.shared
    @StateObject private var toasts = ToastCenter.shared
    @StateObject private var updater = IOSUpdater.shared
    @StateObject private var artworkStore = NowPlayingArtworkStore()
    @Namespace private var nowPlayingTransition
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.scenePhase) private var scenePhase

    /// The app's intended scheme, read on this ancestor so the search-active
    /// tab environment can't invert it (#31).
    private var resolvedColorScheme: ColorScheme {
        settings.appearance.colorScheme ?? systemColorScheme
    }

    @State private var selectedTab: IOSTab = Self.initialSelectedTab()

    private static func initialSelectedTab() -> IOSTab {
        CommandLine.arguments.contains("-kumone.search.tab") ? .search : .home
    }

    private static var isUITest: Bool {
        CommandLine.arguments.contains("-kumone.ui.test")
    }

    /// Returning from the lock screen every few minutes must not rescan

    /// every download and playlist each time.

    @State private var lastForegroundRefresh: Date?
    @State private var showLogin = false
    @State private var showSettings = false

    /// Which root-level sheet is up. `showSettings`/`showLogin` keep their
    /// Bool form because other views bind to them directly; this derives one
    /// item-driven sheet from the two.
    private enum RootSheet: Identifiable {
        case settings
        case login

        var id: Int { hashValue }
    }

    private var rootSheetBinding: Binding<RootSheet?> {
        Binding(
            get: {
                if showSettings { return .settings }
                if showLogin { return .login }
                return nil
            },
            set: { sheet in
                showSettings = sheet == .settings
                showLogin = sheet == .login
            }
        )
    }
    @State private var homePath: [Destination] = []
    @State private var explorePath: [Destination] = []
    @State private var fmPath: [Destination] = []
    @State private var searchPath: [Destination] = []
    @State private var libraryPath: [Destination] = []
    @State private var pluginsPath: [Destination] = []

    public init() {}

    public var body: some View {
        UpstreamGate { gatedBody }
            .tint(Theme.accent)
            .preferredColorScheme(settings.appearance.colorScheme)
    }

    private var gatedBody: some View {
        presentationRoot
            .modifier(OfflinePlaybackAlert(player: player, onDownloads: { openDestination(.downloaded) }, enabled: !player.showNowPlaying))
            .modifier(MeteredDownloadAlert(enabled: !player.showNowPlaying))
            .environmentObject(player)
            .environmentObject(account)
            .environmentObject(settings)
            .environmentObject(toasts)
            .environmentObject(artworkStore)
            .tint(Theme.accent)
            .preferredColorScheme(settings.appearance.colorScheme)
            .environment(\.openLogin, { showLogin = true })
            .environment(\.presentSettingsSheet, { showSettings = true })
            .environment(\.openDestination, openDestination)
            .modifier(PlaybackLifecycle())
            .task {
                await DownloadManager.shared.start()
                await account.bootstrap()
                if settings.autoCheckUpdates, DistributionChannel.current.allowsSelfUpdate, !Self.isUITest {
                    IOSUpdater.shared.check(interactive: false)
                }
            }
            .onChange(of: scenePhase) { phase in
                guard phase == .active else { return }
                if let last = lastForegroundRefresh, Date().timeIntervalSince(last) < 300 { return }
                lastForegroundRefresh = Date()
                Task {
                    await DownloadManager.shared.refreshLibrary()
                    if DownloadManager.shared.network.connected { await account.refreshLibrary() }
                }
            }
            .task(id: settings.showMainWindowAmbientBackground) {
                artworkStore.setArtworkNeeded(settings.showMainWindowAmbientBackground)
            }
            // The update prompt lives on its own background node: presentation
            // modifiers stacked on one chain keep only the last one on iOS 15,
            // so the earlier sheets would silently never appear there.
            .background(
                Color.clear
                    .sheet(isPresented: $updater.showSheet) {
                        IOSUpdaterSheet()
                    }
            )
            // Settings and login share one item-driven sheet (same reason as
            // above). Presented here rather than from the Library tab or the
            // iPad sidebar: a sheet hosted inside the tab view is re-hosted
            // when the tabs update, which reset its navigation (#191 review).
            .sheet(item: rootSheetBinding) { sheet in
                switch sheet {
                case .settings:
                    // Outside the modifiers above, so hand the sheet the same
                    // environment the rest of the app gets.
                    SettingsSheet(
                        titleDisplayMode: UIDevice.current.userInterfaceIdiom == .pad ? .inline : .automatic
                    )
                    .environmentObject(player)
                    .environmentObject(account)
                    .environmentObject(settings)
                    .environmentObject(toasts)
                    .environmentObject(artworkStore)
                    .tint(Theme.accent)
                    .preferredColorScheme(settings.appearance.colorScheme)
                    .environment(\.openLogin, { showLogin = true })
                    .environment(\.openDestination, openDestination)
                case .login:
                    LoginSheet()
                        .environmentObject(account)
                        .environmentObject(toasts)
                }
            }
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    if let toast = toasts.current {
                        ToastView(toast: toast)
                            .transition(AnyTransition.move(edge: Edge.top).combined(with: .opacity))
                            .padding(.top, 8)
                    }
                    if selectedTab != .search, !player.hasCurrentTrack {
                        PlaybackHandoffBanner()
                    }
                }
                .padding(.top, 8)
            }
            .animation(.spring(duration: 0.3), value: toasts.current)
            .animation(.spring(duration: 0.35), value: player.hasCurrentTrack)
    }

    @ViewBuilder
    private var presentationRoot: some View {
        if UIDevice.current.userInterfaceIdiom == .phone {
            if #available(iOS 18.0, *) {
                zoomNowPlayingRoot
            } else {
                // iOS 16/17 used to slide the page up in place, inside a
                // ZStack over the tabs. On iOS 17 that transition could stop
                // part way, leaving the page stuck short of the top (#213), so
                // these systems use the system cover too. Without the zoom
                // there is no system swipe to close it, so the page keeps its
                // own pull-down; what it uncovers is the cover's backdrop.
                systemNowPlayingRoot(usesSystemInteractiveDismissal: false)
            }
        } else {
            systemNowPlayingRoot(usesSystemInteractiveDismissal: true)
        }
    }

    private func systemNowPlayingRoot(usesSystemInteractiveDismissal: Bool) -> some View {
        appContent
            .fullScreenCover(isPresented: $player.showNowPlaying) {
                systemNowPlayingPresentation(
                    usesSystemInteractiveDismissal: usesSystemInteractiveDismissal
                )
            }
    }

    @available(iOS 18.0, *)
    private var zoomNowPlayingRoot: some View {
        appContent
            .fullScreenCover(isPresented: $player.showNowPlaying) {
                systemNowPlayingPresentation(usesSystemInteractiveDismissal: true)
                    .navigationTransition(
                        .zoom(
                            sourceID: NowPlayingTransitionID.surface,
                            in: nowPlayingTransition
                        )
                    )
            }
    }

    @ViewBuilder
    private func systemNowPlayingPresentation(usesSystemInteractiveDismissal: Bool) -> some View {
        // A clear cover background sends iOS 17 into an endless layout pass
        // over the page: the cover never comes up and the app freezes at
        // full CPU (#213, reproduced on the iOS 17.5 simulator). Earlier
        // systems keep the cover's own background.
        if #available(iOS 18.0, *) {
            nowPlayingPresentation(usesSystemInteractiveDismissal: usesSystemInteractiveDismissal)
                .presentationBackground(.clear)
        } else {
            nowPlayingPresentation(usesSystemInteractiveDismissal: usesSystemInteractiveDismissal)
        }
    }

    private var appContent: some View {
        // The iPad split view (MainWindow) needs NavigationSplitView, which is
        // iOS 16+; on the iOS 15 lane every idiom uses the tab interface, the
        // same fallback the proven 0.3.24 release line ships.
        tabInterface
            .background {
                if settings.showMainWindowAmbientBackground {
                    MainWindowAmbientBackground(
                        colors: artworkStore.colors,
                        intensity: settings.mainWindowAmbientBackgroundIntensity
                    )
                    .ignoresSafeArea()
                }
            }
    }

    private func nowPlayingPresentation(usesSystemInteractiveDismissal: Bool) -> some View {
        // The cover animates its own way out; a SwiftUI animation would only
        // be layered on top of it.
        IOSNowPlayingPresentation(
            isPresented: $player.showNowPlaying,
            mode: settings.nowPlayingMode,
            usesSystemInteractiveDismissal: usesSystemInteractiveDismissal,
            dismissAnimation: nil
        ) {
            NowPlayingView(onOpenDestination: openDestination)
                .environmentObject(player)
                .environmentObject(account)
                .environmentObject(settings)
        }
        .modifier(NowPlayingLoginPresenter())
        // A fullScreenCover sits above the root toast overlay, so re-host the
        // same ToastCenter on the page (#182).
        .overlay(alignment: .top) {
            if let toast = toasts.current {
                ToastView(toast: toast)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: toasts.current)
        .environmentObject(toasts)
    }

    @ViewBuilder
    private var tabInterface: some View {
        // iOS 26's search-role tab owns the search field and can replace the
        // page with an empty system search experience. The hand-built bar keeps
        // SearchView's explicit in-page field visible on every supported device.
        customTabInterface
    }

    /// Attach the bottom mini-player accessory only when something is playing.
    /// Leaving the modifier on with empty content still renders an empty,
    /// translucent accessory platter above the tab bar when idle (#35), so we
    /// apply it conditionally.
    @available(iOS 26.0, *)
    private var iOS26TabInterface: some View {
        iOS26TabView
            .tabBarMinimizeBehavior(.onScrollDown)
            // Apply the accessory through a ViewModifier so the TabView keeps a
            // single identity across the hasCurrentTrack toggle. An if/else here
            // churns the TabView identity, which detaches the accessory's
            // matchedTransitionSource and makes the now-playing zoom anchor at
            // the screen centre (#57); not applying it when idle keeps the empty
            // accessory platter gone (#35).
            .modifier(MiniPlayerAccessoryModifier(
                isActive: player.hasCurrentTrack,
                transitionNamespace: nowPlayingTransition,
                colorScheme: resolvedColorScheme
            ))
            .animation(AppAnimation.standard, value: player.hasCurrentTrack)
    }

    @available(iOS 26.0, *)
    private var iOS26TabView: some View {
        TabView(selection: $selectedTab) {
            Tab("推荐", systemImage: "house", value: .home) {
                tabStack(.home) { HomeView() }
            }

            Tab("精选", systemImage: "square.grid.2x2", value: .explore) {
                tabStack(.explore) { ExploreView() }
            }

            Tab("漫游", systemImage: "wave.3.right.circle", value: .fm) {
                tabStack(.fm) { FMView() }
            }

            Tab("我的", systemImage: "person.crop.circle", value: .library) {
                tabStack(.library) { IOSLibraryView(showLogin: $showLogin) }
            }

            Tab("插件", systemImage: "puzzlepiece.extension", value: .plugins) {
                tabStack(.plugins) { PluginsRootView() }
            }

            Tab(value: .search, role: .search) {
                tabStack(.search) { SearchView(query: "") }
            } label: {
                Label("搜索", systemImage: "magnifyingglass")
            }
        }
    }

    private var customTabInterface: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                page(.home) { tabStack(.home) { HomeView() } }
                page(.explore) { tabStack(.explore) { ExploreView() } }
                page(.fm) { tabStack(.fm) { FMView() } }
                page(.search) { tabStack(.search) { SearchView(query: "") } }
                page(.plugins) { tabStack(.plugins) { PluginsRootView() } }
                page(.library) { tabStack(.library) { IOSLibraryView(showLogin: $showLogin) } }
            }

            VStack(spacing: 8) {
                if player.hasCurrentTrack {
                    IOSMiniPlayerBar(presentation: .legacyOverlay)
                        .nowPlayingTransitionSource(in: nowPlayingTransition)
                        .padding(.horizontal, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                GlassTabBar(items: Self.tabItems, selection: $selectedTab) { tab in
                    popToRoot(tab)
                }
            }
            .padding(.bottom, 6)
        }
        .animation(AppAnimation.standard, value: player.hasCurrentTrack)
    }

    private func popToRoot(_ tab: IOSTab) {
        switch tab {
        case .home: homePath = []
        case .explore: explorePath = []
        case .fm: fmPath = []
        case .search: searchPath = []
        case .library: libraryPath = []
        case .plugins: pluginsPath = []
        }
    }

    private func openDestination(_ destination: Destination) {
        player.showNowPlaying = false
        let path = binding(for: selectedTab)
        var destinations = path.wrappedValue
        destinations.appendIfNotCurrent(destination)
        path.wrappedValue = destinations
    }

    @ViewBuilder
    private func tabStack<Content: View>(
        _ tab: IOSTab,
        // @escaping: AppNavStackPath stores the closure as a property.
        @ViewBuilder _ content: @escaping () -> Content
    ) -> some View {
        AppNavStackPath(path: binding(for: tab)) {
            content()
        }
        .publishesWindowHorizontalInsets()
    }

    @ViewBuilder
    private func page<Content: View>(
        _ tab: IOSTab,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        content()
            .opacity(selectedTab == tab ? 1 : 0)
            .allowsHitTesting(selectedTab == tab)
            .zIndex(selectedTab == tab ? 1 : 0)
    }

    private func binding(for tab: IOSTab) -> Binding<[Destination]> {
        switch tab {
        case .home: return $homePath
        case .explore: return $explorePath
        case .fm: return $fmPath
        case .search: return $searchPath
        case .library: return $libraryPath
        case .plugins: return $pluginsPath
        }
    }
}

enum IOSTab: Hashable {
    case home, explore, fm, search, library, plugins
}

extension IOSMainWindow {
    static let tabItems: [GlassTabBar.Item] = [
        .init(tab: .home, title: "推荐", icon: "house"),
        .init(tab: .explore, title: "精选", icon: "square.grid.2x2"),
        .init(tab: .fm, title: "漫游", icon: "dot.radiowaves.left.and.right"),
        .init(tab: .search, title: "搜索", icon: "magnifyingglass"),
        .init(tab: .plugins, title: "插件", icon: "puzzlepiece.extension"),
        .init(tab: .library, title: "我的", icon: "person.crop.circle"),
    ]
}

private enum NowPlayingTransitionID {
    static let surface = "now-playing-surface"
}

/// Login requested from the player must be presented by the player itself:
/// the main window is already presenting its full-screen cover on iOS 18+.
/// Keeping this state here also makes cancellation return to the same player.
private struct NowPlayingLoginPresenter: ViewModifier {
    @EnvironmentObject private var account: AccountStore
    @State private var showLogin = false

    func body(content: Content) -> some View {
        content
            .environment(\.openLogin, { showLogin = true })
            .sheet(isPresented: $showLogin) {
                LoginSheet()
                    .environmentObject(account)
            }
    }
}

// MARK: - Mini player bar for iOS

@available(iOS 26.0, *)
private struct MiniPlayerAccessoryModifier: ViewModifier {
    let isActive: Bool
    let transitionNamespace: Namespace.ID
    let colorScheme: ColorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if isActive {
            content.tabViewBottomAccessory {
                IOSMiniPlayerAccessory(transitionNamespace: transitionNamespace)
                    // Pin the scheme so the search-active tab environment
                    // doesn't flip the bar's text to white (#31).
                    .environment(\.colorScheme, colorScheme)
            }
        } else {
            content
        }
    }
}

@available(iOS 26.0, *)
private struct IOSMiniPlayerAccessory: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @State private var lastKnownPlacementIsInline: Bool?
    let transitionNamespace: Namespace.ID

    var body: some View {
        IOSMiniPlayerBar(presentation: presentation)
            // Match the complete system accessory, never only its artwork.
            .nowPlayingTransitionSource(in: transitionNamespace)
            .onChange(of: placementIsInline, initial: true) { _, isInline in
                if let isInline { lastKnownPlacementIsInline = isInline }
            }
    }

    private var placementIsInline: Bool? {
        placement.map { $0 == .inline }
    }

    private var presentation: IOSMiniPlayerBar.Presentation {
        NowPlayingPresentationMetrics.shouldUseInlineMiniPlayerLayout(
            placementIsInline: placementIsInline,
            lastKnownPlacementIsInline: lastKnownPlacementIsInline
        ) ? .inlineAccessory : .bottomAccessory
    }
}

private extension View {
    @ViewBuilder
    func nowPlayingTransitionSource(in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            matchedTransitionSource(
                id: NowPlayingTransitionID.surface,
                in: namespace
            )
        } else {
            // Pre-18 slides the full-screen cover up; there is no zoom to
            // pair with.
            self
        }
    }
}

/// Renders mini-player content inside either a system-owned tab accessory or
/// the material-backed compatibility overlay used before iOS 26.
///
/// Do not add a background for `bottomAccessory` or `inlineAccessory`: the
/// tab view owns their Liquid Glass surface and adding another material creates
/// a visibly nested card.
struct IOSMiniPlayerBar: View {
    enum Presentation {
        case bottomAccessory
        case inlineAccessory
        case legacyOverlay

        var isInline: Bool { self == .inlineAccessory }
        var drawsBackground: Bool { self == .legacyOverlay }
    }

    @EnvironmentObject private var player: PlayerService
    let presentation: Presentation

    var body: some View {
        playerBarSurface
            .simultaneousGesture(expandGesture)
    }

    @ViewBuilder
    private var playerBarSurface: some View {
        if presentation.drawsBackground {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 4) {
            Button(action: showNowPlaying) {
                trackSummary
            }
            .buttonStyle(.plain)
            .accessibilityLabel(nowPlayingAccessibilityLabel)
            .accessibilityHint("打开正在播放")
            .accessibilityIdentifier("mini-player-now-playing")

            if !presentation.isInline {
                Button(action: player.previous) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .disabled(player.isFMMode)
                .opacity(player.isFMMode ? 0.35 : 1)
                .accessibilityLabel("上一首")
            }

            Button(action: player.togglePlayPause) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(player.isPlaying ? "暂停" : "播放")

            if !presentation.isInline {
                Button(action: player.next) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("下一首")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
    }

    private var trackSummary: some View {
        HStack(alignment: .top, spacing: 8) {
            CachedAsyncImage(url: player.currentTrack?.album.picUrl?.resizedImageURL(128))
                .frame(
                    width: artworkSize,
                    height: artworkSize
                )
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 4, y: 1)

            VStack(alignment: .leading, spacing: metadataSpacing) {
                Text(player.currentTrack?.name ?? "")
                    .font(titleFont)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(player.currentTrack?.artistNames ?? "")
                    .font(artistFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .contentShape(Rectangle())
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var artworkSize: CGFloat {
        presentation.isInline ? 28 : 32
    }

    private var titleFont: Font {
        .system(size: presentation.isInline ? 10 : 13, weight: .semibold)
    }

    private var artistFont: Font {
        .system(size: presentation.isInline ? 8 : 10)
    }

    private var metadataSpacing: CGFloat {
        presentation.isInline ? 2 : 3
    }

    private var nowPlayingAccessibilityLabel: String {
        let title = player.currentTrack?.name ?? String(localized: "正在播放")
        guard let artist = player.currentTrack?.artistNames, !artist.isEmpty else {
            return title
        }
        return "\(title)，\(artist)"
    }

    private var expandGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onEnded { value in
                guard NowPlayingPresentationMetrics.shouldExpandFromMiniPlayer(
                    translation: value.translation.height,
                    predictedTranslation: value.predictedEndTranslation.height
                ) else { return }
                showNowPlaying()
            }
    }

    private func showNowPlaying() {
        player.showNowPlaying = true
    }
}

// MARK: - iOS Library View

struct IOSLibraryView: View {
    @Binding var showLogin: Bool
    @EnvironmentObject private var account: AccountStore
    @ObservedObject private var layout = PlaylistLayoutStore.shared
    @Environment(\.presentSettingsSheet) private var presentSettingsSheet
    @State private var showNewPlaylist = false

    var body: some View {
        List {
            // Profile / Login header
            Section {
                SyncedLoginButtons()
                if let profile = account.profile {
                    HStack(spacing: 14) {
                        CachedAsyncImage(url: profile.avatarUrl?.resizedImageURL(128))
                            .frame(width: 52, height: 52)
                            .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(profile.nickname)
                                    .font(.headline)
                                if profile.vipType > 0 {
                                    VIPBadge()
                                }
                            }
                            if let sig = profile.signature, !sig.isEmpty {
                                Text(sig)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    Button {
                        showLogin = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.badge.plus")
                                .font(.system(size: 32))
                                .foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("登录账号")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text("同步我喜欢的音乐、歌单与每日推荐")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }

            Section {
                DestinationLink(value: Destination.downloaded) {
                    Label("已下载", systemImage: "arrow.down.circle.fill")
                }
            }

            if account.hasAuthCookie {
                Section("我的音乐") {
                    if let liked = account.likedSongsPlaylist {
                        DestinationLink(value: Destination.playlist(liked.id)) {
                            Label("我喜欢的音乐", systemImage: "heart.fill")
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    DestinationLink(value: Destination.daily) {
                        Label("每日推荐", systemImage: "calendar")
                    }
                    DestinationLink(value: Destination.recents) {
                        Label("最近播放", systemImage: "clock.fill")
                    }
                    DestinationLink(value: Destination.collections) {
                        Label("我的收藏", systemImage: "star.fill")
                    }
                    DestinationLink(value: Destination.cloud) {
                        Label("音乐云盘", systemImage: "icloud.fill")
                    }
                }

                if !account.createdPlaylists.isEmpty {
                    Section {
                        // Pinned first, then the user's own order (local pin
                        // layout); NetEase's server-side order is untouched.
                        // The context menu was lost in the 0.3.37 merge.
                        ForEach(layout.orderedCloud(account.createdPlaylists)) { playlist in
                            DestinationLink(value: Destination.playlist(playlist.id)) {
                                HStack(spacing: 10) {
                                    CachedAsyncImage(url: playlist.coverURL?.resizedImageURL(80), animated: false)
                                        .frame(width: 32, height: 32)
                                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(playlist.name)
                                            .font(.system(size: 14))
                                            .lineLimit(1)
                                        Text("\(playlist.trackCount) 首")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if layout.isPinned(cloud: playlist.id) {
                                        Image(systemName: "pin.fill")
                                            .font(.caption)
                                            .foregroundStyle(Theme.accent)
                                    }
                                }
                            }
                            .contextMenu {
                                Button {
                                    layout.togglePin(cloud: playlist.id)
                                } label: {
                                    Label(
                                        layout.isPinned(cloud: playlist.id)
                                            ? String(localized: "取消置顶")
                                            : String(localized: "置顶"),
                                        systemImage: layout.isPinned(cloud: playlist.id) ? "pin.slash" : "pin"
                                    )
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("创建的歌单")
                            Spacer()
                            Button {
                                showNewPlaylist = true
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                        }
                    }
                }

                if !account.subscribedPlaylists.isEmpty {
                    Section("收藏的歌单") {
                        ForEach(layout.orderedCloud(account.subscribedPlaylists)) { playlist in
                            DestinationLink(value: Destination.playlist(playlist.id)) {
                                HStack(spacing: 10) {
                                    CachedAsyncImage(url: playlist.coverURL?.resizedImageURL(80), animated: false)
                                        .frame(width: 32, height: 32)
                                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(playlist.name)
                                            .font(.system(size: 14))
                                            .lineLimit(1)
                                        Text("\(playlist.trackCount) 首")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if layout.isPinned(cloud: playlist.id) {
                                        Image(systemName: "pin.fill")
                                            .font(.caption)
                                            .foregroundStyle(Theme.accent)
                                    }
                                }
                            }
                            .contextMenu {
                                Button {
                                    layout.togglePin(cloud: playlist.id)
                                } label: {
                                    Label(
                                        layout.isPinned(cloud: playlist.id)
                                            ? String(localized: "取消置顶")
                                            : String(localized: "置顶"),
                                        systemImage: layout.isPinned(cloud: playlist.id) ? "pin.slash" : "pin"
                                    )
                                }
                            }
                        }
                    }
                }
            }

            Section {
                PlayerClearanceSpacer()
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("我的")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    presentSettingsSheet()
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("设置")
            }
        }
        .sheet(isPresented: $showNewPlaylist) {
            // alert-with-TextField needs iOS 16 (the field is dropped on 15),
            // so the prompt is a sheet instead.
            NamePromptSheet(
                title: "新建歌单",
                placeholder: "歌单名称",
                submitLabel: "创建"
            ) { name in
                Task {
                    do {
                        try await MusicAPI.createPlaylist(name: name, isPrivate: false)
                        await account.refreshLibrary()
                        ToastCenter.shared.show(String(localized: "歌单已创建"))
                    } catch {
                        ToastCenter.shared.show(error.localizedDescription)
                    }
                }
            }
        }
    }
}
#endif
