import Foundation
import os

/// Playback storage rules run in the repository's isolation, keeping cross-file
/// operations ordered with other domains without adding another actor or task.
struct PlaybackSyncStore {
    struct ReadResult {
        let records: [SyncRecord<PlaybackSession>]
        let waitingForQueues: Bool
        let counter: UInt64
        // Raw checkpoints retain publication status even when their queue is
        // unavailable, so sign-out can still withdraw this device's old offer.
        let activeDevices: Set<UUID>
    }
    private let log = Logger(subsystem: "im.missuo.kumone", category: "playback-sync-store")
    private struct PublishedQueue {
        let revision: UUID
        let snapshot: PlaybackQueueSnapshot
        let previousRevision: UUID?
    }
    private var publishedQueues: [UUID: PublishedQueue] = [:]
    private var completePlayback: [UUID: SyncRecord<PlaybackSession>] = [:]
    private var lastQueueCleanup: [UUID: ContinuousClock.Instant] = [:]
    private let now: @Sendable () -> ContinuousClock.Instant
    private var cachedQueues: Set<URL> = []

    init(now: @escaping @Sendable () -> ContinuousClock.Instant) {
        self.now = now
    }

    mutating func reset() { self = Self(now: now) }

    mutating func read(from repository: isolated SyncRepository, directory: URL, connectionID: UUID) throws -> ReadResult {
        let checkpoints = try repository.read(.playback, as: PlaybackCheckpoint.self, connectionID: connectionID)
        let latest = Dictionary(grouping: checkpoints, by: \.id).values.compactMap {
            $0.max { $0.revision < $1.revision }
        }
        let activeDevices = Set(latest.filter { $0.payload != nil }.map(\.id))
        completePlayback = completePlayback.filter { activeDevices.contains($0.key) }
        var neededQueues: Set<URL> = []
        defer {
            // Complete sessions retain their arrays directly. Decoded historical
            // queue files must not accumulate for the on-disk retention period.
            for file in cachedQueues.subtracting(neededQueues) { repository.invalidateCache(at: file) }
            cachedQueues = neededQueues
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
                let snapshot = try readQueue(at: file, for: record.revision, repository: repository)
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
        return ReadResult(records: records, waitingForQueues: waiting,
                          counter: checkpoints.reduce(0) { max($0, $1.revision.counter) }, activeDevices: activeDevices)
    }

    private func readQueue(at file: URL, for revision: SyncRevision, repository: isolated SyncRepository) throws -> PlaybackQueueSnapshot {
        guard FileManager.default.fileExists(atPath: file.path) else { throw SyncError.downloading }
        let queue: SyncRecord<PlaybackQueueSnapshot> = try repository.coordinate(file, writing: false) { url in
            let records: [SyncRecord<PlaybackQueueSnapshot>] = try repository.readVersions(at: url)
            guard records.count == 1, let record = records.first else { throw SyncError.invalidRecord }
            return record
        }
        guard queue.id == revision.deviceID, queue.revision <= revision,
              let snapshot = queue.payload else { throw SyncError.invalidRecord }
        return snapshot
    }

    mutating func write(_ record: SyncRecord<PlaybackSession>, to repository: isolated SyncRepository, directory: URL, connectionID: UUID) throws {
        guard let session = record.payload else {
            let tombstone = SyncRecord<PlaybackCheckpoint>(revision: record.revision, deviceName: record.deviceName,
                                                            updatedAt: record.updatedAt, payload: nil)
            try repository.write(tombstone, domain: .playback, connectionID: connectionID)
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
                let existing: SyncRecord<PlaybackCheckpoint>? = try repository.coordinate(pointer, writing: false) { url in
                    let records: [SyncRecord<PlaybackCheckpoint>] = try repository.readVersions(at: url)
                    guard records.allSatisfy({ $0.id == record.id }) else { throw SyncError.invalidRecord }
                    return records.max { $0.revision < $1.revision }
                }
                if let existing, let checkpoint = existing.payload {
                    let file = directory.appendingPathComponent(
                        "Devices/\(record.id.uuidString)/Queues/\(checkpoint.queueRevision.uuidString).json")
                    if FileManager.default.fileExists(atPath: file.path) {
                        let restored = try readQueue(at: file, for: existing.revision, repository: repository)
                        _ = try checkpoint.session(using: restored)
                        cachedQueues.insert(file)
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
            let file = folder.appendingPathComponent(queueRevision.uuidString).appendingPathExtension("json")
            try repository.write(queueRecord, to: file)
            cachedQueues.insert(file)
            publishedQueues[record.id] = PublishedQueue(revision: queueRevision, snapshot: snapshot,
                                                       previousRevision: previous?.revision)
        }
        // Publish the immutable queue first, then atomically replace its pointer.
        let checkpoint = SyncRecord(revision: record.revision, deviceName: record.deviceName,
                                    updatedAt: record.updatedAt, payload: PlaybackCheckpoint(session, queueRevision: queueRevision))
        try repository.write(checkpoint, domain: .playback, connectionID: connectionID)
        let instant = now()
        if lastQueueCleanup[record.id].map({ $0.duration(to: instant) >= .seconds(24 * 60 * 60) }) ?? true {
            try removeExpiredQueues(for: record.id, directory: directory, repository: repository)
            // Update only on success so the next publication retries failures.
            lastQueueCleanup[record.id] = instant
        }
    }

    private func removeExpiredQueues(for deviceID: UUID, directory: URL, repository: isolated SyncRepository) throws {
        let device = directory.appendingPathComponent("Devices/\(deviceID.uuidString)")
        let checkpoint = device.appendingPathComponent("playback.json")
        // Re-read current/conflicting pointers under coordination before deleting.
        // An unreadable pointer prevents cleanup, rather than guessing ownership.
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        let folder = device.appendingPathComponent("Queues", isDirectory: true)
        // Hold both items for the entire operation: a new pointer/conflict must
        // not arrive between gathering references and removing queue files.
        try repository.coordinate(reading: checkpoint, writing: folder) { pointer, queues in
            let records: [SyncRecord<PlaybackCheckpoint>] = try repository.readVersions(at: pointer)
            var retained = try Set(records.compactMap { record -> UUID? in
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
                    repository.invalidateCache(at: file)
                }
            }
        }
    }
}
