import Combine
import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

@MainActor
final class SyncService: ObservableObject {
    static let shared = SyncService(defaults: .standard)

    @Published private(set) var enabled: Bool
    @Published private(set) var loginEnabled: Bool
    @Published private(set) var sessions: [SyncRecord<PlaybackSession>] = []
    @Published private(set) var logins: [SyncRecord<SyncedLogin>] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var connected = false
    @Published private(set) var importingLogin = false

    private let repository = SyncRepository()
    private let defaults: UserDefaults
    // Loaded before connecting; an inaccessible identity must not publish a new device.
    private var deviceID = UUID()
    private let deviceIdentity: @Sendable () async throws -> UUID
    private let playbackContext: @MainActor () -> (session: PlaybackSession?, accountID: Int?)
    private let deviceName: String
    private var counter: UInt64
    private var preferences: SyncedPreferences
    private var observedPreferences: [String: PreferenceValue]
    private var lastPlayback: PlaybackSession?
    private var hasPublishedPlayback = false
    private var lastLogin: SyncedLogin?
    private var hasPublishedLogin = false
    private var subscriptions: Set<AnyCancellable> = []
    private var refreshTask: Task<Void, Never>?
    private var changeTask: Task<Void, Never>?
    private var directoryTask: Task<Void, Never>?
    private var directoryDomains: Set<SyncRepository.Domain> = []
    private var connectionID = UUID()
    private var started = false
    private var syncing = false
    private var syncPending = false
    private var playbackPending = false
    private var foreground = true
    private var preferencesNeedUpload = false
    private var domainsNeedingRead = Set(SyncRepository.Domain.allCases)
    private var remoteLogins: [SyncRecord<SyncedLogin>] = []

    private enum Keys {
        static let enabled = "sync.enabled"
        static let login = "sync.publishLogin"
        static let counter = "sync.counter"
        static let bookmark = "sync.directoryBookmark"
        static let preferences = "sync.preferences"
        static let identity = "sync.iCloudIdentity"
    }

    private struct LocalPreferences: Codable {
        let edits: SyncedPreferences
        let observed: [String: PreferenceValue]
    }

    init(defaults: UserDefaults, deviceIdentity: @escaping @Sendable () async throws -> UUID = {
        try await SyncDeviceIdentity.load()
    }, playbackContext: @escaping @MainActor () -> (session: PlaybackSession?, accountID: Int?) = {
        (PlayerService.shared.playbackSession, AccountStore.shared.authenticatedAccountID)
    }) {
        self.defaults = defaults
        self.deviceIdentity = deviceIdentity
        self.playbackContext = playbackContext
        enabled = defaults.bool(forKey: Keys.enabled)
        loginEnabled = defaults.bool(forKey: Keys.login)
        #if os(iOS)
        deviceName = UIDevice.current.name
        #else
        deviceName = Host.current().localizedName ?? "Mac"
        #endif
        counter = (defaults.object(forKey: Keys.counter) as? NSNumber)?.uint64Value ?? 0
        preferences = SyncedPreferences()
        observedPreferences = SettingsManager.shared.syncPreferences
        do {
            if let data = defaults.data(forKey: Keys.preferences) {
                let saved = try JSONDecoder().decode(LocalPreferences.self, from: data)
                preferences = saved.edits
                observedPreferences = saved.observed
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func start() async {
        guard !started else { return }
        started = true
        NotificationCenter.default.publisher(for: .NSUbiquityIdentityDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.disconnectChangedIdentity() }
            }.store(in: &subscriptions)
        let player = PlayerService.shared
        var playbackChanges = [
            player.$currentTrack.map { _ in () }.eraseToAnyPublisher(),
            player.$isPlaying.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            player.$queue.map { _ in () }.eraseToAnyPublisher(),
            player.$shuffledQueue.map { _ in () }.eraseToAnyPublisher(),
            player.$playNextList.map { _ in () }.eraseToAnyPublisher(),
            player.$currentIndex.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            player.$source.map { _ in () }.eraseToAnyPublisher(),
            player.$repeatMode.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            player.$isFMMode.removeDuplicates().map { _ in () }.eraseToAnyPublisher()
        ]
        #if os(macOS)
        playbackChanges.append(player.$queueOrder.removeDuplicates().map { _ in () }.eraseToAnyPublisher())
        playbackChanges.append(player.$autoMixQueue.map { _ in () }.eraseToAnyPublisher())
        #else
        playbackChanges.append(player.$shuffleEnabled.removeDuplicates().map { _ in () }.eraseToAnyPublisher())
        #endif
        let settings = SettingsManager.shared
        let account = AccountStore.shared
        let changes = Publishers.MergeMany(playbackChanges + [
            settings.$audioQuality.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            settings.$appearance.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            settings.$showLyricsTranslation.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            settings.$lyricsAnnotation.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            settings.$verbatimLyrics.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            settings.$enableUnblock.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            settings.$enabledAudioSourceIDs.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            settings.$showMainWindowAmbientBackground.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            settings.$mainWindowAmbientBackgroundIntensity.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            account.$profile.map { _ in () }.eraseToAnyPublisher(),
            account.$isBootstrapped.removeDuplicates().map { _ in () }.eraseToAnyPublisher()
        ])
        changes.sink { [weak self] in
            guard let self, self.enabled, self.connected else { return }
            self.changeTask?.cancel()
            self.changeTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(600)) }
                catch { return }
                guard let self, self.enabled, self.connected else { return }
                await self.synchronize(refreshing: [])
                self.scheduleRefresh()
            }
        }.store(in: &subscriptions)
        guard enabled else { return }
        if await disconnectChangedIdentity() { return }
        do { _ = try await enable() }
        catch is CancellationError { return }
        catch { errorMessage = error.localizedDescription }
    }

    /// Returns false when directory authorization is needed. The caller presents
    /// the platform picker directly, without a second confirmation screen.
    func enable() async throws -> Bool {
        let connection = UUID()
        connectionID = connection
        connected = false
        sessions = []
        logins = []
        do {
            let identity = try await deviceIdentity()
            guard connectionID == connection else { throw CancellationError() }
            deviceID = identity
            if let bookmark = defaults.data(forKey: Keys.bookmark) {
                let refreshed = try await repository.restore(bookmark: bookmark, connectionID: connection)
                guard connectionID == connection else { throw CancellationError() }
                defaults.set(refreshed, forKey: Keys.bookmark)
            } else if try await !repository.connectContainer(connectionID: connection) {
                guard connectionID == connection else { throw CancellationError() }
                return false
            }
            try await activateConnection(connection)
            return true
        } catch {
            guard connectionID == connection else { throw CancellationError() }
            connected = false
            throw error
        }
    }

    func connect(to directory: URL) async {
        let connection = UUID()
        connectionID = connection
        connected = false
        sessions = []
        logins = []
        do {
            let identity = try await deviceIdentity()
            guard connectionID == connection else { return }
            deviceID = identity
            let bookmark = try await repository.connect(to: directory, connectionID: connection)
            guard connectionID == connection else { return }
            defaults.set(bookmark, forKey: Keys.bookmark)
            try await activateConnection(connection)
        } catch {
            guard connectionID == connection else { return }
            connected = false
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func disable() async -> Bool {
        let previous = connectionID
        let disabled = UUID()
        connectionID = disabled
        enabled = false
        connected = false
        defaults.set(false, forKey: Keys.enabled)
        refreshTask?.cancel()
        refreshTask = nil
        changeTask?.cancel()
        changeTask = nil
        directoryTask?.cancel()
        directoryTask = nil
        await repository.disconnect(connectionID: previous)
        guard connectionID == disabled else { return false }
        sessions = []
        logins = []
        remoteLogins = []
        lastLogin = nil
        errorMessage = nil
        return true
    }

    /// A connection owns its observers and publication checkpoints. Both restored
    /// authorization and a newly selected folder enter through this same boundary.
    private func activateConnection(_ connection: UUID) async throws {
        guard connectionID == connection else { throw CancellationError() }
        try rememberIdentity()
        connected = true
        enabled = true
        defaults.set(true, forKey: Keys.enabled)
        lastPlayback = nil
        hasPublishedPlayback = false
        lastLogin = nil
        hasPublishedLogin = false
        preferencesNeedUpload = true
        directoryTask?.cancel()
        directoryTask = nil
        directoryDomains.removeAll()
        domainsNeedingRead = Set(SyncRepository.Domain.allCases)
        remoteLogins = []
        await observeDirectory()
        await synchronize()
        guard connectionID == connection, enabled else { throw CancellationError() }
        scheduleRefresh()
    }

    func setForeground(_ active: Bool) async {
        foreground = active
        guard enabled, connected else { return }
        await synchronize()
        scheduleRefresh()
    }

    func setLoginEnabled(_ enabled: Bool) async {
        loginEnabled = enabled
        defaults.set(enabled, forKey: Keys.login)
        lastLogin = nil
        await synchronize()
    }

    func resume(_ record: SyncRecord<PlaybackSession>) throws {
        guard let session = record.payload else {
            throw SyncError.invalidRecord
        }
        try PlayerService.shared.resume(session)
    }

    @discardableResult
    func importLogin(_ record: SyncRecord<SyncedLogin>) async throws -> Bool {
        guard !importingLogin else { return false }
        let connection = connectionID
        importingLogin = true
        defer { importingLogin = false }
        guard let login = record.payload else { throw SyncError.invalidRecord }
        try await AccountStore.shared.importLogin(login, authorization: {
            self.enabled && self.connected && self.connectionID == connection
                && AccountStore.shared.isBootstrapped && AccountStore.shared.authenticatedAccountID == nil
                && self.logins.contains { $0.revision == record.revision }
        })
        // Receiving a login also authorizes this device to share it back.
        // Commit consent only after verification and credential persistence.
        loginEnabled = true
        defaults.set(true, forKey: Keys.login)
        lastLogin = nil
        await synchronize()
        Task { await AccountStore.shared.refreshLibrary() }
        return AccountStore.shared.authenticatedAccountID == login.accountID
    }

    func synchronize(publishingPlayback: Bool = true,
                     refreshing domains: Set<SyncRepository.Domain> = Set(SyncRepository.Domain.allCases)) async {
        guard enabled, connected else { return }
        domainsNeedingRead.formUnion(domains)
        syncPending = true
        playbackPending = playbackPending || publishingPlayback
        if syncing { return }
        syncing = true
        defer {
            syncing = false
            // A replaced connection can return early while its pending round waits.
            if syncPending, enabled, connected {
                Task { await synchronize(publishingPlayback: false, refreshing: []) }
            }
        }
        repeat {
            syncPending = false
            let publishPlayback = playbackPending
            playbackPending = false
            let connection = connectionID
            let reads = domainsNeedingRead
            domainsNeedingRead.removeAll()
            var failures: [String] = []
            do {
                try capturePreferenceChanges()
                if reads.contains(.preferences) {
                    let records = try await repository.read(.preferences, as: SyncedPreferences.self, connectionID: connection)
                    guard enabled, connection == connectionID else { return }
                    for record in records {
                        counter = max(counter, record.revision.counter)
                        if let incoming = record.payload {
                            for edit in incoming.fields.values { counter = max(counter, edit.revision.counter) }
                        }
                    }
                    // Observe remote revisions before stamping edits made during the read.
                    try capturePreferenceChanges()
                    let previousPreferences = preferences
                    let previousObserved = observedPreferences
                    var merged = preferences
                    for record in records {
                        if let incoming = record.payload { merged.merge(incoming) }
                    }
                    // Invalid remote values must not poison the last valid local projection.
                    try SettingsManager.shared.applySyncPreferences(merged)
                    preferences = merged
                    observedPreferences = SettingsManager.shared.syncPreferences
                    if preferences != previousPreferences || observedPreferences != previousObserved {
                        try savePreferences()
                    }
                }
                // Only fill absent fields after the first remote read. Starting a
                // fresh installation must not overwrite existing cloud preferences.
                for (key, value) in observedPreferences where preferences.fields[key] == nil {
                    preferences.fields[key] = PreferenceEdit(value: value, revision: try nextRevision())
                    preferencesNeedUpload = true
                }
                if preferencesNeedUpload {
                    let uploadedPreferences = preferences
                    let record = try makeRecord(uploadedPreferences)
                    try await repository.write(record, domain: .preferences, connectionID: connection)
                    guard enabled, connection == connectionID else { return }
                    preferencesNeedUpload = preferences != uploadedPreferences
                    try savePreferences()
                }
            } catch {
                guard enabled, connection == connectionID else { return }
                domainsNeedingRead.insert(.preferences)
                failures.append(error.localizedDescription)
            }

            do {
                if reads.contains(.playback) {
                    let received = try await repository.readPlayback(connectionID: connection)
                    guard enabled, connection == connectionID else { return }
                    let records = received.records
                    counter = max(counter, received.counter)
                    hasPublishedPlayback = received.activeDevices.contains(deviceID)
                    if received.waitingForQueues {
                        domainsNeedingRead.insert(.playback)
                        failures.append(SyncError.downloading.localizedDescription)
                    }
                    let incoming = records.filter { $0.id != deviceID && $0.payload != nil }
                        .sorted { $0.updatedAt > $1.updatedAt }
                    if !sessions.elementsEqual(incoming, by: { $0.revision == $1.revision }) { sessions = incoming }
                }
                if publishPlayback {
                    let context = playbackContext()
                    if let session = context.session,
                       let accountID = context.accountID, accountID > 0, session.accountID == accountID {
                        if session.progress != lastPlayback?.progress || session != lastPlayback {
                            let record = try makeRecord(session)
                            try await repository.writePlayback(record, connectionID: connection)
                            guard enabled, connection == connectionID else { return }
                            lastPlayback = session
                            hasPublishedPlayback = true
                        }
                    } else if hasPublishedPlayback {
                        let tombstone: SyncRecord<PlaybackSession> = try makeRecord(nil)
                        try await repository.writePlayback(tombstone, connectionID: connection)
                        guard enabled, connection == connectionID else { return }
                        lastPlayback = nil
                        hasPublishedPlayback = false
                    }
                }
            } catch {
                guard enabled, connection == connectionID else { return }
                domainsNeedingRead.insert(.playback)
                failures.append(error.localizedDescription)
            }

            do {
                if reads.contains(.login) {
                    let records = try await repository.read(.login, as: SyncedLogin.self, connectionID: connection)
                    guard enabled, connection == connectionID else { return }
                    remoteLogins = records
                    for record in records { counter = max(counter, record.revision.counter) }
                    let incoming = SyncedLogin.availableAccounts(in: records, excluding: deviceID)
                    if !logins.elementsEqual(incoming, by: { $0.revision == $1.revision }) { logins = incoming }
                }
                let previousLogin = remoteLogins.filter { $0.id == deviceID }.max { $0.revision < $1.revision }
                if loginEnabled, let profile = AccountStore.shared.profile,
                   AccountStore.shared.authenticatedAccountID == profile.userId {
                    let login = SyncedLogin(accountID: profile.userId, nickname: profile.nickname,
                                            cookies: NeteaseClient.shared.authenticationCookies())
                    try login.validate()
                    if login != lastLogin || previousLogin?.payload != login {
                        let record = try makeRecord(login)
                        try await repository.write(record, domain: .login, connectionID: connection)
                        guard enabled, connection == connectionID else { return }
                        remoteLogins.removeAll { $0.id == deviceID }
                        remoteLogins.append(record)
                        lastLogin = login
                        hasPublishedLogin = true
                    }
                } else if (!loginEnabled || !AccountStore.shared.hasAuthCookie),
                          hasPublishedLogin || previousLogin?.payload != nil {
                    let tombstone: SyncRecord<SyncedLogin> = try makeRecord(nil)
                    try await repository.write(tombstone, domain: .login, connectionID: connection)
                    guard enabled, connection == connectionID else { return }
                    remoteLogins.removeAll { $0.id == deviceID }
                    remoteLogins.append(tombstone)
                    hasPublishedLogin = false
                    lastLogin = nil
                }
            } catch {
                guard enabled, connection == connectionID else { return }
                domainsNeedingRead.insert(.login)
                // Credentials are no longer offered when their repository cannot be read.
                logins = []
                failures.append(error.localizedDescription)
            }
            errorMessage = failures.isEmpty ? nil : Array(Set(failures)).sorted().joined(separator: "\n")
        } while syncPending && enabled && connected
    }

    private func nextRevision() throws -> SyncRevision {
        let (next, overflow) = counter.addingReportingOverflow(1)
        guard !overflow else { throw SyncError.invalidRecord }
        counter = next
        defaults.set(NSNumber(value: counter), forKey: Keys.counter)
        return SyncRevision(counter: counter, deviceID: deviceID)
    }

    private func makeRecord<T: Codable>(_ payload: T?) throws -> SyncRecord<T> {
        SyncRecord(revision: try nextRevision(), deviceName: deviceName, payload: payload)
    }

    private func capturePreferenceChanges() throws {
        let current = SettingsManager.shared.syncPreferences
        guard current != observedPreferences else { return }
        for (key, value) in current where observedPreferences[key] != value {
            preferences.fields[key] = PreferenceEdit(value: value, revision: try nextRevision())
            preferencesNeedUpload = true
        }
        observedPreferences = current
        try savePreferences()
    }

    private func savePreferences() throws {
        let saved = LocalPreferences(edits: preferences, observed: observedPreferences)
        defaults.set(try JSONEncoder().encode(saved), forKey: Keys.preferences)
    }

    private func scheduleRefresh() {
        guard foreground || PlayerService.shared.isPlaying, enabled, connected else {
            refreshTask?.cancel()
            refreshTask = nil
            return
        }
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(20)) }
                catch { return }
                guard let self else { return }
                await self.synchronize()
            }
        }
    }

    private func observeDirectory() async {
        let connection = connectionID
        await repository.observeChanges { [weak self] url in
            Task { @MainActor in
                guard let self, self.enabled, self.connected, self.connectionID == connection,
                      self.foreground || PlayerService.shared.isPlaying else { return }
                if url.lastPathComponent == "Queues" || url.deletingLastPathComponent().lastPathComponent == "Queues" {
                    self.directoryDomains.insert(.playback)
                } else if let domain = SyncRepository.Domain(rawValue: url.deletingPathExtension().lastPathComponent) {
                    self.directoryDomains.insert(domain)
                } else {
                    self.directoryDomains.formUnion(SyncRepository.Domain.allCases)
                }
                // Collect a burst in one bounded window, including our own writes.
                guard self.directoryTask == nil else { return }
                self.directoryTask = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(600)) }
                    catch { return }
                    guard let self, self.enabled, self.connected, self.connectionID == connection else { return }
                    let domains = self.directoryDomains
                    self.directoryDomains.removeAll()
                    self.directoryTask = nil
                    await self.synchronize(publishingPlayback: false, refreshing: domains)
                }
            }
        }
    }

    private func rememberIdentity() throws {
        if let token = FileManager.default.ubiquityIdentityToken {
            defaults.set(try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: false),
                         forKey: Keys.identity)
        } else { defaults.removeObject(forKey: Keys.identity) }
    }

    @discardableResult
    private func disconnectChangedIdentity() async -> Bool {
        guard let saved = defaults.data(forKey: Keys.identity) else { return false }
        do {
            // Apple's opaque identity token promises NSCoding, not NSSecureCoding.
            // Only decode this app's locally archived token, never repository data.
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: saved)
            unarchiver.requiresSecureCoding = false
            defer { unarchiver.finishDecoding() }
            guard let previous = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? NSObjectProtocol else {
                throw SyncError.invalidRecord
            }
            if let current = FileManager.default.ubiquityIdentityToken, previous.isEqual(current) { return false }
            guard await disable() else { return false }
            loginEnabled = false
            defaults.set(false, forKey: Keys.login)
            defaults.removeObject(forKey: Keys.bookmark)
            defaults.removeObject(forKey: Keys.identity)
            errorMessage = SyncError.identityChanged.localizedDescription
            return true
        } catch {
            guard await disable() else { return false }
            errorMessage = error.localizedDescription
            return true
        }
    }
}
