import Foundation
import Testing
@testable import KumoneCore

@MainActor
@Suite("Source switch service")
struct SourceSwitchServiceTests {
    @Test("same platform skips search")
    func samePlatformSkipsSearch() async throws {
        var searches = 0
        let service = SourceSwitchService(
            search: { _, _, _ in
                searches += 1
                return (isEnd: true, items: [])
            },
            probe: { _, _ in PluginMediaSource(url: nil, headers: nil) },
            throttleNanoseconds: 0
        )
        let entry = try makeEntry(id: "song-1", platform: "origin")

        let outcome = await service.switchEntry(entry, to: "origin")

        #expect(searches == 0)
        #expect(outcome.error == .samePlatform)
        #expect(outcome.replacementID == nil)
        #expect(!outcome.isSuccess)
    }

    @Test("NetEase entries treat every NetEase spelling as the same source")
    func neteaseSpellingsAreSameSource() async throws {
        var searches = 0
        let service = SourceSwitchService(
            search: { _, _, _ in
                searches += 1
                return (isEnd: true, items: [])
            },
            probe: { _, _ in PluginMediaSource(url: nil, headers: nil) },
            throttleNanoseconds: 0
        )
        let entry = LocalTrackEntry.netease(LocalNeteaseSong(
            id: 42,
            name: "Song",
            artist: "Artist",
            album: "Album",
            picUrl: nil,
            durationMS: 180_000,
            fee: 0
        ))

        let outcome = await service.switchEntry(entry, to: "163")

        #expect(searches == 0)
        #expect(outcome.error == .samePlatform)
    }

    @Test("empty results report not found")
    func emptyResultsReportNotFound() async throws {
        let entry = try makeEntry(id: "song-1", platform: "origin")
        let service = SourceSwitchService(
            search: { platform, query, page in
                #expect(platform == "target")
                #expect(query == "Song Artist")
                #expect(page == 1)
                return (isEnd: true, items: [])
            },
            probe: { _, _ in PluginMediaSource(url: nil, headers: nil) },
            throttleNanoseconds: 0
        )

        let outcome = await service.switchEntry(entry, to: "target")

        #expect(outcome.error == .notFound)
        #expect(outcome.replacementID == nil)
        #expect(outcome.replacement == nil)
        #expect(!outcome.isSuccess)
    }

    @Test("candidates that do not match report not found")
    func mismatchedCandidatesReportNotFound() async throws {
        let entry = try makeEntry(id: "song-1", platform: "origin")
        let stranger = try makeItem(
            id: "stranger-1",
            platform: "target",
            title: "Different Song",
            artist: "Someone Else"
        )
        let service = SourceSwitchService(
            search: { _, _, _ in (isEnd: false, items: [stranger]) },
            probe: { _, _ in PluginMediaSource(url: nil, headers: nil) },
            throttleNanoseconds: 0
        )

        let outcome = await service.switchEntry(entry, to: "target")

        #expect(outcome.error == .notFound)
        #expect(outcome.replacementID == nil)
        #expect(outcome.replacement == nil)
        #expect(!outcome.isSuccess)
    }

    @Test("a match reports the candidate identity")
    func matchReportsCandidateIdentity() async throws {
        let entry = try makeEntry(id: "song-1", platform: "origin")
        let candidate = try makeItem(
            id: "candidate-1",
            platform: "target",
            title: "Song",
            artist: "Artist"
        )
        let service = SourceSwitchService(
            search: { _, _, _ in
                (isEnd: true, items: [candidate])
            },
            probe: { _, _ in PluginMediaSource(url: nil, headers: nil) },
            throttleNanoseconds: 0
        )

        let outcome = await service.switchEntry(entry, to: "target")

        #expect(outcome.isSuccess)
        #expect(outcome.error == nil)
        #expect(outcome.replacementID == candidate.sourceCandidate.identity)
        let replacement = try #require(outcome.replacement)
        guard case .plugin(let item) = replacement else {
            Issue.record("expected a plugin replacement")
            return
        }
        #expect(item.id == candidate.id)
        #expect(item.platform == "target")
        #expect(item.title == candidate.title)
    }

    @Test("a replacement keeps its routing platform across a relaunch")
    func replacementKeepsRoutingPlatform() async throws {
        let entry = try makeEntry(id: "song-1", platform: "origin")
        let candidate = try makeItem(
            id: "candidate-2",
            platform: "target",
            title: "Song",
            artist: "Artist"
        )
        let service = SourceSwitchService(
            search: { _, _, _ in (isEnd: true, items: [candidate]) },
            probe: { _, _ in PluginMediaSource(url: nil, headers: nil) },
            throttleNanoseconds: 0
        )

        let outcome = await service.switchEntry(entry, to: "target")
        let replacement = try #require(outcome.replacement)
        let reloaded = try #require(LocalTrackEntry(dictionary: replacement.dictionary))

        #expect(reloaded.platform == "target")
        #expect(reloaded.id == candidate.id)
        #expect(reloaded.title == candidate.title)
        #expect(reloaded.album == candidate.album)
        #expect(reloaded.durationMS == candidate.durationMS)
        // Fields only the plugin understands must survive the round trip;
        // playback resolution reads them back out of the raw payload.
        #expect(reloaded.rawJSON.contains("\"cid\":\"raw-123\""))
    }

    @Test("search failures are reported")
    func searchFailuresAreReported() async throws {
        let entry = try makeEntry(id: "song-1", platform: "origin")
        let service = SourceSwitchService(
            search: { _, _, _ in throw FakeSearchError() },
            probe: { _, _ in PluginMediaSource(url: nil, headers: nil) },
            throttleNanoseconds: 0
        )

        let outcome = await service.switchEntry(entry, to: "target")

        guard case .searchFailed(let message)? = outcome.error else {
            Issue.record("expected .searchFailed, got \(String(describing: outcome.error))")
            return
        }
        #expect(message == "boom")
        #expect(outcome.replacementID == nil)
        #expect(!outcome.isSuccess)
    }

    @Test("the shared service defaults to a 0.7 second request spacing")
    func sharedServiceUsesDefaultThrottle() {
        #expect(SourceSwitchService.shared.throttleNanoseconds == 700_000_000)
    }

    private struct FakeSearchError: LocalizedError {
        var errorDescription: String? { "boom" }
    }

    private func makeEntry(id: String, platform: String) throws -> LocalTrackEntry {
        .plugin(try makeItem(
            id: id,
            platform: platform,
            title: "Song",
            artist: "Artist"
        ))
    }

    private func makeItem(
        id: String,
        platform: String,
        title: String,
        artist: String
    ) throws -> PluginMusicItem {
        try #require(PluginMusicItem(
            normalizing: [
                "id": id,
                "title": title,
                "artist": artist,
                "album": "Album",
                "duration": 180,
                "cid": "raw-123",
            ],
            platform: platform
        ))
    }
}
