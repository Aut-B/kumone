import SwiftUI

#if os(iOS)
/// The iPhone now-playing lyrics with the song's comments one page to their
/// right: swipe left for the comments, right for the lyrics again. Songs
/// without a public thread (cloud uploads), or with the swipe turned off in
/// settings (#225), show the lyrics alone. A plugin track carries no lyric
/// source, so its pager only holds the comments and opens there.
struct NowPlayingLyricsPager<Lyrics: View>: View {
    private enum Page: Hashable {
        case lyrics, comments
    }

    /// Whether the lyrics are on screen. Hiding them returns to the lyrics
    /// page, so they open on the lyrics next time.
    let isShown: Bool
    /// The layout's horizontal margin. Pages slide edge to edge across it
    /// and keep it inside.
    let horizontalInset: CGFloat
    private let lyrics: Lyrics

    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var settings: SettingsManager
    @State private var page = Page.lyrics
    /// The page the current drag started on, so a turn goes one page from
    /// there even if the TabView has already moved under the finger.
    @State private var swipeStartPage: Page?
    /// Presented from here, outside the pager: a sheet raised from inside
    /// one of its pages closed again a moment later, when the pages refreshed.
    @State private var sharedComment: SharedComment?

    init(
        isShown: Bool,
        horizontalInset: CGFloat,
        @ViewBuilder lyrics: () -> Lyrics
    ) {
        self.isShown = isShown
        self.horizontalInset = horizontalInset
        self.lyrics = lyrics()
    }

    var body: some View {
        if let track = commentsTrack {
            TabView(selection: pageSelection) {
                if !hasNoLyrics {
                    lyrics
                        .padding(.horizontal, horizontalInset)
                        .tag(Page.lyrics)
                }
                // The list keeps a 16pt margin of its own.
                NowPlayingCommentsPage(track: track, isActive: isShown && currentPage == .comments) { comment in
                    sharedComment = SharedComment(track: track, comment: comment)
                }
                    .id(track.id)
                    .padding(.horizontal, max(horizontalInset - 16, 0))
                    .tag(Page.comments)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .padding(.horizontal, -horizontalInset)
            .overlay(alignment: .bottom) {
                if pages.count > 1 { pageIndicator }
            }
            .overlay(alignment: .bottomTrailing) {
                if pages.count > 1 { commentsToggle }
            }
            .sheet(item: $sharedComment) { shared in
                CommentShareSheet(track: shared.track, comment: shared.comment)
            }
            .onAppear { alignPage() }
            .onChange(of: hasNoLyrics) { _ in alignPage() }
            .onChange(of: isShown) { _ in alignPage() }
            // Simultaneous, never priority: the lyric scroll and the TabView's
            // own paging keep their gestures, and this only reads the travel.
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { _ in
                        if swipeStartPage == nil { swipeStartPage = currentPage }
                    }
                    .onEnded { value in
                        let start = swipeStartPage ?? currentPage
                        swipeStartPage = nil
                        guard PagerSwipeDecision.shouldPage(
                            dx: value.translation.width,
                            dy: value.translation.height
                        ) else { return }
                        turnPage(from: start, by: value.translation.width < 0 ? 1 : -1)
                    }
            )
        } else if hasNoLyrics {
            EmptyView()
        } else {
            lyrics
        }
    }

    private var commentsTrack: Track? {
        guard settings.swipeToComments,
              let track = player.currentTrack,
              SongCommentAvailability.isAvailable(for: track),
              !SongCommentAvailability.isShortVideoTrack(track) else { return nil }
        return track
    }

    /// A plugin track has no lyrics page at all, so the comments are the
    /// pager's first (and only) page.
    private var startsOnComments: Bool {
        hasNoLyrics && commentsTrack != nil
    }

    private var pages: [Page] {
        hasNoLyrics ? [.comments] : [.lyrics, .comments]
    }

    /// `hasNoLyrics` is only set by `startPlaying`; after a restored session
    /// the plugin tag is the remaining evidence that there is no lyric source.
    private var hasNoLyrics: Bool {
        player.hasNoLyrics || player.currentTrack?.isPluginTrack == true
    }

    /// The page actually on screen: a plugin track has no lyrics page, so it
    /// reads as comments even before the state is aligned.
    private var currentPage: Page {
        startsOnComments ? .comments : page
    }

    private var pageSelection: Binding<Page> {
        Binding(
            get: { currentPage },
            set: { page = $0 }
        )
    }

    private func alignPage() {
        let target: Page = startsOnComments ? .comments : .lyrics
        guard page != target else { return }
        withoutAnimation { page = target }
    }

    private func withoutAnimation(_ update: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, update)
    }

    /// The comments button mirrors the page it can reach: the lyrics open the
    /// comments, the comments return to the lyrics. Built only when the pager
    /// really has two pages, so it never leads to a blank page.
    private var commentsToggle: some View {
        Button(action: togglePage) {
            Image(systemName: "text.bubble")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 34, height: 34)
                .background(.white.opacity(0.12), in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, horizontalInset)
        .padding(.bottom, 6)
        .accessibilityIdentifier("nowPlayingCommentsToggle")
        .accessibilityLabel(
            currentPage == .lyrics
                ? LocalizedStringKey("查看评论")
                : LocalizedStringKey("返回歌词")
        )
    }

    private func togglePage() {
        let target: Page = currentPage == .lyrics ? .comments : .lyrics
        guard pages.contains(target) else { return }
        withoutAnimation { page = target }
    }

    /// Moves one page from where the drag began, clamped to the two pages:
    /// a long swipe on the last page never lands past it.
    private func turnPage(from start: Page, by offset: Int) {
        guard let index = pages.firstIndex(of: start) else { return }
        let target = index + offset
        guard pages.indices.contains(target) else { return }
        let destination = pages[target]
        guard destination != currentPage else { return }
        withoutAnimation { page = destination }
    }

    private var pageIndicator: some View {
        HStack(spacing: 6) {
            ForEach(pages, id: \.self) { item in
                Capsule()
                    .fill(.white.opacity(item == currentPage ? 0.8 : 0.28))
                    .frame(width: item == currentPage ? 14 : 5, height: 5)
            }
        }
        .padding(.bottom, 2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The current song's comments on the now-playing page. They load the
/// first time the page is turned to, not with every song that plays.
private struct SharedComment: Identifiable {
    let track: Track
    let comment: SongComment
    var id: Int { comment.id }
}

private struct NowPlayingCommentsPage: View {
    let track: Track
    let isActive: Bool
    let onShare: (SongComment) -> Void

    @StateObject private var content: SongCommentsContent

    init(track: Track, isActive: Bool, onShare: @escaping (SongComment) -> Void) {
        self.track = track
        self.isActive = isActive
        self.onShare = onShare
        // 用 track 路由（网易云/B站各自的评论接口）：旧的 songID 初始化器
        // 只认网易云歌曲 id，B站歌会静默抓到空评论（2026-11-25 真机反馈）。
        _content = StateObject(wrappedValue: SongCommentsContent(track: track))
    }

    var body: some View {
        SongCommentsList(track: track, content: content, onShare: onShare)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 12)
            .mask(edgeMask)
            .environment(\.colorScheme, .dark)
            .accessibilityIdentifier("nowPlayingComments")
            // Keyed to the page being shown and nothing else: keying it to the
            // phase would cancel the request it just started. Turning away
            // cancels the task, which puts an unfinished load back to idle, so
            // turning back loads again (#214).
            .task(id: isActive) {
                guard isActive else { return }
                // A quick turn away and back can find the cancelled load
                // still running; wait for it before deciding to load again.
                await content.waitForFirstPageToSettle()
                guard !Task.isCancelled, content.phase == .idle else { return }
                await content.loadFirstPage()
            }
    }

    private var edgeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.03),
                .init(color: .black, location: 0.94),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
#endif
