import Foundation
import Testing
@testable import KumoneCore

@Suite("Playlist replacement", .serialized)
struct PlaylistReplacementTests {
    @Test("replaces one entry in place and keeps order")
    func replacesInPlaceKeepingOrder() {
        let first = entry(id: "a", title: "Alpha")
        let second = entry(id: "b", title: "Beta")
        let third = entry(id: "c", title: "Gamma")
        let replacement = entry(id: "b-new", title: "Beta New")

        let result = LocalPlaylistReplacement.apply(
            [second.id: replacement],
            to: [first, second, third]
        )

        #expect(result.entries.map(\.id) == [first.id, replacement.id, third.id])
        #expect(result.entries[0] == first)
        #expect(result.entries[2] == third)
        #expect(result.replacedIDs == [second.id])
        #expect(result.skippedIDs.isEmpty)
    }

    @Test("a replacement that would duplicate an id is skipped")
    func duplicateReplacementIsSkipped() {
        let first = entry(id: "a", title: "Alpha")
        let second = entry(id: "b", title: "Beta")
        let third = entry(id: "c", title: "Gamma")
        let duplicate = entry(id: "c", title: "Gamma Copy")
        let original = [first, second, third]

        let result = LocalPlaylistReplacement.apply(
            [second.id: duplicate],
            to: original
        )

        #expect(result.entries == original)
        #expect(result.replacedIDs.isEmpty)
        #expect(result.skippedIDs == [second.id])
        #expect(Set(result.entries.map(\.id)).count == result.entries.count)
    }

    @Test("unknown ids are ignored")
    func unknownIDsAreIgnored() {
        let original = [entry(id: "a", title: "Alpha"), entry(id: "b", title: "Beta")]
        let unknown = entry(id: "missing", title: "Missing")

        let result = LocalPlaylistReplacement.apply(
            ["plugin|test|missing": unknown],
            to: original
        )

        #expect(result.entries == original)
        #expect(result.replacedIDs.isEmpty)
        #expect(result.skippedIDs.isEmpty)
    }

    @Test("empty replacements are a no-op")
    func emptyReplacementsAreNoOp() {
        let original = [entry(id: "a", title: "Alpha")]
        let result = LocalPlaylistReplacement.apply([:], to: original)

        #expect(result.entries == original)
        #expect(result.replacedCount == 0)
        #expect(result.skippedIDs.isEmpty)
    }

    @MainActor
    @Test("store rewrites only the target and keeps itemCount")
    func storeReplacesOnlyTargetEntry() throws {
        let store = ImportedPlaylistStore.shared
        let playlist = try store.createPlaylist(name: "Replacement-\(UUID().uuidString)")
        defer { store.remove(playlist) }

        let entries = [
            entry(id: "a", title: "Alpha"),
            entry(id: "b", title: "Beta"),
            entry(id: "c", title: "Gamma"),
        ]
        #expect(store.addEntries(entries, to: playlist) == 3)

        let fileURL = playlistFileURL(for: playlist)
        let before = try jsonObjects(at: fileURL)
        let replacement = entry(id: "b-new", title: "Beta New")

        let result = store.replaceEntries([entries[1].id: replacement], in: playlist)

        #expect(result.replacedIDs == [entries[1].id])
        #expect(result.skippedIDs.isEmpty)
        #expect(result.entries.count == 3)
        #expect(result.entries[0].id == entries[0].id)
        #expect(result.entries[1].id == replacement.id)
        #expect(result.entries[2].id == entries[2].id)

        let updated = try #require(store.playlists.first { $0.id == playlist.id })
        #expect(updated.itemCount == 3)

        let after = try jsonObjects(at: fileURL)
        let beforeFirst = try canonicalJSON(before[0])
        let beforeSecond = try canonicalJSON(before[1])
        let beforeThird = try canonicalJSON(before[2])
        let afterFirst = try canonicalJSON(after[0])
        let afterSecond = try canonicalJSON(after[1])
        let afterThird = try canonicalJSON(after[2])
        #expect(after.count == before.count)
        #expect(afterFirst == beforeFirst)
        #expect(afterSecond != beforeSecond)
        #expect(afterThird == beforeThird)
        #expect((after[1]["title"] as? String) == "Beta New")
    }

    @MainActor
    @Test("empty replacement set leaves the file untouched")
    func storeEmptyReplacementDoesNotTouchDisk() throws {
        let store = ImportedPlaylistStore.shared
        let playlist = try store.createPlaylist(name: "EmptyReplacement-\(UUID().uuidString)")
        defer { store.remove(playlist) }

        #expect(store.addEntries([entry(id: "a", title: "Alpha")], to: playlist) == 1)

        let fileURL = playlistFileURL(for: playlist)
        let beforeData = try Data(contentsOf: fileURL)
        let beforeAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)

        let result = store.replaceEntries([:], in: playlist)

        #expect(result.replacedCount == 0)
        #expect(result.entries.count == 1)

        let afterData = try Data(contentsOf: fileURL)
        let afterAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        #expect(afterData == beforeData)
        #expect((afterAttributes[.modificationDate] as? Date) == (beforeAttributes[.modificationDate] as? Date))
        #expect((afterAttributes[.systemFileNumber] as? NSNumber) == (beforeAttributes[.systemFileNumber] as? NSNumber))
    }

    private func entry(id: String, title: String) -> LocalTrackEntry {
        .plugin(PluginMusicItem(
            normalizing: [
                "id": id,
                "title": title,
                "artist": "Artist",
                "album": "Album",
                "duration": 180,
            ],
            platform: "test"
        )!)
    }

    private func playlistFileURL(for playlist: ImportedPlaylist) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ImportedPlaylists", isDirectory: true)
            .appendingPathComponent(playlist.fileName)
    }

    private func jsonObjects(at url: URL) throws -> [[String: Any]] {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [[String: Any]])
    }

    private func canonicalJSON(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
