import Foundation

/// Device records supply publication comparisons. Withdrawal responsibility
/// survives a later read that skips this device's temporarily unreadable file.
@MainActor
final class LoginSync {
    private var cachedLoginRecords: [SyncRecord<SyncedLogin>] = []
    private var hasPublishedLogin = false

    func resetConnection() {
        cachedLoginRecords = []
        hasPublishedLogin = false
    }

    func read(repository: SyncRepository, connectionID: UUID, clock: SyncRevisionClock) async throws {
        try Task.checkCancellation()
        let records = try await repository.read(.login, as: SyncedLogin.self, connectionID: connectionID)
        try Task.checkCancellation()
        cachedLoginRecords = records
        for record in records { clock.observe(record.revision.counter) }
        if let latestLocalRecord = records.lazy.filter({ $0.id == clock.deviceID }).max(by: { $0.revision < $1.revision }) {
            hasPublishedLogin = latestLocalRecord.payload != nil
        }
    }

    func publish(
        enabled isLoginSyncEnabled: Bool, repository: SyncRepository, connectionID: UUID,
        clock: SyncRevisionClock
    ) async throws -> [SyncRecord<SyncedLogin>] {
        try Task.checkCancellation()
        let previousLocalRecord = cachedLoginRecords.lazy.filter { $0.id == clock.deviceID }.max { $0.revision < $1.revision }
        let accountStore = AccountStore.shared
        let outgoingLogin: SyncedLogin?
        if isLoginSyncEnabled, let profile = accountStore.profile, accountStore.authenticatedAccountID == profile.userId {
            let login = SyncedLogin(
                accountID: profile.userId, nickname: profile.nickname,
                cookies: NeteaseClient.shared.authenticationCookies())
            try login.validate()
            outgoingLogin = login
        } else if !isLoginSyncEnabled || !accountStore.hasAuthCookie {
            outgoingLogin = nil
        } else {
            // Bootstrap has not verified the local cookie's account yet. Keep
            // the published offer until authentication becomes authoritative.
            return SyncedLogin.availableAccounts(in: cachedLoginRecords, excluding: clock.deviceID)
        }
        if previousLocalRecord?.payload != outgoingLogin || (outgoingLogin == nil && hasPublishedLogin) {
            let record = try clock.makeRecord(outgoingLogin)
            try await repository.write(record, domain: .login, connectionID: connectionID)
            try Task.checkCancellation()
            cachedLoginRecords.removeAll { $0.id == clock.deviceID }
            cachedLoginRecords.append(record)
            hasPublishedLogin = outgoingLogin != nil
        }
        clock.persistCounter()
        return SyncedLogin.availableAccounts(in: cachedLoginRecords, excluding: clock.deviceID)
    }
}
