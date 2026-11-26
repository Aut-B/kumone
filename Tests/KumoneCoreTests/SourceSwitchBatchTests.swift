import Foundation
import Testing
@testable import KumoneCore

@MainActor
@Suite("Source switch batch")
struct SourceSwitchBatchTests {
    @Test("entries are searched one at a time and progress counts up")
    func serialSearchAndProgress() async throws {
        let titles = ["Track A", "Track B", "Track C"]
        var entries: [LocalTrackEntry] = []
        var itemsByQuery: [String: PluginMusicItem] = [:]
        for (index, title) in titles.enumerated() {
            itemsByQuery["\(title) Artist"] = try makeItem(
                id: "item-\(index)",
                platform: "target",
                title: title,
                artist: "Artist"
            )
            entries.append(.plugin(try makeItem(
                id: "origin-\(index)",
                platform: "origin",
                title: title,
                artist: "Artist"
            )))
        }

        var events: [String] = []
        var active = 0
        var maxActive = 0
        var progress: [String] = []

        let service = SourceSwitchService(
            search: { _, query, _ in
                active += 1
                maxActive = max(maxActive, active)
                events.append("start|\(query)")
                await Task.yield()
                active -= 1
                events.append("end|\(query)")
                return (isEnd: true, items: itemsByQuery[query].map { [$0] } ?? [])
            },
            probe: { _, _ in
                PluginMediaSource(url: URL(string: "https://example.com/a.mp3"), headers: nil)
            },
            throttleNanoseconds: 0
        )

        let outcomes = await service.switchEntries(entries, to: "target") { done, total in
            progress.append("\(done)/\(total)")
        }

        #expect(maxActive == 1)
        #expect(events == [
            "start|Track A Artist", "end|Track A Artist",
            "start|Track B Artist", "end|Track B Artist",
            "start|Track C Artist", "end|Track C Artist",
        ])
        #expect(progress == ["1/3", "2/3", "3/3"])
        #expect(outcomes.count == 3)
        #expect(outcomes.allSatisfy(\.isSuccess))
        #expect(outcomes.map(\.sourceTitle) == titles)
        #expect(outcomes.compactMap(\.replacementID) == [
            "target|item-0",
            "target|item-1",
            "target|item-2",
        ])
    }

    @Test("an empty batch searches nothing and reports no progress")
    func emptyBatchDoesNothing() async {
        var searches = 0
        var progressCalls = 0
        let service = SourceSwitchService(
            search: { _, _, _ in
                searches += 1
                return (isEnd: true, items: [])
            },
            probe: { _, _ in PluginMediaSource(url: nil, headers: nil) },
            throttleNanoseconds: 0
        )

        let outcomes = await service.switchEntries([], to: "target") { _, _ in
            progressCalls += 1
        }

        #expect(outcomes.isEmpty)
        #expect(searches == 0)
        #expect(progressCalls == 0)
    }

    @Test("same-source entries still advance the batch")
    func sameSourceEntriesAdvanceProgress() async throws {
        let entries = [
            try makeEntry(id: "a", platform: "target"),
            try makeEntry(id: "b", platform: "target"),
        ]
        var searches = 0
        var progress: [String] = []
        let service = SourceSwitchService(
            search: { _, _, _ in
                searches += 1
                return (isEnd: true, items: [])
            },
            probe: { _, _ in PluginMediaSource(url: nil, headers: nil) },
            throttleNanoseconds: 0
        )

        let outcomes = await service.switchEntries(entries, to: "target") { done, total in
            progress.append("\(done)/\(total)")
        }

        #expect(searches == 0)
        #expect(progress == ["1/2", "2/2"])
        #expect(outcomes.count == 2)
        #expect(outcomes.allSatisfy { $0.error == .samePlatform })
    }

    @Test("one failure does not stop the rest of the batch")
    func failureDoesNotStopLaterEntries() async throws {
        let entries = [
            try makeEntry(id: "a", platform: "origin", title: "Broken"),
            try makeEntry(id: "b", platform: "origin", title: "Good"),
        ]
        let goodItem = try makeItem(
            id: "good-1",
            platform: "target",
            title: "Good",
            artist: "Artist"
        )
        var progress: [String] = []
        let service = SourceSwitchService(
            search: { _, query, _ in
                if query.hasPrefix("Broken") { throw FakeSearchError() }
                return (isEnd: true, items: [goodItem])
            },
            probe: { _, _ in PluginMediaSource(url: nil, headers: nil) },
            throttleNanoseconds: 0
        )

        let outcomes = await service.switchEntries(entries, to: "target") { done, total in
            progress.append("\(done)/\(total)")
        }

        #expect(progress == ["1/2", "2/2"])
        guard case .searchFailed(let message)? = outcomes.first?.error else {
            Issue.record("expected the first entry to fail its search")
            return
        }
        #expect(message == "boom")
        #expect(outcomes.last?.isSuccess == true)
    }

    private struct FakeSearchError: LocalizedError {
        var errorDescription: String? { "boom" }
    }

    private func makeEntry(
        id: String,
        platform: String,
        title: String = "Song"
    ) throws -> LocalTrackEntry {
        .plugin(try makeItem(
            id: id,
            platform: platform,
            title: title,
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
            ],
            platform: platform
        ))
    }
}
