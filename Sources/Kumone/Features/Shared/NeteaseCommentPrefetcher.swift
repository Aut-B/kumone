import Foundation

/// Fetches the first page of a NetEase song's comments in the background so
/// opening the comments panel reuses that request instead of starting another.
/// One entry per song and page size: repeated prefetches and a panel opened
/// mid-flight all wait on the same task.
@MainActor
final class NeteaseCommentPrefetcher {
    static let shared = NeteaseCommentPrefetcher()

    private struct Key: Hashable {
        let songID: Int
        let limit: Int
    }

    private struct Entry {
        let token: Int
        let task: Task<SongCommentsPage, Error>
    }

    private let client: MusicClient
    private var completed: [Key: SongCommentsPage] = [:]
    private var inflight: [Key: Entry] = [:]
    private var currentSongID: Int?
    /// Identifies each request so a cancelled one cannot clear its successor.
    private var nextToken = 0

    init(client: MusicClient = .shared) {
        self.client = client
    }

    /// Starts the first page for a song unless it is already done or running.
    func prefetch(songID: Int, limit: Int = 20) {
        let key = Key(songID: songID, limit: max(1, limit))
        if currentSongID != songID {
            switchToSong(songID)
        }
        // Showing the player again must not re-fetch a page already in hand.
        guard completed[key] == nil else { return }
        _ = entry(for: key)
    }

    /// Drops the cached first page and cancels in-flight requests, e.g. when
    /// the player moves on to a song whose comments are not prefetched.
    func cancelAll() {
        for entry in inflight.values { entry.task.cancel() }
        inflight.removeAll()
        completed.removeAll()
        currentSongID = nil
    }

    /// The first page, reusing a completed prefetch or joining its request. A
    /// panel opened while prefetching waits for that same task.
    func page(songID: Int, limit: Int = 20) async throws -> SongCommentsPage {
        let key = Key(songID: songID, limit: max(1, limit))
        if currentSongID != songID {
            switchToSong(songID)
        }
        if let page = completed[key] { return page }
        let entry = entry(for: key)
        do {
            return try await entry.task.value
        } catch {
            removeInflight(for: key, token: entry.token)
            throw error
        }
    }

    /// A retry must not re-join the request a watchdog already gave up on.
    /// A completed page is still valid, so only a stalled request is replaced.
    func refreshPage(songID: Int, limit: Int = 20) async throws -> SongCommentsPage {
        let key = Key(songID: songID, limit: max(1, limit))
        if currentSongID != songID {
            switchToSong(songID)
        }
        if let page = completed[key] { return page }
        inflight.removeValue(forKey: key)?.task.cancel()
        let entry = entry(for: key)
        do {
            return try await entry.task.value
        } catch {
            removeInflight(for: key, token: entry.token)
            throw error
        }
    }

    /// A completed first page, if the prefetch has already landed.
    func cachedPage(songID: Int, limit: Int = 20) -> SongCommentsPage? {
        completed[Key(songID: songID, limit: max(1, limit))]
    }

    private func switchToSong(_ songID: Int) {
        cancelAll()
        currentSongID = songID
    }

    @discardableResult
    private func entry(for key: Key) -> Entry {
        if let existing = inflight[key] { return existing }
        let token = nextToken
        nextToken += 1
        let client = self.client
        let task = Task<SongCommentsPage, Error> {
            let page = try await MusicAPI.songComments(
                songID: key.songID, limit: key.limit, offset: 0, using: client)
            // A cancelled prefetch must not publish its page either.
            try Task.checkCancellation()
            return page
        }
        let entry = Entry(token: token, task: task)
        inflight[key] = entry
        Task { @MainActor [weak self] in
            do {
                let page = try await task.value
                self?.finish(page, for: key, token: token)
            } catch {
                self?.removeInflight(for: key, token: token)
            }
        }
        return entry
    }

    private func finish(_ page: SongCommentsPage, for key: Key, token: Int) {
        guard inflight[key]?.token == token else { return }
        completed[key] = page
        inflight[key] = nil
    }

    private func removeInflight(for key: Key, token: Int) {
        guard inflight[key]?.token == token else { return }
        inflight[key] = nil
    }
}
