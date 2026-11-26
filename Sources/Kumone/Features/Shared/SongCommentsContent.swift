import Foundation

/// Paging and like state for one song's comments: hot comments from the
/// first page, then the latest ones a page at a time. NetEase and Bilibili
/// share the paging shape but not the API.
@MainActor
final class SongCommentsContent: ObservableObject {
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
    private let backend: Backend
    private let session: URLSession
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
    init(songID: Int, pageSize: Int = 20, client: MusicClient = .shared) {
        self.songID = songID
        self.threadID = MusicAPI.songCommentThread(songID: songID)
        self.pageSize = max(1, pageSize)
        self.client = client
        self.backend = .netease(songID: songID)
        self.session = .shared
        adoptSnapshotIfMatching()
    }

    /// Picks the backend from the track. A track with no readable comment
    /// thread starts loaded and empty, so no request is ever sent for it.
    init(track: Track, pageSize: Int = 20,
         client: MusicClient = .shared, session: URLSession = .shared) {
        let source = SongCommentAvailability.source(for: track)
        self.songID = track.id
        self.threadID = source == .netease ? MusicAPI.songCommentThread(songID: track.id) : ""
        self.pageSize = max(1, pageSize)
        self.client = client
        self.session = session
        self.backend = Self.makeBackend(for: track)
        if source == .unavailable { phase = .loaded }
        adoptSnapshotIfMatching()
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
        phase = .loading
        loadMoreError = nil
        do {
            switch backend {
            case .netease(let songID):
                try await loadNeteaseFirstPage(songID: songID)
            case .bilibili(let track):
                try await loadBilibiliFirstPage(track: track)
            case .unavailable:
                break
            }
            phase = .loaded
            saveSnapshot()
        } catch is CancellationError {
            phase = .idle
        } catch {
            phase = .failed(error.localizedDescription)
        }
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
        } catch {
            loadMoreError = error.localizedDescription
        }
    }

    private func loadNeteaseFirstPage(songID: Int) async throws {
        let page = try await MusicAPI.songComments(songID: songID, limit: pageSize, offset: 0, using: client)
        var hotIDs: Set<Int> = []
        hot = page.hot.filter { hotIDs.insert($0.id).inserted }
        latestIDs = []
        latest = page.latest.filter { latestIDs.insert($0.id).inserted }
        total = page.total
        nextOffset = pageSize
        hasMore = page.more && !page.latest.isEmpty
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

    private func loadBilibiliFirstPage(track: Track) async throws {
        let aid = try await bilibiliAID(for: track)
        // The two orderings are independent requests. Serially they doubled
        // the first-comment wait on a slow A9 (6S, #380): run them together.
        async let hotPageTask = BilibiliComments.fetchPage(
            oid: aid, page: 1, pageSize: pageSize, sort: .hot, using: session)
        let latestPage = try await BilibiliComments.fetchPage(
            oid: aid, page: 1, pageSize: pageSize, sort: .time, using: session)
        let hotPage = try await hotPageTask
        var hotIDs: Set<Int> = []
        hot = hotPage.hot.filter { hotIDs.insert($0.id).inserted }
        latestIDs = []
        latest = latestPage.latest.filter { latestIDs.insert($0.id).inserted }
        total = latestPage.total > 0 ? latestPage.total : hotPage.total
        nextPage = 2
        hasMore = latestPage.more && !latestPage.latest.isEmpty
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
