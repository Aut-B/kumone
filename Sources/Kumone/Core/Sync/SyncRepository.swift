import Foundation
import os

/// Each installation writes only its own directory. File coordination protects
/// access through both iCloud containers and user-authorized File Provider folders.
actor SyncRepository {
    enum Domain: String, CaseIterable {
        case playback, preferences, login
    }

    private var directory: URL?
    private var scopedURL: URL?
    private var connectionID: UUID?
    private var conflicts: [URL: [NSFileVersion]] = [:]
    private var presenter: SyncDirectoryPresenter?
    private let log = Logger(subsystem: "im.missuo.kumone", category: "sync-repository")
    private struct FileStamp: Equatable {
        let identity: any NSObjectProtocol
        let generation: any NSObjectProtocol

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.identity.isEqual(rhs.identity) && lhs.generation.isEqual(rhs.generation)
        }
    }
    private struct CachedRecord {
        let stamp: FileStamp?
        let data: Data
        // Type erasure stays inside the generic repository cache. A different
        // requested payload type must decode and validate its own record.
        let record: Any
    }
    private struct PublishedQueue {
        let revision: UUID
        let snapshot: PlaybackQueueSnapshot
        let previousRevision: UUID?
    }
    private var decodedFiles: [URL: CachedRecord] = [:]
    private var publishedQueues: [UUID: PublishedQueue] = [:]
    private var completePlayback: [UUID: SyncRecord<PlaybackSession>] = [:]
    private var lastQueueCleanup: [UUID: ContinuousClock.Instant] = [:]
    private let now: @Sendable () -> ContinuousClock.Instant
    private struct Manifest: Codable {
        let application: String
        let schemaVersion: Int
    }

    init(now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.now = now
    }

    func connect(to selectedURL: URL, connectionID: UUID) throws -> Data {
        disconnect()
        if selectedURL.startAccessingSecurityScopedResource() { scopedURL = selectedURL }
        do {
            let containsRepository = FileManager.default.fileExists(
                atPath: selectedURL.appendingPathComponent("repository.json").path
            )
            let root = containsRepository || selectedURL.lastPathComponent == "Kumone"
                ? selectedURL : selectedURL.appendingPathComponent("Kumone", isDirectory: true)
            try coordinate(root, writing: true) { url in
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
            try validateRepository(at: root)
            #if os(macOS)
            let bookmark = try root.bookmarkData(options: .withSecurityScope)
            #else
            let bookmark = try root.bookmarkData(options: .minimalBookmark)
            #endif
            directory = root
            self.connectionID = connectionID
            return bookmark
        } catch {
            disconnect()
            throw error
        }
    }

    func restore(bookmark: Data, connectionID: UUID) throws -> Data {
        var stale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
        #else
        let options: URL.BookmarkResolutionOptions = .withoutUI
        #endif
        let url = try URL(resolvingBookmarkData: bookmark, options: options, bookmarkDataIsStale: &stale)
        return try connect(to: url, connectionID: connectionID)
    }

    func connectContainer(connectionID: UUID) throws -> Bool {
        disconnect()
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else { return false }
        let root = container.appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Kumone", isDirectory: true)
        try coordinate(root, writing: true) { url in
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try validateRepository(at: root)
        directory = root
        self.connectionID = connectionID
        return true
    }

    func disconnect(connectionID: UUID? = nil) {
        if let connectionID, self.connectionID != connectionID { return }
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        directory = nil
        self.connectionID = nil
        conflicts.removeAll()
        decodedFiles.removeAll()
        publishedQueues.removeAll()
        completePlayback.removeAll()
        lastQueueCleanup.removeAll()
        if let presenter { NSFileCoordinator.removeFilePresenter(presenter) }
        presenter = nil
    }

    func observeChanges(_ onChange: @escaping @Sendable (URL) -> Void) {
        guard let directory else { return }
        if let presenter { NSFileCoordinator.removeFilePresenter(presenter) }
        let observer = SyncDirectoryPresenter(directory: directory, onChange: onChange)
        presenter = observer
        NSFileCoordinator.addFilePresenter(observer)
    }

    func read<Payload: Codable>(_ domain: Domain, as type: Payload.Type, connectionID: UUID) throws -> [SyncRecord<Payload>] {
        guard self.connectionID == connectionID, let directory else { throw CancellationError() }
        let devices: [URL] = try coordinate(directory, writing: false) { root in
            let devices = root.appendingPathComponent("Devices", isDirectory: true)
            guard FileManager.default.fileExists(atPath: devices.path) else { return [] }
            return try FileManager.default.contentsOfDirectory(at: devices, includingPropertiesForKeys: nil)
                .filter { UUID(uuidString: $0.lastPathComponent) != nil }
        }
        decodedFiles = decodedFiles.filter { FileManager.default.fileExists(atPath: $0.key.path) }
        return try devices.flatMap { device -> [SyncRecord<Payload>] in
            let file = device.appendingPathComponent(domain.rawValue).appendingPathExtension("json")
            guard FileManager.default.fileExists(atPath: file.path) else { return [] }
            do {
                return try coordinate(file, writing: false) { url in
                    let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
                    let records = try ([url] + versions.map(\.url)).map { versionURL -> SyncRecord<Payload> in
                        let record: SyncRecord<Payload> = try self.readRecord(at: versionURL)
                        guard record.id.uuidString == device.lastPathComponent else { throw SyncError.invalidRecord }
                        return record
                    }
                    self.conflicts[url] = versions
                    return records
                }
            } catch {
                // Login devices are independent. A malformed or unavailable file
                // cannot revoke other devices' valid accounts; retry it next round.
                guard domain == .login else { throw error }
                log.error("Could not read login for device \(device.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return []
            }
        }
    }

    /// Cache only successfully decoded content. File generations identify in-place
    /// edits; resource identity also detects atomic replacements. Providers without
    /// these identifiers compare bytes, rather than trusting timestamps or size.
    private func readRecord<Payload: Codable>(at url: URL) throws -> SyncRecord<Payload> {
        do {
            let values = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey,
                                                         .fileResourceIdentifierKey, .generationIdentifierKey])
            if values.ubiquitousItemDownloadingStatus == .notDownloaded {
                try FileManager.default.startDownloadingUbiquitousItem(at: url)
                throw SyncError.downloading
            }
            let stamp: FileStamp?
            if let identity = values.fileResourceIdentifier, let generation = values.generationIdentifier {
                stamp = FileStamp(identity: identity, generation: generation)
            } else { stamp = nil }
            if let stamp, let cached = decodedFiles[url], cached.stamp == stamp,
               let record = cached.record as? SyncRecord<Payload> { return record }
            let data = try Data(contentsOf: url)
            if let cached = decodedFiles[url], cached.data == data,
               let record = cached.record as? SyncRecord<Payload> {
                decodedFiles[url] = CachedRecord(stamp: stamp, data: data, record: record)
                return record
            }
            let record: SyncRecord<Payload>
            do { record = try JSONDecoder().decode(SyncRecord<Payload>.self, from: data) }
            catch is DecodingError { throw SyncError.invalidRecord }
            decodedFiles[url] = CachedRecord(stamp: stamp, data: data, record: record)
            return record
        } catch {
            decodedFiles[url] = nil
            throw error
        }
    }

    func write<Payload: Codable>(_ record: SyncRecord<Payload>, domain: Domain, connectionID: UUID) throws {
        guard self.connectionID == connectionID, let directory else { throw CancellationError() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(record)
        let device = directory.appendingPathComponent("Devices", isDirectory: true)
            .appendingPathComponent(record.id.uuidString, isDirectory: true)
        try coordinate(device, writing: true) { url in
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let file = device.appendingPathComponent(domain.rawValue).appendingPathExtension("json")
        try coordinate(file, writing: true) { url in
            try data.write(to: url, options: .atomic)
            self.decodedFiles[url] = nil
            // Only retire conflict versions already read into the domain merge;
            // a version that arrived since the read must survive the next cycle.
            for version in self.conflicts[url] ?? [] {
                version.isResolved = true
                try version.remove()
                self.decodedFiles[version.url] = nil
            }
            self.conflicts[url] = nil
        }
    }

    func readPlayback(connectionID: UUID) throws -> (records: [SyncRecord<PlaybackSession>], waitingForQueues: Bool, counter: UInt64) {
        let checkpoints = try read(.playback, as: PlaybackCheckpoint.self, connectionID: connectionID)
        guard let directory else { throw CancellationError() }
        let latest = Dictionary(grouping: checkpoints, by: \.id).values.compactMap {
            $0.max { $0.revision < $1.revision }
        }
        let activeDevices = Set(latest.filter { $0.payload != nil }.map(\.id))
        completePlayback = completePlayback.filter { activeDevices.contains($0.key) }
        var neededQueues: Set<URL> = []
        defer {
            // Complete sessions retain their arrays directly. Decoded historical
            // queue files must not accumulate for the on-disk retention period.
            decodedFiles = decodedFiles.filter {
                $0.key.deletingLastPathComponent().lastPathComponent != "Queues" || neededQueues.contains($0.key)
            }
        }
        var records: [SyncRecord<PlaybackSession>] = []
        var waiting = false
        for record in latest {
            guard let checkpoint = record.payload else {
                records.append(SyncRecord(revision: record.revision, deviceName: record.deviceName,
                                          updatedAt: record.updatedAt, payload: nil))
                continue
            }
            let file = directory.appendingPathComponent("Devices/\(record.id.uuidString)/Queues")
                .appendingPathComponent(checkpoint.queueRevision.uuidString).appendingPathExtension("json")
            neededQueues.insert(file)
            do {
                let snapshot = try readQueue(at: file, for: record.revision)
                let session = try checkpoint.session(using: snapshot)
                let complete = SyncRecord(revision: record.revision, deviceName: record.deviceName,
                                          updatedAt: record.updatedAt, payload: session)
                completePlayback[record.id] = complete
                records.append(complete)
            } catch SyncError.downloading {
                // The pointer can arrive before its immutable queue. Keep only
                // an already complete session; never combine it with another queue.
                waiting = true
                if let previous = completePlayback[record.id] { records.append(previous) }
            }
        }
        // Observe even incomplete checkpoints before publishing a new revision
        // after reinstall. An unavailable queue must not reset the device clock.
        return (records, waiting, checkpoints.reduce(0) { max($0, $1.revision.counter) })
    }

    private func readQueue(at file: URL, for revision: SyncRevision) throws -> PlaybackQueueSnapshot {
        guard FileManager.default.fileExists(atPath: file.path) else { throw SyncError.downloading }
        let queue: SyncRecord<PlaybackQueueSnapshot> = try coordinate(file, writing: false) { url in
            guard NSFileVersion.unresolvedConflictVersionsOfItem(at: url)?.isEmpty != false else {
                throw SyncError.invalidRecord
            }
            return try self.readRecord(at: url)
        }
        guard queue.id == revision.deviceID, queue.revision <= revision,
              let snapshot = queue.payload else { throw SyncError.invalidRecord }
        return snapshot
    }

    func writePlayback(_ record: SyncRecord<PlaybackSession>, connectionID: UUID) throws {
        guard self.connectionID == connectionID, let directory else { throw CancellationError() }
        guard let session = record.payload else {
            let tombstone = SyncRecord<PlaybackCheckpoint>(revision: record.revision, deviceName: record.deviceName,
                                                            updatedAt: record.updatedAt, payload: nil)
            try write(tombstone, domain: .playback, connectionID: connectionID)
            return
        }
        guard RepeatMode(rawValue: session.repeatMode) != nil else { throw SyncError.invalidRecord }
        try PlaybackSession.validatePosition(session.currentIndex, progress: session.progress, count: session.orderedQueue.count)
        let snapshot = PlaybackQueueSnapshot(session)
        if publishedQueues[record.id] == nil {
            // Reconstruct the local publication cache lazily, including after a
            // restart that publishes before its first all-device refresh.
            let pointer = directory.appendingPathComponent("Devices/\(record.id.uuidString)/playback.json")
            if FileManager.default.fileExists(atPath: pointer.path) {
                let existing: SyncRecord<PlaybackCheckpoint>? = try coordinate(pointer, writing: false) { url in
                    let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
                    return try ([url] + versions.map(\.url)).map { version -> SyncRecord<PlaybackCheckpoint> in
                        let checkpoint: SyncRecord<PlaybackCheckpoint> = try self.readRecord(at: version)
                        guard checkpoint.id == record.id else { throw SyncError.invalidRecord }
                        return checkpoint
                    }.max { $0.revision < $1.revision }
                }
                if let existing, let checkpoint = existing.payload {
                    let file = directory.appendingPathComponent(
                        "Devices/\(record.id.uuidString)/Queues/\(checkpoint.queueRevision.uuidString).json")
                    if FileManager.default.fileExists(atPath: file.path) {
                        let restored = try readQueue(at: file, for: existing.revision)
                        _ = try checkpoint.session(using: restored)
                        publishedQueues[record.id] = PublishedQueue(revision: checkpoint.queueRevision, snapshot: restored,
                                                                   previousRevision: nil)
                    } else {
                        // Reuse is optional for a missing queue. The validated
                        // local session can publish a new snapshot and pointer.
                        // Existing placeholders and malformed files still fail
                        // through readQueue instead of being treated as absent.
                        log.notice("Published queue \(checkpoint.queueRevision.uuidString, privacy: .public) is missing; publishing the local session")
                    }
                }
            }
        }
        let previous = publishedQueues[record.id]
        let queueRevision: UUID
        if let previous, previous.snapshot == snapshot,
           FileManager.default.fileExists(atPath: directory.appendingPathComponent(
            "Devices/\(record.id.uuidString)/Queues/\(previous.revision.uuidString).json").path) {
            queueRevision = previous.revision
        } else {
            queueRevision = UUID()
            let folder = directory.appendingPathComponent("Devices/\(record.id.uuidString)/Queues", isDirectory: true)
            let queueRecord = SyncRecord(revision: record.revision, deviceName: record.deviceName, payload: snapshot)
            let data = try JSONEncoder().encode(queueRecord)
            try coordinate(folder, writing: true) { url in
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
            let file = folder.appendingPathComponent(queueRevision.uuidString).appendingPathExtension("json")
            try coordinate(file, writing: true) { try data.write(to: $0, options: .atomic) }
            publishedQueues[record.id] = PublishedQueue(revision: queueRevision, snapshot: snapshot,
                                                       previousRevision: previous?.revision)
        }
        // Publish the immutable queue first, then atomically replace its pointer.
        let checkpoint = SyncRecord(revision: record.revision, deviceName: record.deviceName,
                                    updatedAt: record.updatedAt, payload: PlaybackCheckpoint(session, queueRevision: queueRevision))
        try write(checkpoint, domain: .playback, connectionID: connectionID)
        let instant = now()
        if lastQueueCleanup[record.id].map({ $0.duration(to: instant) >= .seconds(24 * 60 * 60) }) ?? true {
            try removeExpiredQueues(for: record.id, connectionID: connectionID)
            // Update only on success so the next publication retries failures.
            lastQueueCleanup[record.id] = instant
        }
    }

    private func removeExpiredQueues(for deviceID: UUID, connectionID: UUID) throws {
        guard self.connectionID == connectionID, let directory else { throw CancellationError() }
        let device = directory.appendingPathComponent("Devices/\(deviceID.uuidString)")
        let checkpoint = device.appendingPathComponent("playback.json")
        // Re-read current/conflicting pointers under coordination before deleting.
        // An unreadable pointer prevents cleanup, rather than guessing ownership.
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        let folder = device.appendingPathComponent("Queues", isDirectory: true)
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var cleanup: Result<Void, Error>?
        // Hold both items for the entire operation: a new pointer/conflict must
        // not arrive between gathering references and removing queue files.
        coordinator.coordinate(readingItemAt: checkpoint, options: [], writingItemAt: folder, options: [],
                               error: &coordinationError) { pointer, queues in
            cleanup = Result {
                let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: pointer) ?? []
                var retained = try Set(([pointer] + versions.map(\.url)).compactMap { version -> UUID? in
                    let record: SyncRecord<PlaybackCheckpoint> = try self.readRecord(at: version)
                    guard record.id == deviceID else { throw SyncError.invalidRecord }
                    return record.payload?.queueRevision
                })
                if let previous = self.publishedQueues[deviceID]?.previousRevision { retained.insert(previous) }
                let files = try FileManager.default.contentsOfDirectory(at: queues, includingPropertiesForKeys: [.contentModificationDateKey])
                for file in files where file.pathExtension == "json" {
                    guard let revision = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                          !retained.contains(revision) else { continue }
                    guard let modified = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
                        throw SyncError.unavailable
                    }
                    if modified < cutoff {
                        try FileManager.default.removeItem(at: file)
                        self.decodedFiles[file] = nil
                    }
                }
            }
        }
        if let coordinationError { throw coordinationError }
        guard let cleanup else { throw SyncError.unavailable }
        try cleanup.get()
    }

    private func validateRepository(at directory: URL) throws {
        let file = directory.appendingPathComponent("repository.json")
        try coordinate(file, writing: true) { url in
            if FileManager.default.fileExists(atPath: url.path) {
                do {
                    let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
                    guard manifest.application == "Kumone" else { throw SyncError.invalidRecord }
                    guard manifest.schemaVersion == 1 else { throw SyncError.newerVersion }
                } catch is DecodingError { throw SyncError.invalidRecord }
            } else {
                let manifest = Manifest(application: "Kumone", schemaVersion: 1)
                try JSONEncoder().encode(manifest).write(to: url, options: .atomic)
            }
        }
    }

    private func coordinate<T>(_ url: URL, writing: Bool, access: @escaping (URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<T, Error>?
        let accessor: (URL) -> Void = { coordinatedURL in
            result = Result { try access(coordinatedURL) }
        }
        if writing {
            coordinator.coordinate(writingItemAt: url, options: [], error: &coordinationError, byAccessor: accessor)
        } else {
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError, byAccessor: accessor)
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw SyncError.unavailable }
        return try result.get()
    }
}

private final class SyncDirectoryPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    private let onChange: @Sendable (URL) -> Void

    init(directory: URL, onChange: @escaping @Sendable (URL) -> Void) {
        presentedItemURL = directory
        self.onChange = onChange
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        presentedItemOperationQueue = queue
        super.init()
    }

    func presentedItemDidChange() {
        if let presentedItemURL { onChange(presentedItemURL) }
    }
    func presentedSubitemDidChange(at url: URL) { onChange(url) }
    func presentedSubitemDidAppear(at url: URL) { onChange(url) }
    func presentedItemDidMove(to newURL: URL) { onChange(newURL) }
}
