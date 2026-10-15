import Foundation
import os

/// Directory access is the trust boundary. These credentials have no separate
/// application-level encryption and are published only with explicit consent.
struct SyncedLogin: Codable, Equatable {
    let accountID: Int
    let nickname: String
    let cookies: [String: String]

    func validate() throws {
        guard accountID > 0, cookies["MUSIC_U"]?.isEmpty == false else { throw SyncError.invalidRecord }
    }

    private static let log = Logger(subsystem: "im.missuo.kumone", category: "login-sync")

    static func availableAccounts(in records: [SyncRecord<Self>], excluding deviceID: UUID) -> [SyncRecord<Self>] {
        // Resolve each device's deletion marker before collapsing duplicate accounts.
        let latest = Dictionary(grouping: records, by: \.id).values.compactMap {
            $0.max { $0.revision < $1.revision }
        }.filter { record in
            guard record.id != deviceID else { return false }
            do {
                guard let login = record.payload else { return false }
                try login.validate()
                return true
            } catch {
                // Never resurrect an older login when the latest record is invalid.
                log.error("Rejected login record for device \(record.id.uuidString, privacy: .public)")
                return false
            }
        }
        return Dictionary(grouping: latest, by: { $0.payload?.accountID }).values.compactMap {
            $0.max { $0.revision < $1.revision }
        }.sorted { $0.revision > $1.revision }
    }
}
