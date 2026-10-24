import SwiftUI


struct PlaylistDetailView: View {
    let playlistID: Int
    var isLikedList = false
    var recommendationContext: RecommendationContext?

    @StateObject private var model: PlaylistContent
    @ObservedObject private var downloads = DownloadManager.shared
    // This page only sends playback commands; individual rows observe playback.
    private let player = PlayerService.shared
    @EnvironmentObject private var account: AccountStore
    @ObservedObject private var layout = PlaylistLayoutStore.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showFullDescription = false
    @State private var multiSelectMode = false
    @State private var selectedIDs: Set<Int> = []
    @State private var sorting = false
    @State private var showCollect = false
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    #if os(iOS)
    @State private var showSearch = false
    @State private var searchFocused = false
    #endif

    init(playlistID: Int, isLikedList: Bool = false, recommendationContext: RecommendationContext? = nil) {
        self.playlistID = playlistID
        self.isLikedList = isLikedList
        self.recommendationContext = recommendationContext
        _model = StateObject(wrappedValue: PlaylistContent(playlistID: playlistID))
    }

    private var isOwnPlaylist: Bool {
        model.detail?.creator?.userId == account.profile?.userId
    }

    private var isCompact: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone || horizontalSizeClass == .compact
        #else
        return false
        #endif
    }

    /// Search inside the list. Upstream gated this on the liked-songs list
    /// only; finding a song matters just as much in a long collected
    /// playlist, so every playlist gets it.
    private var supportsPlaylistSearch: Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }

    private var isSearchActive: Bool {
        #if os(iOS)
        return supportsPlaylistSearch && showSearch
        #else
        return false
        #endif
    }

    private var activeQuery: String {
        model.filter.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ScrollViewReader { proxy in
            onlineContent
                .task(id: "\(playlistID):\(account.offlineScope ?? ""):\(downloads.network.isKnown):\(downloads.network.connected)") {
                    await loadPlaylist()
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        if model.errorMessage != nil, downloads.network.connected, model.detail != nil {
                            Button { Task { await loadPlaylist() } } label: { Image(systemName: "arrow.clockwise") }
                                .accessibilityLabel("重试")
                                .help("重试")
                        }
                    }
                    #if os(iOS)
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            toggleMultiSelect()
                        } label: {
                            Image(systemName: multiSelectMode ? "xmark.circle" : "checklist")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .accessibilityLabel(multiSelectMode ? "退出多选" : "多选")
                        .disabled(model.detail == nil || sorting)
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu {
                            if !isSearchActive {
                                Button {
                                    withAnimation(AppAnimation.standard) {
                                        showSearch = true
                                        proxy.scrollTo("playlistTop", anchor: .top)
                                    }
                                    searchFocused = true
                                } label: {
                                    Label("在歌单内查找", systemImage: "magnifyingglass")
                                }
                            }
                            Button {
                                toggleMultiSelect()
                            } label: {
                                Label(multiSelectMode ? "退出多选" : "多选", systemImage: "checklist")
                            }
                            Button {
                                sorting.toggle()
                                if sorting {
                                    multiSelectMode = false
                                    selectedIDs.removeAll()
                                }
                            } label: {
                                Label(sorting ? "完成排序" : "调整歌曲顺序",
                                      systemImage: sorting ? "checkmark" : "arrow.up.arrow.down")
                            }
                            .disabled(model.tracks.count < 2)
                            Menu {
                                Picker("排序方式", selection: $model.sortOrder) {
                                    ForEach(PlaylistTrackSort.allCases, id: \.self) { order in
                                        Text(LocalizedStringKey(order.rawValue)).tag(order)
                                    }
                                }
                            } label: {
                                Label("排序方式", systemImage: "arrow.up.arrow.down")
                            }
                            Button {
                                layout.clearTrackOrder(playlistID: playlistID)
                            } label: {
                                Label("恢复默认顺序", systemImage: "arrow.uturn.left")
                            }
                            .disabled(!layout.hasCustomTrackOrder(playlistID: playlistID))
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("更多")
                        .disabled(model.detail == nil)
                    }
                    #endif
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
                        Task { await deleteSelected() }
                    }
                    Button("取消", role: .cancel) {}
                }
        }
    }

    private func loadPlaylist() async {
        await model.load(allowNetwork: !downloads.network.isKnown || downloads.network.connected,
                         summary: account.userPlaylists.first { $0.id == playlistID })
    }

    @ViewBuilder
    private var onlineContent: some View {
        #if os(macOS)
        Group {
            if model.loadedScope == account.offlineScope, let detail = model.detail {
                let tracks = model.filteredTracks
                TrackTable(
                    trackIDs: tracks.map(\.id),
                    header: AnyView(regularHeader(detail)
                        .padding(.horizontal, Theme.Layout.contentInset)
                        .padding(.top, 16)
                        .padding(.bottom, 20)),
                    footer: AnyView(VStack(spacing: 20) {
                        playlistStatus(detail)
                        PlayerClearanceSpacer()
                    }.padding(.top, 20)),
                    headerHeight: 246,
                    footerHeight: desktopFooterHeight(detail)
                ) { index in
                    AnyView(trackList(tracks, layout: .singleRow(index))
                        .padding(.horizontal, Theme.Layout.contentInset - 10))
                }
            } else {
                ScrollView { playlistContents }
            }
        }
        .clipped()
        .navigationTitle(model.detail?.name ?? String(localized: "歌单"))
        #else
        Group {
            if sorting {
                reorderList
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: isCompact ? 16 : 20) {
                        playlistContents
                    }
                    .id("playlistTop")
                    #if os(iOS)
                    .background {
                        if supportsPlaylistSearch {
                            PlaylistSearchScrollGesture(isSearchActive: showSearch, onPullDown: {
                                withAnimation(AppAnimation.standard) { showSearch = true }
                                searchFocused = true
                            }, onScrollUp: {
                                searchFocused = false
                                withAnimation(AppAnimation.standard) { showSearch = false }
                            })
                        }
                    }
                    #endif
                }
                .safeAreaInset(edge: .top) {
                    // Pinned under the navigation bar, not at the bottom: the
                    // floating mini player would otherwise cover it.
                    if multiSelectMode {
                        VStack(spacing: 0) {
                            PlaylistSelectionSummaryBar(
                                selectedCount: selectedIDs.count,
                                totalCount: visibleTracks.count,
                                onToggleAll: toggleSelectAll
                            )
                            Divider().opacity(0.4)
                            PlaylistSelectionActionBar(
                                selectedCount: selectedIDs.count,
                                canDelete: isOwnPlaylist,
                                onPlayNext: playSelectedNext,
                                onQueueEnd: queueSelectedAtEnd,
                                onCollect: { showCollect = true },
                                onDelete: { showDeleteConfirm = true }
                            )
                            Divider().opacity(0.4)
                        }
                        .background(.bar)
                    }
                }
            }
        }
        .navigationTitle(isSearchActive ? String(localized: "搜索歌单内歌曲") : "")
        .navigationBarTitleDisplayMode(.inline)
        .compatScrollDismissesKeyboardInteractively()
        #endif
    }

    #if os(macOS)
    private func desktopFooterHeight(_ detail: PlaylistDetail) -> CGFloat {
        let clearance = Theme.Layout.playerChromeClearance + Theme.Layout.scrollBreathingMargin + 20
        if model.isLoading || model.isLoadingMore { return clearance + 60 }
        if model.tracks.isEmpty { return clearance + 100 }
        if model.tracks.count < detail.trackCount { return clearance + 40 }
        return clearance
    }
    #endif

    private func trackList(_ tracks: [Track], layout: TrackListView.Layout = .stack) -> some View {
        TrackListView(
            tracks: tracks,
            privileges: model.privileges,
            source: .playlist(playlistID),
            context: model.detail.map { .playlist(id: playlistID, name: $0.name) },
            removableFromPlaylistID: isOwnPlaylist ? playlistID : nil,
            onRemoved: { track in Task { await model.remove(track) } },
            recommendationContext: recommendationContext,
            onRecommendationReduced: { model.replaceRecommendation($0, with: $1) },
            layout: layout
        )
    }

    @ViewBuilder
    private var playlistContents: some View {
        if model.loadedScope == account.offlineScope, let detail = model.detail {
            let filteredTracks = model.filteredTracks
            if !isSearchActive {
                if isCompact {
                    compactHeader(detail)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                } else {
                    regularHeader(detail)
                        .padding(.horizontal, Theme.Layout.contentInset)
                        .padding(.top, 16)
                }
            }

            #if os(iOS)
            if isSearchActive {
                HStack(spacing: 4) {
                    PlaylistSearchField(text: $model.filter, isFocused: $searchFocused)
                    Button("取消") {
                        model.filter = ""
                        searchFocused = false
                        withAnimation(AppAnimation.standard) { showSearch = false }
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 8)
                }
                .frame(height: 52)
                .padding(.horizontal, isCompact ? 8 : Theme.Layout.contentInset - 8)
                .padding(.top, 8)
                .transition(.opacity)
            }

            if supportsPlaylistSearch && !model.filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack {
                    Text("找到 \(filteredTracks.count) 首匹配歌曲")
                    if !isSearchActive {
                        Spacer()
                        Button("清空搜索") { model.filter = "" }
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, isCompact ? 16 : Theme.Layout.contentInset)

                if filteredTracks.isEmpty && !model.isLoadingMore && model.errorMessage == nil {
                    EmptyStateView(icon: "magnifyingglass", title: "没有匹配的歌曲",
                                   subtitle: "试试其他歌名、歌手或专辑")
                        .frame(minHeight: 180)
                }
            }
            #endif

            if multiSelectMode {
                LazyVStack(spacing: 1) {
                    ForEach(visibleTracks) { track in
                        selectableRow(track)
                    }
                }
                .padding(.horizontal, isCompact ? 6 : Theme.Layout.contentInset - 10)
            } else {
                trackList(visibleTracks)
                    .padding(.horizontal, isCompact ? 6 : Theme.Layout.contentInset - 10)
            }

            playlistStatus(detail)
        } else if model.isLoading {
            loadingHeader
        } else if let message = model.errorMessage {
            ErrorStateView(message: message) {
                Task { await loadPlaylist() }
            }
            .frame(minHeight: 400)
        } else {
            EmptyStateView(icon: "music.note.list", title: "联网后载入歌曲")
                .frame(minHeight: 400)
        }
        PlayerClearanceSpacer()
    }

    @ViewBuilder
    private func playlistStatus(_ detail: PlaylistDetail) -> some View {
        if model.isLoading || model.isLoadingMore {
            HStack {
                Spacer()
                ProgressView().controlSize(.small)
                #if os(iOS)
                if supportsPlaylistSearch {
                    Text("正在加载歌单，搜索结果会继续更新…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                #endif
                Spacer()
            }
            .padding(.vertical, 12)
        } else if model.tracks.isEmpty {
            Text(detail.trackCount == 0 ? String(localized: "歌单暂无歌曲") : String(localized: "联网后载入歌曲"))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
        } else if model.tracks.count < detail.trackCount {
            Text("已载入 \(model.tracks.count)/\(detail.trackCount) 首")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, isCompact ? 16 : Theme.Layout.contentInset)
        }

        #if os(iOS)
        if supportsPlaylistSearch, model.tracks.count < detail.trackCount, let message = model.errorMessage {
            VStack(spacing: 8) {
                Text("歌单未完整加载，搜索结果可能不完整")
                    .font(.subheadline)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("重试") { Task { await loadPlaylist() } }
                    .buttonStyle(.bordered)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, isCompact ? 16 : Theme.Layout.contentInset)
        }
        #endif
    }

    // MARK: - Multi-select

    /// The list as shown: filtered, then re-ordered by the local layout.
    private var visibleTracks: [Track] {
        layout.orderedTracks(model.filteredTracks, playlistID: playlistID)
    }

    private var selectedTracks: [Track] {
        visibleTracks.filter { selectedIDs.contains($0.id) }
    }

    /// A plain row while selecting — tapping toggles the checkbox instead of
    /// starting playback, and the title is explicitly `.primary` so it isn't
    /// painted in the accent colour.
    private func selectableRow(_ track: Track) -> some View {
        HStack(spacing: 10) {
            SelectionCheckmark(isSelected: selectedIDs.contains(track.id))
            CachedAsyncImage(url: track.album.picUrl?.resizedImageURL(160), animated: false) {
                Rectangle().fill(Color.secondary.opacity(0.12))
            }
            .frame(width: 42, height: 42)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(track.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(track.artistNames)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle(track) }
    }

    private func toggle(_ track: Track) {
        if selectedIDs.contains(track.id) {
            selectedIDs.remove(track.id)
        } else {
            selectedIDs.insert(track.id)
        }
    }

    private func toggleSelectAll() {
        let ids = Set(visibleTracks.map(\.id))
        if !ids.isEmpty && selectedIDs == ids {
            selectedIDs.removeAll()
        } else {
            selectedIDs = ids
        }
    }

    private func toggleMultiSelect() {
        multiSelectMode.toggle()
        selectedIDs.removeAll()
    }

    private func playSelectedNext() {
        let tracks = selectedTracks
        guard !tracks.isEmpty else { return }
        player.addToPlayNext(tracks)
        selectedIDs.removeAll()
        multiSelectMode = false
    }

    /// "Play these after whatever I am listening to right now" — the Beans
    /// behaviour, as opposed to cutting in after the current song.
    private func queueSelectedAtEnd() {
        let tracks = selectedTracks
        guard !tracks.isEmpty else { return }
        player.addToQueueEnd(tracks)
        selectedIDs.removeAll()
        multiSelectMode = false
    }

    private func deleteSelected() async {
        let ids = selectedIDs
        guard !ids.isEmpty, isOwnPlaylist else { return }
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await NeteaseAPI.playlistTracks(op: "del", playlistID: playlistID, trackIDs: ids.sorted())
            await model.remove(ids: ids)
            selectedIDs.removeAll()
            multiSelectMode = false
            ToastCenter.shared.show(String(localized: "已从歌单中移除 \(ids.count) 首"))
        } catch {
            ToastCenter.shared.show(error.localizedDescription)
        }
    }

    // MARK: - Reordering

    /// NetEase offers no API to reorder a playlist's tracks, so this writes a
    /// local view order: it changes what you see and play here, not the server.
    private var reorderList: some View {
        List {
            ForEach(visibleTracks) { track in
                HStack(spacing: 10) {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(.secondary)
                    Text(track.name)
                        .lineLimit(1)
                    Spacer()
                    Text(track.artistNames)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .onMove { offsets, destination in
                var list = visibleTracks
                list.move(fromOffsets: offsets, toOffset: destination)
                layout.setTrackOrder(list, playlistID: playlistID)
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, .constant(.active))
    }

    // MARK: - Compact (Mobile) Header

    private func compactHeader(_ detail: PlaylistDetail) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                CachedAsyncImage(url: detail.coverImgUrl?.resizedImageURL(384))
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous))
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 4)

                VStack(alignment: .leading, spacing: 6) {
                    Text(isLikedList ? String(localized: "我喜欢的音乐") : detail.name)
                        .font(.system(size: 16, weight: .bold))
                        .lineLimit(3)

                    if let creator = detail.creator, !isLikedList {
                        HStack(spacing: 6) {
                            CachedAsyncImage(url: creator.avatarUrl?.resizedImageURL(48), animated: false)
                                .frame(width: 18, height: 18)
                                .clipShape(Circle())
                            Text(creator.nickname)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Text("\(detail.trackCount) 首 · \(Formatters.playCount(detail.playCount)) 次播放")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if let description = detail.description, !description.isEmpty {
                Button {
                    showFullDescription = true
                } label: {
                    HStack(spacing: 4) {
                        Text(description.replacingOccurrences(of: "\n", with: " "))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showFullDescription) {
                    AppNavStack {
                        ScrollView {
                            Text(description)
                                .font(.system(size: 14))
                                .padding(20)
                        }
                        .navigationTitle("歌单简介")
                        #if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                        .toolbar {
                            ToolbarItem(placement: .primaryAction) {
                                Button("完成") { showFullDescription = false }
                            }
                        }
                    }
                }
            }

            // Compact Action Bar
            HStack(spacing: 10) {
                Button {
                    player.play(tracks: playable, source: .playlist(playlistID),
                                context: model.detail.map { .playlist(id: playlistID, name: $0.name) })
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                        Text("播放全部 (\(playable.count))")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Theme.accentGradient, in: Capsule())
                    .shadow(color: Theme.accent.opacity(0.3), radius: 6, y: 2)
                }
                .buttonStyle(.pressable)
                .disabled(playable.isEmpty)

                downloadButton(detail, compact: true)

                if isLikedList {
                    Button {
                        startHeartbeat()
                    } label: {
                        Image(systemName: "heart.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 38, height: 38)
                            .background(.primary.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.pressable)
                } else if !isOwnPlaylist, account.isLoggedIn {
                    Button {
                        toggleSubscribe(detail)
                    } label: {
                        Image(systemName: detail.subscribed ? "checkmark" : "plus")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(detail.subscribed ? Theme.accent : .primary)
                            .frame(width: 38, height: 38)
                            .background(.primary.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.pressable)
                }
            }
        }
    }

    // MARK: - Regular (Desktop / iPad) Header

    private func regularHeader(_ detail: PlaylistDetail) -> some View {
        HStack(alignment: .bottom, spacing: 24) {
            CachedAsyncImage(url: detail.coverImgUrl?.resizedImageURL(512))
                .frame(width: 200, height: 200)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 16, y: 8)

            VStack(alignment: .leading, spacing: 8) {
                Text(isLikedList ? String(localized: "我喜欢的音乐") : String(localized: "歌单"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(detail.name)
                    .font(.title.weight(.bold))
                    .lineLimit(2)

                if let creator = detail.creator {
                    HStack(spacing: 6) {
                        CachedAsyncImage(url: creator.avatarUrl?.resizedImageURL(48), animated: false)
                            .frame(width: 18, height: 18)
                            .clipShape(Circle())
                        Text(creator.nickname)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                Text("\(detail.trackCount) 首 · \(Formatters.playCount(detail.playCount)) 次播放 · 更新于 \(Formatters.date(fromMS: detail.updateTime))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)

                if let description = detail.description, !description.isEmpty {
                    Button {
                        showFullDescription = true
                    } label: {
                        Text(description.replacingOccurrences(of: "\n", with: " "))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showFullDescription, arrowEdge: .bottom) {
                        ScrollView {
                            Text(description)
                                .font(.system(size: 13))
                                .padding(16)
                                .frame(width: 380, alignment: .leading)
                        }
                        .frame(maxHeight: 400)
                    }
                }

                Spacer(minLength: 4)

                actionRow(detail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 210)
    }

    private func actionRow(_ detail: PlaylistDetail) -> some View {
        HStack(spacing: 10) {
            Button {
                player.play(tracks: playable, source: .playlist(playlistID),
                            context: .playlist(id: playlistID, name: detail.name))
            } label: {
                Label("播放全部", systemImage: "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Theme.accentGradient, in: Capsule())
                    .shadow(color: Theme.accent.opacity(0.3), radius: 6, y: 2)
            }
            .buttonStyle(.pressable)
            .disabled(playable.isEmpty)

            if isLikedList {
                Button {
                    startHeartbeat()
                } label: {
                    Label("心动模式", systemImage: "heart.circle")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.primary.opacity(0.06), in: Capsule())
                }
                .buttonStyle(.pressable)
            } else if !isOwnPlaylist, account.isLoggedIn {
                Button {
                    toggleSubscribe(detail)
                } label: {
                    Label(detail.subscribed ? String(localized: "已收藏") : String(localized: "收藏"),
                          systemImage: detail.subscribed ? "checkmark" : "plus")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.primary.opacity(0.06), in: Capsule())
                }
                .buttonStyle(.pressable)
            }

            downloadButton(detail)

            #if os(macOS)
            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("搜索歌单内歌曲", text: $model.filter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 130)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.primary.opacity(0.05), in: Capsule())
            #endif
        }
    }

    private var playable: [Track] {
        // 同 TrackList.playableTracks：备份里的原始 fee/privilege 与账号无关，
        // 按版权过滤会砍短播放队列，改为全量入队。
        let tracks = model.orderedTracks
        if SettingsManager.shared.canResolveUnblockedTracks { return tracks }
        return tracks
    }

    private func startHeartbeat() {
        Task {
            guard let seed = playable.randomElement() else { return }
            do {
                let tracks = try await NeteaseAPI.intelligenceList(songID: seed.id, playlistID: playlistID)
                guard !tracks.isEmpty else {
                    ToastCenter.shared.show(String(localized: "心动模式暂时不可用"))
                    return
                }
                player.play(tracks: tracks, source: .playlist(playlistID), context: .heartbeat)
                ToastCenter.shared.show(String(localized: "已开启心动模式"))
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

    private func toggleSubscribe(_ detail: PlaylistDetail) {
        Task {
            do {
                try await NeteaseAPI.subscribePlaylist(id: detail.id, subscribe: !detail.subscribed)
                model.detail?.subscribed.toggle()
                await account.refreshLibrary()
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

    private func downloadButton(_ detail: PlaylistDetail, compact: Bool = false) -> some View {
        DownloadCollectionButton(tracks: model.tracks, owner: "playlist:\(playlistID)", name: detail.name,
                                 enabled: model.canDownloadAll, compact: compact)
            .accessibilityHint("等待歌单完整加载后下载全部歌曲")
    }

    private var loadingHeader: some View {
        HStack(alignment: .top, spacing: isCompact ? 14 : 24) {
            SkeletonView(cornerRadius: isCompact ? Theme.Radius.standard : Theme.Radius.large)
                .frame(width: isCompact ? 120 : 200, height: isCompact ? 120 : 200)

            VStack(alignment: .leading, spacing: 10) {
                SkeletonView(cornerRadius: 4).frame(width: 80, height: 14)
                SkeletonView(cornerRadius: 4).frame(maxWidth: isCompact ? 160 : 220, minHeight: 14, maxHeight: 14)
                SkeletonView(cornerRadius: 4).frame(width: 120, height: 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, isCompact ? 16 : Theme.Layout.contentInset)
        .padding(.top, isCompact ? 12 : 16)
    }
}
