import Foundation
import os

/// Paging and like state for one song's comments: hot comments from the
/// first page, then the latest ones a page at a time. NetEase and Bilibili
/// share the paging shape but not the API.
@MainActor
final class SongCommentsContent: ObservableObject {
    static let log = Logger(subsystem: "sb.moe.kumone", category: "comments")

    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private enum Backend {
        case netease(songID: Int)
        case bilibili(Track)
        case unavailable
    }

    let songID: Int
    let threadID: String
    let pageSize: Int

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var hot: [SongComment] = []
    @Published private(set) var latest: [SongComment] = []
    @Published private(set) var total = 0
    @Published private(set) var hasMore = false
    @Published private(set) var isLoadingMore = false
    /// Set when a later page failed; the comments already shown stay.
    @Published private(set) var loadMoreError: String?
    @Published private(set) var pendingLikes: Set<Int> = []

    private let client: MusicClient
    /// Shared with the player's background prefetch so opening the panel can
    /// reuse the request already in flight, or its finished first page.
    private let prefetcher: NeteaseCommentPrefetcher
    private let backend: Backend
    private let session: URLSession
    /// How long a first page may stay unanswered before it is reported as a
    /// retryable failure. Injectable so tests need not wait 20 seconds.
    private let loadingDeadline: TimeInterval
    /// Bumped by every first-page load: a reply from an older one is stale.
    private var loadGeneration = 0
    /// Set when the watchdog gave up on a request; the retry must replace that
    /// request rather than join it again. A panel simply reopened after being
    /// cancelled keeps waiting on the prefetch instead.
    private var refreshFirstPageOnNextLoad = false
    private var watchdog: Task<Void, Never>?
    private var watchdogGeneration = 0
    private var nextOffset = 0
    private var nextPage = 1
    private var bilibiliAID: Int?
    private var latestIDs: Set<Int> = []

    var source: SongCommentSource {
        switch backend {
        case .netease: return .netease
        case .bilibili: return .bilibili
        case .unavailable: return .unavailable
        }
    }

    /// Bilibili's comments are read-only in this app.
    var supportsLikes: Bool { source.supportsLikes }

    /// The NetEase-only initializer, kept for callers that already hold a
    /// song id.
    init(songID: Int, pageSize: Int = 20, client: MusicClient = .shared,
         prefetcher: NeteaseCommentPrefetcher? = nil,
         loadingDeadline: TimeInterval = 20) {
        self.songID = songID
        self.threadID = MusicAPI.songCommentThread(songID: songID)
        self.pageSize = max(1, pageSize)
        self.client = client
        self.prefetcher = prefetcher ?? Self.defaultPrefetcher(for: client)
        self.loadingDeadline = loadingDeadline
        self.backend = .netease(songID: songID)
        self.session = .shared
        adoptSnapshotIfMatching()
    }

    /// Picks the backend from the track. A track with no readable comment
    /// thread starts loaded and empty, so no request is ever sent for it.
    init(track: Track, pageSize: Int = 20,
         client: MusicClient = .shared, session: URLSession = .shared,
         prefetcher: NeteaseCommentPrefetcher? = nil,
         loadingDeadline: TimeInterval = 20) {
        let source = SongCommentAvailability.source(for: track)
        self.songID = track.id
        self.threadID = source == .netease ? MusicAPI.songCommentThread(songID: track.id) : ""
        self.pageSize = max(1, pageSize)
        self.client = client
        self.prefetcher = prefetcher ?? Self.defaultPrefetcher(for: client)
        self.loadingDeadline = loadingDeadline
        self.session = session
        self.backend = Self.makeBackend(for: track)
        if source == .unavailable { phase = .loaded }
        adoptSnapshotIfMatching()
    }

    /// The shared prefetcher is only valid for the shared transport; a stub or
    /// alternate client needs its own cache or prefetch would leave the stub.
    private static func defaultPrefetcher(for client: MusicClient) -> NeteaseCommentPrefetcher {
        client === MusicClient.shared ? .shared : NeteaseCommentPrefetcher(client: client)
    }

    var isEmpty: Bool { hot.isEmpty && latest.isEmpty }

    /// The last loaded snapshot, keyed by song id: stepping to the queue and
    /// back rebuilds this object, and without the snapshot the comments the
    /// listener just read would reload from the network (#380, 瑕疵C).
    private struct Snapshot {
        let songID: Int
        let hot: [SongComment]
        let latest: [SongComment]
        let total: Int
        let nextOffset: Int
        let nextPage: Int
        let latestIDs: Set<Int>
        let hasMore: Bool
    }

    /// A first page fetched off the object. It is applied only after the
    /// generation check, so a superseded load cannot touch any published
    /// state, including the paging cursors.
    private struct FirstPage {
        let hot: [SongComment]
        let latest: [SongComment]
        let total: Int
        let nextOffset: Int
        let nextPage: Int
        let latestIDs: Set<Int>
        let hasMore: Bool
    }

    @MainActor
    private static var recentSnapshot: Snapshot?

    private func adoptSnapshotIfMatching() {
        guard let snap = Self.recentSnapshot, snap.songID == songID else { return }
        hot = snap.hot
        latest = snap.latest
        total = snap.total
        nextOffset = snap.nextOffset
        nextPage = snap.nextPage
        latestIDs = snap.latestIDs
        hasMore = snap.hasMore
        phase = .loaded
    }

    private func saveSnapshot() {
        Self.recentSnapshot = Snapshot(
            songID: songID, hot: hot, latest: latest, total: total,
            nextOffset: nextOffset, nextPage: nextPage,
            latestIDs: latestIDs, hasMore: hasMore)
    }

    /// Loads the first page, replacing whatever is shown. A no-op while it runs.
    func loadFirstPage() async {
        guard phase != .loading else { return }
        // No readable thread: show the empty state without a request.
        if case .unavailable = backend {
            phase = .loaded
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        phase = .loading
        loadMoreError = nil
        startWatchdog(for: generation)
        Self.log.info("load start song=\(self.songID) gen=\(generation) refresh=\(self.refreshFirstPageOnNextLoad)")
        var outcome = Phase.loaded
        var firstPage: FirstPage?
        do {
            switch backend {
            case .netease(let songID):
                firstPage = try await loadNeteaseFirstPage(songID: songID)
            case .bilibili(let track):
                firstPage = try await loadBilibiliFirstPage(track: track, generation: generation)
            case .unavailable:
                break
            }
        } catch is CancellationError {
            // Turning away from the page cancels its task: idle, and the view
            // reloads when it comes back (#214). A cancellation from OUTSIDE
            // this task (a song switch cancelling the shared prefetch this
            // load joined) leaves the page on screen with an idle spinner and
            // no watcher (#382): mark the prefetch stale so the view's
            // self-heal replaces it instead of rejoining the dead request.
            if !Task.isCancelled {
                refreshFirstPageOnNextLoad = true
                Self.log.info("external cancel song=\(self.songID) gen=\(generation) → self-heal reload")
            }
            outcome = .idle
        } catch let error as URLError where error.code == .cancelled {
            if !Task.isCancelled {
                refreshFirstPageOnNextLoad = true
                Self.log.info("external cancel (URL) song=\(self.songID) gen=\(generation) → self-heal reload")
            }
            outcome = .idle
        } catch {
            outcome = .failed(error.localizedDescription)
            Self.log.error("load failed song=\(self.songID) gen=\(generation): \(error.localizedDescription)")
        }
        stopWatchdog(for: generation)
        // An answer from before a retry must not overwrite the newer state:
        // not the phase and not the comments the retry has already shown.
        guard generation == loadGeneration else { return }
        if let firstPage {
            hot = firstPage.hot
            latest = firstPage.latest
            total = firstPage.total
            nextOffset = firstPage.nextOffset
            nextPage = firstPage.nextPage
            latestIDs = firstPage.latestIDs
            hasMore = firstPage.hasMore
        }
        phase = outcome
        if outcome == .loaded {
            refreshFirstPageOnNextLoad = false
            saveSnapshot()
            Self.log.info("load done song=\(self.songID) hot=\(self.hot.count) latest=\(self.latest.count) more=\(self.hasMore)")
        }
    }

    /// Waits for an in-flight first page to settle. A page turned away and
    /// straight back can find the cancelled load still `.loading`; without
    /// this the new task would skip its load and leave the spinner up.
    func waitForFirstPageToSettle() async {
        while phase == .loading, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Ends a first page that never answers: a stalled socket would otherwise
    /// leave the spinner up forever. The watchdog belongs to one generation
    /// and stands down once that load finishes, fails or is retried.
    private func startWatchdog(for generation: Int) {
        watchdog?.cancel()
        watchdogGeneration = generation
        let nanoseconds = UInt64(max(0, loadingDeadline) * 1_000_000_000)
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.watchdogExpired(for: generation)
        }
    }

    private func watchdogExpired(for generation: Int) {
        guard generation == loadGeneration, phase == .loading else { return }
        watchdog = nil
        refreshFirstPageOnNextLoad = true
        phase = .failed(String(localized: "评论加载超时，请重试"))
        Self.log.error("watchdog expired song=\(self.songID) gen=\(generation) → retryable failure")
    }

    private func stopWatchdog(for generation: Int) {
        guard generation == watchdogGeneration else { return }
        watchdog?.cancel()
        watchdog = nil
    }

    /// Appends the next page of latest comments, skipping ones already shown.
    func loadMore() async {
        guard phase == .loaded, hasMore, !isLoadingMore else { return }
        switch backend {
        case .netease(let songID):
            await performMoreLoad { try await self.loadNeteaseMore(songID: songID) }
        case .bilibili(let track):
            await performMoreLoad { try await self.loadBilibiliMore(track: track) }
        case .unavailable:
            return
        }
    }

    private func performMoreLoad(_ load: () async throws -> Void) async {
        isLoadingMore = true
        loadMoreError = nil
        defer { isLoadingMore = false }
        do {
            try await load()
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            loadMoreError = error.localizedDescription
        }
    }

    private func loadNeteaseFirstPage(songID: Int) async throws -> FirstPage {
        let page: SongCommentsPage
        if refreshFirstPageOnNextLoad {
            refreshFirstPageOnNextLoad = false
            // A retry replaces a prefetch the watchdog already stopped waiting
            // for; otherwise it would join that same stalled request forever.
            page = try await prefetcher.refreshPage(songID: songID, limit: pageSize)
        } else {
            page = try await prefetcher.page(songID: songID, limit: pageSize)
        }
        try Task.checkCancellation()
        var hotIDs: Set<Int> = []
        let hot = page.hot.filter { hotIDs.insert($0.id).inserted }
        var latestIDs: Set<Int> = []
        let latest = page.latest.filter { latestIDs.insert($0.id).inserted }
        return FirstPage(
            hot: hot, latest: latest, total: page.total,
            nextOffset: pageSize, nextPage: 1, latestIDs: latestIDs,
            hasMore: page.more && !page.latest.isEmpty)
    }

    private func loadNeteaseMore(songID: Int) async throws {
        let page = try await MusicAPI.songComments(songID: songID, limit: pageSize, offset: nextOffset,
                                                   using: client)
        let fresh = page.latest.filter { latestIDs.insert($0.id).inserted }
        latest.append(contentsOf: fresh)
        if page.total > 0 { total = page.total }
        nextOffset += pageSize
        // A page with nothing new would only be asked for again.
        hasMore = page.more && !fresh.isEmpty
    }

    /// Fetches the Bilibili first page. Hot and latest start together; a
    /// non-empty hot page is published the moment it lands instead of waiting
    /// for the slower latest page. Latest then fills in behind it (#381).
    ///
    /// Returns `nil` when hot was already published and the rest of the page
    /// could not be used: those hot comments stay on screen. A superseded
    /// generation is also returned as `nil` so the caller leaves every
    /// published value alone.
    private func loadBilibiliFirstPage(track: Track, generation: Int) async throws -> FirstPage? {
        let aid = try await bilibiliAID(for: track)
        try Task.checkCancellation()
        // The two orderings are independent requests. Serially they doubled
        // the first-comment wait on a slow A9 (6S, #380): run them together.
        async let hotPageTask = BilibiliComments.fetchPage(
            oid: aid, page: 1, pageSize: pageSize, sort: .hot, using: session)
        async let latestPageTask = BilibiliComments.fetchPage(
            oid: aid, page: 1, pageSize: pageSize, sort: .time, using: session)

        var hotPage: SongCommentsPage?
        var hotFailure: Error?
        do {
            hotPage = try await hotPageTask
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw error
        } catch {
            hotFailure = error
        }

        var hotComments: [SongComment] = []
        var hotPublished = false
        if let hotPage {
            // A retried load owns the screen now; this answer is stale.
            guard generation == loadGeneration else { return nil }
            try Task.checkCancellation()
            var hotIDs: Set<Int> = []
            hotComments = hotPage.hot.filter { hotIDs.insert($0.id).inserted }
            if !hotComments.isEmpty {
                hot = hotComments
                if hotPage.total > 0 { total = hotPage.total }
                phase = .loaded
                stopWatchdog(for: generation)
                hotPublished = true
            }
        }

        do {
            let latestPage = try await latestPageTask
            guard generation == loadGeneration else { return nil }
            var latestIDs: Set<Int> = []
            let latest = latestPage.latest.filter { latestIDs.insert($0.id).inserted }
            return FirstPage(
                hot: hotComments, latest: latest,
                total: latestPage.total > 0 ? latestPage.total : hotPage?.total ?? 0,
                nextOffset: 0, nextPage: 2, latestIDs: latestIDs,
                hasMore: latestPage.more && !latestPage.latest.isEmpty)
        } catch is CancellationError {
            if hotPublished { return nil }
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            if hotPublished { return nil }
            throw error
        } catch {
            if hotPublished { return nil }
            throw hotFailure ?? error
        }
    }

    private func loadBilibiliMore(track: Track) async throws {
        let aid = try await bilibiliAID(for: track)
        // Bilibili's hot ordering only fills the first page; later pages are
        // time-ordered.
        let page = try await BilibiliComments.fetchPage(oid: aid, page: nextPage, pageSize: pageSize,
                                                        sort: .time, using: session)
        let fresh = page.latest.filter { latestIDs.insert($0.id).inserted }
        latest.append(contentsOf: fresh)
        if page.total > 0 { total = page.total }
        nextPage += 1
        hasMore = page.more && !fresh.isEmpty
    }

    private func bilibiliAID(for track: Track) async throws -> Int {
        if let bilibiliAID { return bilibiliAID }
        if let aid = BilibiliComments.aid(for: track) {
            bilibiliAID = aid
            return aid
        }
        guard let bvid = BilibiliComments.bvid(for: track) else {
            throw MusicAPIError.business(code: 400, message: String(localized: "这个视频没有可用的评论 id"))
        }
        let aid = try await BilibiliComments.resolveAID(bvid: bvid, using: session)
        bilibiliAID = aid
        return aid
    }

    private static func makeBackend(for track: Track) -> Backend {
        switch SongCommentAvailability.source(for: track) {
        case .netease:
            return .netease(songID: track.id)
        case .bilibili:
            return .bilibili(track)
        case .unavailable:
            return .unavailable
        }
    }

    /// Retries whatever failed last: the first page, or the next one.
    func retry() async {
        if case .failed = phase {
            await loadFirstPage()
        } else if loadMoreError != nil {
            await loadMore()
        }
    }

    func comment(id: Int) -> SongComment? {
        hot.first(where: { $0.id == id }) ?? latest.first(where: { $0.id == id })
    }

    /// Likes or unlikes a comment at once, and puts it back if the service
    /// refuses. Rethrows that refusal for the caller to report.
    func toggleLike(commentID: Int) async throws {
        guard supportsLikes else { return }
        guard !pendingLikes.contains(commentID), let current = comment(id: commentID) else { return }
        let like = !current.liked
        pendingLikes.insert(commentID)
        defer { pendingLikes.remove(commentID) }
        apply(commentID: commentID, liked: like)
        do {
            try await MusicAPI.likeComment(threadID: threadID, commentID: commentID, like: like, using: client)
        } catch {
            apply(commentID: commentID, liked: !like)
            throw error
        }
    }

    /// The same comment can be both hot and latest; both rows follow.
    private func apply(commentID: Int, liked: Bool) {
        func update(_ list: inout [SongComment]) {
            for index in list.indices where list[index].id == commentID && list[index].liked != liked {
                list[index].liked = liked
                list[index].likedCount = max(0, list[index].likedCount + (liked ? 1 : -1))
            }
        }
        update(&hot)
        update(&latest)
    }
}
