import SwiftUI

@MainActor
final class PlaylistDetailViewModel: ObservableObject {
    let playlistID: Int
    @Published var detail: PlaylistDetail?
    @Published var tracks: [Track] = [] {
        didSet { orderedTracks = sortOrder.sorted(tracks) }
    }
    @Published var sortOrder: PlaylistTrackSort = .addedNewestFirst {
        didSet { orderedTracks = sortOrder.sorted(tracks) }
    }
    private(set) var orderedTracks: [Track] = []
    @Published var privileges: [Int: TrackPrivilege] = [:]
    @Published var isLoading = true
    @Published var isLoadingMore = false
    @Published var errorMessage: String?
    @Published var filter = ""
    private var reducedRecommendationIDs: Set<Int> = []

    init(playlistID: Int) {
        self.playlistID = playlistID
    }

    var filteredTracks: [Track] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return orderedTracks }
        return orderedTracks.filter {
            $0.name.localizedStandardContains(query)
                || $0.artistNames.localizedStandardContains(query)
                || $0.album.name.localizedStandardContains(query)
        }
    }

    func load() async {
        isLoading = tracks.isEmpty
        errorMessage = nil
        do {
            let response = try await NeteaseAPI.playlistDetail(id: playlistID)
            try Task.checkCancellation()
            detail = response.playlist
            tracks = response.playlist.tracks.filter { !reducedRecommendationIDs.contains($0.id) }
            merge(privileges: response.privileges)
            isLoading = false
            try await loadRemainingTracks()
        } catch {
            isLoading = false
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func loadRemainingTracks() async throws {
        guard let detail else { return }
        let loadedIDs = Set(tracks.map(\.id)).union(reducedRecommendationIDs)
        let remaining = detail.trackIds.map(\.id).filter { !loadedIDs.contains($0) }
        guard !remaining.isEmpty else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        for offset in stride(from: 0, to: remaining.count, by: 500) {
            let chunk = Array(remaining[offset..<min(offset + 500, remaining.count)])
            let response = try await NeteaseAPI.songDetails(ids: chunk)
            try Task.checkCancellation()
            tracks += response.songs.filter { !reducedRecommendationIDs.contains($0.id) }
            merge(privileges: response.privileges)
        }
    }

    private func merge(privileges list: [TrackPrivilege]?) {
        for privilege in list ?? [] {
            privileges[privilege.id] = privilege
        }
    }

    func remove(_ track: Track) {
        tracks.removeAll { $0.id == track.id }
    }

    /// Batch removal: one network call already deleted them on the server, so
    /// the local list just drops every id at once.
    func remove(ids: Set<Int>) {
        tracks.removeAll { ids.contains($0.id) }
    }

    func replaceRecommendation(_ rejected: Track, with replacement: Track) {
        if tracks.replaceRecommendation(rejected, with: replacement) {
            reducedRecommendationIDs.insert(rejected.id)
        }
    }
}

struct PlaylistDetailView: View {
    let playlistID: Int
    var isLikedList = false
    var recommendationContext: RecommendationContext?

    @StateObject private var model: PlaylistDetailViewModel
    @EnvironmentObject private var player: PlayerService
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
        _model = StateObject(wrappedValue: PlaylistDetailViewModel(playlistID: playlistID))
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
            Group {
                if sorting {
                    reorderList
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: isCompact ? 16 : 20) {
                            if let detail = model.detail {
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

                                if !activeQuery.isEmpty {
                                    HStack {
                                        Text("找到 \(visibleTracks.count) 首匹配歌曲")
                                        if !isSearchActive {
                                            Spacer()
                                            Button("清空搜索") { model.filter = "" }
                                        }
                                    }
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, isCompact ? 16 : Theme.Layout.contentInset)

                                    if visibleTracks.isEmpty && !model.isLoadingMore && model.errorMessage == nil {
                                        EmptyStateView(icon: "magnifyingglass", title: "没有匹配的歌曲",
                                                       subtitle: "试试其他歌名、歌手或专辑")
                                            .frame(minHeight: 180)
                                    }
                                }
                                #endif

                                Group {
                                    if multiSelectMode {
                                        LazyVStack(spacing: 1) {
                                            ForEach(visibleTracks) { track in
                                                selectableRow(track)
                                            }
                                        }
                                    } else {
                                        TrackListView(
                                            tracks: visibleTracks,
                                            privileges: model.privileges,
                                            source: .playlist(playlistID),
                                            context: model.detail.map { .playlist(id: playlistID, name: $0.name) },
                                            removableFromPlaylistID: isOwnPlaylist ? playlistID : nil,
                                            onRemoved: { model.remove($0) },
                                            recommendationContext: recommendationContext,
                                            onRecommendationReduced: { model.replaceRecommendation($0, with: $1) }
                                        )
                                    }
                                }
                                .padding(.horizontal, isCompact ? 6 : Theme.Layout.contentInset - 10)

                                if model.isLoadingMore {
                                    HStack {
                                        Spacer()
                                        ProgressView().controlSize(.small)
                                        Spacer()
                                    }
                                    .padding(.vertical, 12)
                                }
                            } else if model.isLoading {
                                loadingHeader
                            } else if let message = model.errorMessage {
                                ErrorStateView(message: message) {
                                    Task { await model.load() }
                                }
                                .frame(minHeight: 400)
                            }
                            PlayerClearanceSpacer()
                        }
                        .id("playlistTop")
                        #if os(iOS)
                        .background {
                            PlaylistSearchScrollGesture(isSearchActive: showSearch, onPullDown: {
                                withAnimation(AppAnimation.standard) { showSearch = true }
                                searchFocused = true
                            }, onScrollUp: {
                                searchFocused = false
                                withAnimation(AppAnimation.standard) { showSearch = false }
                            })
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
            #if os(macOS)
            .navigationTitle(model.detail?.name ?? String(localized: "歌单"))
            #else
            .navigationTitle(isSearchActive ? String(localized: "搜索歌单内歌曲") : "")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
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
            }
            #endif
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
            .task(id: playlistID) {
                await model.load()
            }
        }
        }
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
            model.remove(ids: ids)
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

                if !isLikedList && !isOwnPlaylist, account.isLoggedIn {
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
        let tracks = model.orderedTracks
        if SettingsManager.shared.canResolveUnblockedTracks { return tracks }
        return tracks.filter {
            $0.playability(privilege: model.privileges[$0.id],
                           isLoggedIn: account.isLoggedIn,
                           vipType: account.vipType) == .playable
        }
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
