import Foundation
import Testing
@testable import KumoneCore

@Suite("Source matcher")
struct SourceMatcherTests {
    @Test("normalization strips version decorations and subtitles")
    func normalizationStripsDecorations() {
        #expect(SourceMatcher.normalize("Song") == "song")
        #expect(SourceMatcher.normalize("Song (Live)") == "song")
        #expect(SourceMatcher.normalize("ＳＯＮＧ（Ｌｉｖｅ）") == "song")
        #expect(SourceMatcher.normalize("Song【Remastered】") == "song")
        #expect(SourceMatcher.normalize("Song「Live」") == "song")
        #expect(SourceMatcher.normalize("Song (feat. Guest)") == "song")
        #expect(SourceMatcher.normalize("Song - Remastered 2011") == "song")
    }

    @Test("same song from another source matches")
    func sameSongAcrossSourcesMatches() throws {
        let item = try makeItem(
            id: "original",
            title: "Blue Moon (Live)",
            artist: "Example Artist",
            durationSeconds: 180
        )
        let query = SourceMatchQuery(entry: .plugin(item))
        let candidate = makeCandidate(
            identity: "other|blue-moon",
            title: "Blue Moon",
            artist: "Example Artist",
            durationMS: 181_000
        )

        let match = SourceMatcher.bestMatch(for: query, among: [candidate])
        #expect(match?.identity == "other|blue-moon")

        let reverseQuery = SourceMatchQuery(
            title: "Blue Moon",
            artist: "Example Artist",
            durationMS: 181_000
        )
        #expect(SourceMatcher.bestMatch(for: reverseQuery, among: [item.sourceCandidate]) != nil)
    }

    @Test("same title but a different artist is refused")
    func sameTitleDifferentArtistRejected() {
        let query = SourceMatchQuery(
            title: "Song",
            artist: "Original Artist",
            durationMS: 180_000
        )
        let candidate = makeCandidate(
            identity: "cover|song",
            title: "Song (Cover by X)",
            artist: "Cover Artist X",
            durationMS: 180_000
        )

        #expect(SourceMatcher.score(query: query, candidate: candidate) == 0)
        #expect(SourceMatcher.bestMatch(for: query, among: [candidate]) == nil)
    }

    @Test("empty candidate list returns nil")
    func emptyCandidatesReturnNil() {
        let query = SourceMatchQuery(title: "Song", artist: "Artist", durationMS: 180_000)
        #expect(SourceMatcher.bestMatch(for: query, among: []) == nil)
    }

    @Test("close candidates by different artists return nil")
    func tiedCandidatesByDifferentArtistsReturnNil() {
        let query = SourceMatchQuery(title: "Song", artist: "Artist A", durationMS: 180_000)
        let first = makeCandidate(
            identity: "source|first",
            title: "Song",
            artist: "Artist A One",
            durationMS: 180_000
        )
        let second = makeCandidate(
            identity: "source|second",
            title: "Song",
            artist: "Artist A Two",
            durationMS: 180_000
        )

        #expect(SourceMatcher.bestMatch(for: query, among: [first])?.identity == "source|first")
        #expect(SourceMatcher.score(query: query, candidate: first) > 0.6)
        #expect(SourceMatcher.score(query: query, candidate: second) > 0.6)
        #expect(SourceMatcher.bestMatch(for: query, among: [first, second]) == nil)
    }

    @Test("shuffled candidates still pick the highest score")
    func shuffledCandidatesPickHighestScore() {
        let query = SourceMatchQuery(title: "Song", artist: "Artist A", durationMS: 180_000)
        let best = makeCandidate(
            identity: "source|best",
            title: "Song",
            artist: "Artist A",
            durationMS: 180_000
        )
        let lower = makeCandidate(
            identity: "source|lower",
            title: "Distant Melody",
            artist: "Artist A",
            durationMS: 180_000
        )
        let lowest = makeCandidate(
            identity: "source|lowest",
            title: "Another Sky",
            artist: "Artist A",
            durationMS: 175_000
        )

        for candidates in [
            [best, lower, lowest],
            [lowest, best, lower],
            [lower, lowest, best],
        ] {
            let match = SourceMatcher.bestMatch(for: query, among: candidates)
            #expect(match?.identity == "source|best")
        }
    }

    @Test("scores below the threshold are not returned")
    func lowScoreRejected() {
        let query = SourceMatchQuery(title: "Song", artist: "Artist A", durationMS: 180_000)
        let weak = makeCandidate(
            identity: "source|weak",
            title: "Distant Melody",
            artist: "Artist A",
            durationMS: 180_000
        )

        #expect(SourceMatcher.score(query: query, candidate: weak) < 0.6)
        #expect(SourceMatcher.bestMatch(for: query, among: [weak]) == nil)
    }

    @Test("a query without a duration still matches")
    func zeroDurationStillMatches() {
        let query = SourceMatchQuery(
            title: "Song",
            artist: "Artist A",
            album: "",
            durationMS: 0
        )
        let candidate = makeCandidate(
            identity: "source|zero-duration",
            title: "Song",
            artist: "Artist A",
            durationMS: 180_000
        )

        #expect(SourceMatcher.score(query: query, candidate: candidate) > 0.6)
        #expect(SourceMatcher.bestMatch(for: query, among: [candidate])?.identity
            == "source|zero-duration")
    }

    @Test("an empty album does not block matching")
    func emptyAlbumStillMatches() {
        let query = SourceMatchQuery(
            title: "Song",
            artist: "Artist A",
            album: "",
            durationMS: 180_000
        )
        let candidate = makeCandidate(
            identity: "source|album",
            title: "Song",
            artist: "Artist A",
            album: "Another Album",
            durationMS: 180_000
        )

        #expect(SourceMatcher.score(query: query, candidate: candidate) > 0.6)
        #expect(SourceMatcher.bestMatch(for: query, among: [candidate])?.identity
            == "source|album")
    }

    private func makeItem(
        id: String,
        title: String,
        artist: String,
        durationSeconds: Double
    ) throws -> PluginMusicItem {
        try #require(PluginMusicItem(
            normalizing: [
                "id": id,
                "title": title,
                "artist": artist,
                "album": "Album",
                "duration": durationSeconds,
            ],
            platform: "test"
        ))
    }

    private func makeCandidate(
        identity: String,
        title: String,
        artist: String,
        album: String = "Album",
        durationMS: Int
    ) -> SourceCandidate {
        SourceCandidate(
            identity: identity,
            title: title,
            artist: artist,
            album: album,
            durationMS: durationMS
        )
    }
}
