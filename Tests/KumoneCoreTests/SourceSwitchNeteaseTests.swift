import Foundation
import Testing
@testable import KumoneCore

@MainActor
@Suite("Source switch NetEase")
struct SourceSwitchNeteaseTests {
    @Test("a match maps every Track field into the .netease reference")
    func matchMapsTrackFields() async throws {
        let entry = try makeEntry(title: "Blue Moon", artist: "Artist One")
        let track = try decodeTrack(
            id: 12_345,
            name: "Blue Moon",
            artists: ["Artist One", "Artist Two"],
            album: "Moon Album",
            picUrl: "https://img.example/moon.jpg",
            durationMS: 185_000,
            fee: 1
        )
        var queries: [String] = []
        let service = SourceSwitchService(
            neteaseSearch: { query in
                queries.append(query)
                return self.searchResult([track])
            },
            throttleNanoseconds: 0
        )

        let outcome = await service.switchEntryToNetease(entry)

        #expect(queries == ["Blue Moon Artist One"])
        #expect(outcome.isSuccess)
        #expect(outcome.targetName == "网易云")
        #expect(outcome.replacementID == "netease|12345")
        let replacement = try #require(outcome.replacement)
        #expect(replacement.id == "netease|12345")
        guard case .netease(let song) = replacement else {
            Issue.record("expected a NetEase replacement")
            return
        }
        #expect(song.id == 12_345)
        #expect(song.name == "Blue Moon")
        #expect(song.artist == "Artist One / Artist Two")
        #expect(song.album == "Moon Album")
        #expect(song.picUrl == "https://img.example/moon.jpg")
        #expect(song.durationMS == 185_000)
        #expect(song.fee == 1)

        // The reference must survive the playlist round trip for playback.
        let reloaded = try #require(LocalTrackEntry(dictionary: replacement.dictionary))
        #expect(reloaded == replacement)
        #expect(reloaded.track.id == 12_345)
        #expect(reloaded.track.album.picUrl == "https://img.example/moon.jpg")
    }

    @Test("no matching song keeps the entry")
    func noMatchKeepsEntry() async throws {
        let entry = try makeEntry(title: "Blue Moon", artist: "Artist One")
        let stranger = try decodeTrack(
            id: 999,
            name: "Different Song",
            artists: ["Someone Else"],
            album: "Other Album",
            picUrl: nil,
            durationMS: 185_000,
            fee: 0
        )
        let service = SourceSwitchService(
            neteaseSearch: { _ in self.searchResult([stranger]) },
            throttleNanoseconds: 0
        )

        let outcome = await service.switchEntryToNetease(entry)

        #expect(outcome.error == .notFound)
        #expect(outcome.replacementID == nil)
        #expect(outcome.replacement == nil)
        #expect(!outcome.isSuccess)
    }

    @Test("search failures keep the entry and carry the reason")
    func searchFailureKeepsEntry() async throws {
        let entry = try makeEntry(title: "Blue Moon", artist: "Artist One")
        let service = SourceSwitchService(
            neteaseSearch: { _ in throw FakeSearchError() },
            throttleNanoseconds: 0
        )

        let outcome = await service.switchEntryToNetease(entry)

        guard case .searchFailed(let message)? = outcome.error else {
            Issue.record("expected .searchFailed, got \(String(describing: outcome.error))")
            return
        }
        #expect(message == "boom")
        #expect(outcome.replacementID == nil)
        #expect(!outcome.isSuccess)
    }

    @Test("a blank title skips the request even when an artist is present")
    func blankQuerySkipsSearch() async throws {
        let entry = try makeEntry(title: "", artist: "Artist One")
        var searches = 0
        let service = SourceSwitchService(
            neteaseSearch: { _ in
                searches += 1
                return self.searchResult([])
            },
            throttleNanoseconds: 0
        )

        let outcome = await service.switchEntryToNetease(entry)

        #expect(searches == 0)
        guard case .searchFailed(let message)? = outcome.error else {
            Issue.record("expected an incomplete-song message")
            return
        }
        #expect(message.contains("歌曲信息不完整"))
        #expect(!outcome.isSuccess)
    }

    @Test("a NetEase entry treats the direct target as the same source")
    func neteaseEntrySkipsDirectTarget() async throws {
        let entry = LocalTrackEntry.netease(LocalNeteaseSong(
            id: 42,
            name: "Song",
            artist: "Artist",
            album: "Album",
            picUrl: nil,
            durationMS: 180_000,
            fee: 0
        ))
        var searches = 0
        let service = SourceSwitchService(
            neteaseSearch: { _ in
                searches += 1
                return self.searchResult([])
            },
            throttleNanoseconds: 0
        )

        let outcome = await service.switchEntryToNetease(entry)

        #expect(searches == 0)
        #expect(outcome.error == .samePlatform)
        #expect(!outcome.isSuccess)
    }

    @Test("a NetEase batch that misses everywhere still reports progress")
    func neteaseBatchAllNotFound() async throws {
        let entries = [
            try makeEntry(id: "a", title: "Song A"),
            try makeEntry(id: "b", title: "Song B"),
        ]
        var searches = 0
        var maxActive = 0
        var active = 0
        var progress: [String] = []
        let service = SourceSwitchService(
            neteaseSearch: { _ in
                searches += 1
                active += 1
                maxActive = max(maxActive, active)
                await Task.yield()
                active -= 1
                return self.searchResult([])
            },
            throttleNanoseconds: 0
        )

        let outcomes = await service.switchEntriesToNetease(entries) { done, total in
            progress.append("\(done)/\(total)")
        }

        #expect(searches == 2)
        #expect(maxActive == 1)
        #expect(progress == ["1/2", "2/2"])
        #expect(outcomes.count == 2)
        #expect(outcomes.allSatisfy { $0.error == .notFound })
        #expect(outcomes.allSatisfy { $0.replacement == nil })
    }

    @Test("every NetEase plugin spelling collapses into the direct target")
    func neteasePluginSpellingsCollapse() {
        #expect(SourceSwitchService.isNeteaseSource(platform: "网易音乐"))
        #expect(SourceSwitchService.isNeteaseSource(platform: "元力WY"))
        #expect(SourceSwitchService.isNeteaseSource(platform: "wy"))
        #expect(SourceSwitchService.isNeteasePlugin(
            platform: "元力WY",
            sourceURL: "https://example.com/yuanli/wy.js"
        ))
        #expect(SourceSwitchService.isNeteasePlugin(
            platform: "Opaque",
            sourceURL: "https://example.com/plugins/wy.js?mirror=1"
        ))
        #expect(!SourceSwitchService.isNeteaseSource(platform: "QQ"))
        #expect(!SourceSwitchService.isNeteasePlugin(
            platform: "QQ",
            sourceURL: "https://example.com/qq.js"
        ))
    }

    private struct FakeSearchError: LocalizedError {
        var errorDescription: String? { "boom" }
    }

    private func searchResult(_ tracks: [Track]) -> MusicAPI.SearchResult {
        MusicAPI.SearchResult(
            songs: tracks,
            albums: nil,
            artists: nil,
            playlists: nil,
            songCount: nil,
            albumCount: nil,
            artistCount: nil,
            playlistCount: nil
        )
    }

    private func decodeTrack(
        id: Int,
        name: String,
        artists: [String],
        album: String,
        picUrl: String?,
        durationMS: Int,
        fee: Int
    ) throws -> Track {
        let artistJSON = artists
            .map { "{\"id\":0,\"name\":\"\($0)\"}" }
            .joined(separator: ",")
        let picJSON = picUrl.map { "\"\($0)\"" } ?? "null"
        let json = "{\"id\":\(id),\"name\":\"\(name)\",\"ar\":[\(artistJSON)],"
            + "\"al\":{\"id\":1,\"name\":\"\(album)\",\"picUrl\":\(picJSON)},"
            + "\"dt\":\(durationMS),\"fee\":\(fee)}"
        return try JSONDecoder().decode(Track.self, from: Data(json.utf8))
    }

    private func makeEntry(
        id: String = "song-1",
        title: String,
        artist: String = "Artist One"
    ) throws -> LocalTrackEntry {
        .plugin(try #require(PluginMusicItem(
            normalizing: [
                "id": id,
                "title": title,
                "artist": artist,
                "album": "Origin Album",
                "duration": 180,
            ],
            platform: "origin"
        )))
    }
}
