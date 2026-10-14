import Foundation
import os

/// Enqueue snapshots at the call site so an older asynchronous write cannot
/// overwrite a later pause/seek checkpoint.
enum PlaybackStateStorage {
    private static let queue = DispatchQueue(label: "im.missuo.kumone.playback-state", qos: .utility)
    private static let log = Logger(subsystem: "im.missuo.kumone", category: "playback-state")

    static func save<T: Encodable>(_ state: T, to url: URL) {
        queue.async {
            do {
                let data = try JSONEncoder().encode(state)
                try data.write(to: url, options: .atomic)
            } catch {
                log.error("Playback checkpoint write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Finish queued local writes before normal application termination.
    static func flush() {
        queue.sync {}
    }
}
