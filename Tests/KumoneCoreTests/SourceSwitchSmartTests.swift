import Foundation
import Testing
@testable import KumoneCore

@MainActor
@Suite("Source switch smart")
struct SourceSwitchSmartTests {
    @Test("the first source that resolves a URL wins")
    func firstPlayableSourceWins() async throws {
        let entry = try makeEntry(platform: "origin")
        let items = [
            "alpha": try makeItem(id: "alpha-1", platform: "alpha"),
            "beta": try makeItem(id: "beta-1", platform: "beta"),
            "gamma": try makeItem(id: "gamma-1", platform: "gamma"),
        ]
        var searches: [String] = []
        var probes: [String] = []
        let service = SourceSwitchService(
            search: { platform, _, _ in
                searches.append(platform)
                return (isEnd: true, items: [items[platform]!])
            },
            probe: { platform, _ in
                probes.append(platform)
                switch platform {
                case "alpha":
                    return PluginMediaSource(url: nil, headers: nil, failureReason: "签名失效")
                case "beta":
                    return PluginMediaSource(url: nil, headers: nil, failureReason: "网络超时")
                default:
                    return PluginMediaSource(
                        url: URL(string: "https://gamma.example/a.mp3"),
                        headers: nil
                    )
                }
            },
            plugins: {
                [self.makePlugin("alpha", name: "Alpha"),
                 self.makePlugin("beta", name: "Beta"),
                 self.makePlugin("gamma", name: "Gamma")]
            },
            throttleNanoseconds: 0
        )

        let outcome = await service.switchEntrySmart(entry)

        #expect(searches == ["alpha", "beta", "gamma"])
        #expect(probes == ["alpha", "beta", "gamma"])
        #expect(outcome.isSuccess)
        #expect(outcome.targetName == "Gamma")
        #expect(outcome.replacementID == "gamma|gamma-1")
        guard case .plugin(let item)? = outcome.replacement else {
            Issue.record("expected a plugin replacement from the first usable source")
            return
        }
        #expect(item.platform == "gamma")
        #expect(item.id == "gamma|gamma-1")
    }

    @Test("a search error falls through to the next source")
    func searchErrorFallsThrough() async throws {
        let entry = try makeEntry(platform: "origin")
        let betaItem = try makeItem(id: "beta-1", platform: "beta")
        var searches: [String] = []
        var probes: [String] = []
        let service = SourceSwitchService(
            search: { platform, _, _ in
                searches.append(platform)
                if platform == "alpha" { throw FakeSearchError() }
                return (isEnd: true, items: [betaItem])
            },
            probe: { platform, _ in
                probes.append(platform)
                return PluginMediaSource(url: URL(string: "https://beta.example/a.mp3"), headers: nil)
            },
            plugins: {
                [self.makePlugin("alpha", name: "Alpha"),
                 self.makePlugin("beta", name: "Beta")]
            },
            throttleNanoseconds: 0
        )

        let outcome = await service.switchEntrySmart(entry)

        #expect(searches == ["alpha", "beta"])
        #expect(probes == ["beta"])
        #expect(outcome.isSuccess)
        #expect(outcome.replacementID == "beta|beta-1")
    }

    @Test("a source without a matching item falls through")
    func noMatchFallsThrough() async throws {
        let entry = try makeEntry(platform: "origin")
        let stranger = try makeItem(
            id: "stranger-1",
            platform: "alpha",
            title: "Different Song",
            artist: "Someone Else"
        )
        let betaItem = try makeItem(id: "beta-1", platform: "beta")
        var probes: [String] = []
        let service = SourceSwitchService(
            search: { platform, _, _ in
                platform == "alpha"
                    ? (isEnd: true, items: [stranger])
                    : (isEnd: true, items: [betaItem])
            },
            probe: { platform, _ in
                probes.append(platform)
                return PluginMediaSource(url: URL(string: "https://beta.example/a.mp3"), headers: nil)
            },
            plugins: {
                [self.makePlugin("alpha", name: "Alpha"),
                 self.makePlugin("beta", name: "Beta")]
            },
            throttleNanoseconds: 0
        )

        let outcome = await service.switchEntrySmart(entry)

        // A missing match never reaches getMediaSource.
        #expect(probes == ["beta"])
        #expect(outcome.replacementID == "beta|beta-1")
    }

    @Test("all sources failing keeps the entry and explains every source")
    func allSourcesFailReportEveryReason() async throws {
        let entry = try makeEntry(platform: "origin")
        let items = [
            "alpha": try makeItem(id: "alpha-1", platform: "alpha"),
            "beta": try makeItem(id: "beta-1", platform: "beta"),
        ]
        var probes: [String] = []
        let service = SourceSwitchService(
            search: { platform, _, _ in
                (isEnd: true, items: [items[platform]!])
            },
            probe: { platform, _ in
                probes.append(platform)
                let reason = platform == "alpha" ? "签名失效" : "网络超时"
                return PluginMediaSource(url: nil, headers: nil, failureReason: reason)
            },
            plugins: {
                [self.makePlugin("alpha", name: "Alpha"),
                 self.makePlugin("beta", name: "Beta")]
            },
            throttleNanoseconds: 0
        )

        let outcome = await service.switchEntrySmart(entry)

        #expect(probes == ["alpha", "beta"])
        #expect(!outcome.isSuccess)
        #expect(outcome.replacementID == nil)
        #expect(outcome.replacement == nil)
        guard case .allSourcesFailed(let details)? = outcome.error else {
            Issue.record("expected .allSourcesFailed, got \(String(describing: outcome.error))")
            return
        }
        #expect(details.contains("Alpha"))
        #expect(details.contains("签名失效"))
        #expect(details.contains("Beta"))
        #expect(details.contains("网络超时"))
    }

    @Test("same-source and disabled plugins are skipped")
    func sameSourceAndDisabledAreSkipped() async throws {
        let entry = try makeEntry(platform: "alpha")
        let gammaItem = try makeItem(id: "gamma-1", platform: "gamma")
        var searches: [String] = []
        var probes: [String] = []
        let service = SourceSwitchService(
            search: { platform, _, _ in
                searches.append(platform)
                return (isEnd: true, items: [gammaItem])
            },
            probe: { platform, _ in
                probes.append(platform)
                return PluginMediaSource(url: URL(string: "https://gamma.example/a.mp3"), headers: nil)
            },
            plugins: {
                [self.makePlugin("alpha", name: "Alpha"),
                 self.makePlugin("beta", name: "Beta", enabled: false),
                 self.makePlugin("gamma", name: "Gamma")]
            },
            throttleNanoseconds: 0
        )

        let outcome = await service.switchEntrySmart(entry)

        #expect(searches == ["gamma"])
        #expect(probes == ["gamma"])
        #expect(outcome.replacementID == "gamma|gamma-1")
    }

    @Test("no enabled plugins fails without searching")
    func noEnabledPluginsFailsWithoutSearching() async throws {
        let entry = try makeEntry(platform: "origin")
        var searches = 0
        let service = SourceSwitchService(
            search: { _, _, _ in
                searches += 1
                return (isEnd: true, items: [])
            },
            probe: { _, _ in PluginMediaSource(url: nil, headers: nil) },
            plugins: { [self.makePlugin("alpha", name: "Alpha", enabled: false)] },
            throttleNanoseconds: 0
        )

        let outcome = await service.switchEntrySmart(entry)

        #expect(searches == 0)
        #expect(!outcome.isSuccess)
        guard case .allSourcesFailed(let details)? = outcome.error else {
            Issue.record("expected an explanation for the missing sources")
            return
        }
        #expect(details.contains("没有启用"))
    }

    private struct FakeSearchError: LocalizedError {
        var errorDescription: String? { "boom" }
    }

    private func makePlugin(
        _ platform: String,
        name: String,
        enabled: Bool = true
    ) -> PluginManager.InstalledPlugin {
        PluginManager.InstalledPlugin(
            platform: platform,
            name: name,
            version: nil,
            sourceURL: nil,
            enabled: enabled,
            fileName: "\(platform).js",
            hash: "hash-\(platform)"
        )
    }

    private func makeEntry(platform: String) throws -> LocalTrackEntry {
        .plugin(try makeItem(id: "origin-1", platform: platform))
    }

    private func makeItem(
        id: String,
        platform: String,
        title: String = "Song",
        artist: String = "Artist"
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
