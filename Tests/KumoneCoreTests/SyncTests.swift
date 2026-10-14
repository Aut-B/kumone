import Foundation
import Security
import Testing
@testable import KumoneCore

@Suite("Cross-device sync")
struct SyncTests {
    @Test func deviceIdentityPersistsAcrossConcurrentAndSubsequentLoads() async throws {
        let keychainService = "kumone-sync-identity-test-\(UUID())"
        defer {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                      kSecAttrService as String: keychainService,
                                      kSecAttrAccount as String: "device-id"]
            SecItemDelete(query as CFDictionary)
        }
        async let first = SyncDeviceIdentity.load(service: keychainService)
        async let concurrent = SyncDeviceIdentity.load(service: keychainService)
        let (identity, other) = try await (first, concurrent)
        #expect(identity == other)
        #expect(try await SyncDeviceIdentity.load(service: keychainService) == identity)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: keychainService,
                                  kSecAttrAccount as String: "device-id"]
        #expect(SecItemDelete(query as CFDictionary) == errSecSuccess)
        // The process keeps its resolved identity without another Keychain read.
        #expect(try await SyncDeviceIdentity.load(service: keychainService) == identity)
    }

    @Test(arguments: ["malformed", "newer", "invalid-payload"])
    func oneInvalidLoginFileDoesNotHideOtherAccounts(failure: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-partial-login-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SyncRepository()
        let connection = UUID()
        _ = try await repository.connect(to: root, connectionID: connection)
        let login = SyncedLogin(accountID: 42, nickname: "Fixture", cookies: ["MUSIC_U": "synthetic-session"])
        let good = SyncRecord(revision: .init(counter: 1, deviceID: UUID()), deviceName: "Mac", payload: login)
        let badLogin = SyncedLogin(accountID: 99, nickname: "Invalid", cookies: [:])
        let bad = SyncRecord(revision: .init(counter: 2, deviceID: UUID()), deviceName: "iPhone", payload: badLogin)
        for record in [good, bad] {
            try await repository.write(record, domain: .login, connectionID: connection)
        }
        let file = root.appendingPathComponent("Kumone/Devices/\(bad.id.uuidString)/login.json")
        if failure == "malformed" {
            try Data("invalid JSON".utf8).write(to: file)
        } else if failure == "newer" {
            var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(bad)) as? [String: Any])
            object["schemaVersion"] = 2
            try JSONSerialization.data(withJSONObject: object).write(to: file)
        }
        let records = try await repository.read(.login, as: SyncedLogin.self, connectionID: connection)
        #expect(SyncedLogin.availableAccounts(in: records, excluding: UUID()).map(\.id) == [good.id])
        await repository.disconnect(connectionID: connection)
    }

    @Test func invalidLatestLoginDoesNotResurrectItsOlderCredential() {
        let device = UUID()
        let login = SyncedLogin(accountID: 42, nickname: "Fixture", cookies: ["MUSIC_U": "synthetic-session"])
        let old = SyncRecord(revision: .init(counter: 1, deviceID: device), deviceName: "Mac", payload: login)
        let invalid = SyncRecord(revision: .init(counter: 2, deviceID: device), deviceName: "Mac",
                                 payload: SyncedLogin(accountID: 42, nickname: "Invalid", cookies: [:]))
        #expect(SyncedLogin.availableAccounts(in: [old, invalid], excluding: UUID()).isEmpty)
    }

    @Test @MainActor func reinstallReusesItsDeviceAndExcludesItsOwnPlayback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-reinstall-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SyncRepository()
        let connection = UUID()
        _ = try await repository.connect(to: root, connectionID: connection)
        let identity = UUID()
        let remote = UUID()
        let track = try JSONDecoder().decode(Track.self, from: Data("{\"id\":1,\"name\":\"Fixture\"}".utf8))
        let session = PlaybackSession(accountID: 42, queue: [track], orderedQueue: [track],
                                      currentIndex: 0, currentTrack: track, playNext: [], source: .none,
                                      repeatMode: "off", shuffled: false, automaticOrder: false, isFM: false, progress: 0)
        for device in [identity, remote] {
            try await repository.writePlayback(SyncRecord(revision: .init(counter: 9, deviceID: device),
                                                           deviceName: "iPhone", payload: session), connectionID: connection)
        }
        // A fresh defaults domain models reinstall; names deliberately match.
        let suite = "kumone-reinstall-defaults-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = SyncService(defaults: defaults, deviceIdentity: { identity })
        await service.connect(to: root)
        #expect(service.connected)
        #expect(service.sessions.map(\.id) == [remote])
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Kumone/Devices").path)
        #expect(Set(files) == Set([identity.uuidString, remote.uuidString]))
        await service.disable()
        await repository.disconnect(connectionID: connection)
    }

    @Test @MainActor func inaccessibleDeviceIdentityCannotConnectOrPublish() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-identity-error-\(UUID())")
        let suite = "kumone-identity-error-defaults-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = SyncService(defaults: defaults, deviceIdentity: { throw SyncError.unavailable })
        await service.connect(to: root)
        #expect(!service.connected)
        #expect(service.errorMessage != nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        await #expect(throws: SyncError.self) { try await service.enable() }
        #expect(!service.connected)
    }

    @Test @MainActor func disabledSyncDoesNotCapturePreferenceChanges() async throws {
        let suite = "kumone-disabled-sync-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = SettingsManager.shared
        let original = settings.showLyricsTranslation
        defer {
            settings.showLyricsTranslation = original
            defaults.removePersistentDomain(forName: suite)
        }
        let service = SyncService(defaults: defaults)
        await service.start()
        settings.showLyricsTranslation.toggle()
        await service.setForeground(false)
        try await Task.sleep(for: .milliseconds(750))
        #expect(defaults.data(forKey: "sync.preferences") == nil)
        #expect(defaults.object(forKey: "sync.counter") == nil)
    }

    @Test @MainActor func supersededEnableIsCancelledRatherThanRequestingAuthorization() async throws {
        let suite = "kumone-cancel-enable-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ready = AsyncStream<Void>.makeStream()
        let identities = AsyncStream<UUID>.makeStream()
        let service = SyncService(defaults: defaults, deviceIdentity: {
            ready.continuation.yield(())
            for await identity in identities.stream { return identity }
            throw CancellationError()
        })
        let enabling = Task { try await service.enable() }
        for await _ in ready.stream { break }
        await service.disable()
        identities.continuation.yield(UUID())
        identities.continuation.finish()
        ready.continuation.finish()
        await #expect(throws: CancellationError.self) { try await enabling.value }
        #expect(!service.enabled && !service.connected)
    }

    @Test(arguments: [SyncRepository.Domain.preferences, .playback])
    @MainActor func failedDomainDoesNotBlockLoginWithdrawalOrOtherDomains(domain: SyncRepository.Domain) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-domain-failure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "kumone-domain-failure-defaults-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = SyncRepository()
        let connection = UUID()
        _ = try await repository.connect(to: root, connectionID: connection)
        let local = UUID()
        let remote = UUID()
        let revision = SyncRevision(counter: 30, deviceID: remote)
        let track = try JSONDecoder().decode(Track.self, from: Data("{\"id\":1}".utf8))
        let session = PlaybackSession(accountID: 42, queue: [track], orderedQueue: [track],
                                      currentIndex: 0, currentTrack: track, playNext: [], source: .none,
                                      repeatMode: "off", shuffled: false, automaticOrder: false, isFM: false, progress: 10)
        let preferences = SyncedPreferences(fields: ["future-option": .init(value: .boolean(true), revision: revision)])
        let preferenceRecord = SyncRecord(revision: revision, deviceName: "Remote", payload: preferences)
        let playbackRecord = SyncRecord(revision: revision, deviceName: "Remote", payload: session)
        try await repository.write(preferenceRecord, domain: .preferences, connectionID: connection)
        try await repository.writePlayback(playbackRecord, connectionID: connection)
        let login = SyncedLogin(accountID: 42, nickname: "Fixture", cookies: ["MUSIC_U": "synthetic-session"])
        for device in [local, remote] {
            try await repository.write(SyncRecord(revision: .init(counter: 31, deviceID: device),
                                                   deviceName: "Fixture", payload: login), domain: .login, connectionID: connection)
        }
        let brokenFile = root.appendingPathComponent("Kumone/Devices/\(remote.uuidString)/\(domain.rawValue).json")
        try Data("invalid JSON".utf8).write(to: brokenFile, options: .atomic)
        let service = SyncService(defaults: defaults, deviceIdentity: { local })
        await service.connect(to: root)
        #expect(service.connected)
        #expect(service.errorMessage != nil)
        #expect(service.logins.map(\.id) == [remote])
        if domain == .preferences { #expect(service.sessions.map(\.id) == [remote]) }
        else {
            let records = try await repository.read(.preferences, as: SyncedPreferences.self, connectionID: connection)
            #expect(records.first { $0.id == local }?.payload?.fields["future-option"] != nil)
        }
        let loginRecords = try await repository.read(.login, as: SyncedLogin.self, connectionID: connection)
        #expect(try #require(loginRecords.first { $0.id == local }).payload == nil)
        if domain == .preferences {
            try await repository.write(preferenceRecord, domain: .preferences, connectionID: connection)
        } else {
            try await repository.writePlayback(playbackRecord, connectionID: connection)
        }
        // A local-only round still retries a domain whose preceding read failed.
        await service.synchronize(publishingPlayback: false, refreshing: [])
        #expect(service.errorMessage == nil)
        #expect(service.sessions.map(\.id) == [remote])
        await service.disable()
        await repository.disconnect(connectionID: connection)
    }

    @Test func concurrentPreferencesMergePerFieldAndConvergeInEitherOrder() throws {
        let deviceA = UUID()
        let deviceB = UUID()
        let a = PreferenceEdit(value: .string("dark"), revision: .init(counter: 3, deviceID: deviceA))
        let b = PreferenceEdit(value: .string("lossless"), revision: .init(counter: 3, deviceID: deviceB))
        let left = SyncedPreferences(fields: ["appearance": a])
        let right = SyncedPreferences(fields: ["quality": b])
        var forward = left
        forward.merge(right)
        var backward = right
        backward.merge(left)
        #expect(forward == backward)
        #expect(forward.fields["appearance"] == a)
        #expect(forward.fields["quality"] == b)
        let concurrent = SyncedPreferences(fields: ["appearance": .init(value: .string("light"), revision: b.revision)])
        forward.merge(concurrent)
        var reversed = concurrent
        reversed.merge(backward)
        #expect(forward == reversed)
        forward.merge(SyncedPreferences(fields: ["future-setting": b]))
        #expect(forward.fields["future-setting"] == b)
    }

    @Test func directoryLoginsCollapseAccountsAfterResolvingDeviceDeletions() throws {
        let login = SyncedLogin(accountID: 42, nickname: "Fixture", cookies: ["MUSIC_U": "synthetic-session"])
        let mac = UUID()
        let phone = UUID()
        let receiver = UUID()
        let first = SyncRecord(revision: .init(counter: 1, deviceID: mac), deviceName: "Mac", payload: login)
        let duplicate = SyncRecord(revision: .init(counter: 2, deviceID: phone), deviceName: "iPhone", payload: login)
        let withdrawn = SyncRecord<SyncedLogin>(revision: .init(counter: 3, deviceID: phone), deviceName: "iPhone", payload: nil)
        let accounts = SyncedLogin.availableAccounts(in: [first, duplicate], excluding: receiver)
        #expect(accounts.map(\.id) == [phone])
        let remaining = SyncedLogin.availableAccounts(in: [duplicate, withdrawn, first], excluding: receiver)
        #expect(remaining.map(\.id) == [mac])
        #expect(SyncedLogin.availableAccounts(in: [duplicate, withdrawn, first], excluding: mac).isEmpty)

        #expect(throws: SyncError.self) { try SyncedLogin(accountID: 42, nickname: "Fixture", cookies: [:]).validate() }
        #expect(throws: SyncError.self) { try SyncedLogin(accountID: 0, nickname: "Fixture", cookies: login.cookies).validate() }
    }

    @Test @MainActor func loginPublicationRequiresExplicitConsent() throws {
        let suite = "kumone-sync-consent-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!SyncService(defaults: defaults).loginEnabled)
        defaults.set(true, forKey: "sync.publishLogin")
        #expect(SyncService(defaults: defaults).loginEnabled)
    }

    @Test func loginUsesOneFileAndSupportsWithdrawal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-login-format-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SyncRepository()
        let connection = UUID()
        _ = try await repository.connect(to: root, connectionID: connection)
        let login = SyncedLogin(accountID: 42, nickname: "Fixture", cookies: ["MUSIC_U": "synthetic-session"])
        let record = SyncRecord(revision: .init(counter: 1, deviceID: UUID()), deviceName: "Mac", payload: login)
        try await repository.write(record, domain: .login, connectionID: connection)
        let device = root.appendingPathComponent("Kumone/Devices/\(record.id.uuidString)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: device.path) == ["login.json"])
        let received = try await repository.read(.login, as: SyncedLogin.self, connectionID: connection)
        let imported = SyncedLogin.availableAccounts(in: received, excluding: UUID())
        #expect(imported.count == 1)
        #expect(imported.first?.payload == login)
        let tombstone = SyncRecord<SyncedLogin>(revision: .init(counter: 2, deviceID: record.id), deviceName: "Mac", payload: nil)
        try await repository.write(tombstone, domain: .login, connectionID: connection)
        let withdrawn = try await repository.read(.login, as: SyncedLogin.self, connectionID: connection)
        #expect(SyncedLogin.availableAccounts(in: withdrawn, excluding: UUID()).isEmpty)
        await repository.disconnect(connectionID: connection)
    }

    @Test @MainActor func failedDirectoryChangeRevokesPreviouslyOfferedLogins() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-login-reconnect-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "kumone-sync-reconnect-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = SyncRepository()
        let connection = UUID()
        _ = try await repository.connect(to: root, connectionID: connection)
        let record = SyncRecord(revision: .init(counter: 1, deviceID: UUID()), deviceName: "Mac", payload: SyncedLogin(accountID: 42, nickname: "Fixture", cookies: ["MUSIC_U": "synthetic-session"]))
        try await repository.write(record, domain: .login, connectionID: connection)
        let identity = UUID()
        let service = SyncService(defaults: defaults, deviceIdentity: { identity })
        await service.connect(to: root)
        #expect(service.connected)
        #expect(service.logins.map(\.id) == [record.id])
        #expect(!service.loginEnabled)

        let invalidDirectory = root.appendingPathComponent("not-a-directory")
        try Data().write(to: invalidDirectory)
        await service.connect(to: invalidDirectory)
        #expect(!service.connected && service.logins.isEmpty)
        #expect(service.errorMessage != nil)
        await #expect(throws: CancellationError.self) { try await service.importLogin(record) }
        #expect(!service.loginEnabled)
        await service.connect(to: root)
        #expect(service.connected)
        await service.disable()
        #expect(!service.connected)
        #expect(try await service.enable())
        #expect(service.connected)
        await service.disable()
        await repository.disconnect(connectionID: connection)
    }

    @Test func localSignOutKeepsTheOtherDevicesSharedLoginAvailableForReturn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-return-login-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SyncRepository()
        let connection = UUID()
        _ = try await repository.connect(to: root, connectionID: connection)
        let mac = UUID()
        let phone = UUID()
        let macClient = NeteaseClient(cookieDirectory: root.appendingPathComponent("mac"))
        let phoneClient = NeteaseClient(cookieDirectory: root.appendingPathComponent("phone"))
        macClient.setCookies(["MUSIC_U": "synthetic-shared-session"])
        let login = SyncedLogin(accountID: 42, nickname: "Fixture", cookies: macClient.authenticationCookies())
        try await repository.write(SyncRecord(revision: .init(counter: 1, deviceID: mac), deviceName: "Mac",
                                              payload: login), domain: .login, connectionID: connection)

        try phoneClient.replaceAuthentication(with: login.cookies)
        let received = SyncedLogin(accountID: 42, nickname: "Fixture", cookies: phoneClient.authenticationCookies())
        try await repository.write(SyncRecord(revision: .init(counter: 2, deviceID: phone), deviceName: "iPhone",
                                              payload: received), domain: .login, connectionID: connection)
        try macClient.clearAuthCookies()
        let signedOut = SyncRecord<SyncedLogin>(revision: .init(counter: 3, deviceID: mac), deviceName: "Mac",
                                                payload: nil)
        try await repository.write(signedOut, domain: .login, connectionID: connection)

        #expect(!macClient.isLoggedIn)
        #expect(phoneClient.isLoggedIn)
        let records = try await repository.read(.login, as: SyncedLogin.self, connectionID: connection)
        let accounts = SyncedLogin.availableAccounts(in: records, excluding: mac)
        #expect(accounts.map(\.id) == [phone])
        let returnLogin = try #require(accounts.first?.payload)
        try macClient.replaceAuthentication(with: returnLogin.cookies)
        #expect(macClient.isLoggedIn)
        #expect(NeteaseClient(cookieDirectory: root.appendingPathComponent("phone")).isLoggedIn)
        await repository.disconnect(connectionID: connection)
    }

    @Test func repeatedSongsPreserveTheirCursorAndPlayNextTrack() throws {
        let track = try JSONDecoder().decode(Track.self, from: Data("{\"id\":1,\"name\":\"Fixture\",\"dt\":200000}".utf8))
        let next = try JSONDecoder().decode(Track.self, from: Data("{\"id\":2,\"name\":\"Next\"}".utf8))
        let session = PlaybackSession(accountID: 42, queue: [track, track], orderedQueue: [track, track],
                                      currentIndex: 1, currentTrack: next, playNext: [next], source: .playlist(7),
                                      repeatMode: "all", shuffled: true, automaticOrder: false, isFM: false, progress: 95)
        try session.validate()
        let restored = try JSONDecoder().decode(PlaybackSession.self, from: JSONEncoder().encode(session))
        #expect(restored == session)
        #expect(restored.currentIndex == 1)
    }

    @Test func compactPlaybackSnapshotKeepsMetadataVariantsAndQueueOccurrences() throws {
        let first = try JSONDecoder().decode(Track.self, from: Data("{\"id\":1,\"name\":\"Original\"}".utf8))
        let variant = try JSONDecoder().decode(Track.self, from: Data("{\"id\":1,\"name\":\"Updated\"}".utf8))
        let outside = try JSONDecoder().decode(Track.self, from: Data("{\"id\":2,\"name\":\"FM\"}".utf8))
        let session = PlaybackSession(accountID: 42, queue: [first, first, variant],
                                      orderedQueue: [variant, first, first], currentIndex: 2,
                                      currentTrack: outside, playNext: [outside, first, outside], source: .none,
                                      repeatMode: "off", shuffled: true, automaticOrder: false, isFM: true, progress: 32)
        let data = try JSONEncoder().encode(session)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((object["tracks"] as? [[String: Any]])?.count == 3)
        #expect(object["queue"] as? [Int] == [0, 0, 1])
        #expect(object["orderedQueue"] as? [Int] == [1, 0, 0])
        #expect(object["currentTrack"] as? Int == 2)
        #expect(try JSONDecoder().decode(PlaybackSession.self, from: data) == session)
        let record = SyncRecord(revision: .init(counter: 1, deviceID: UUID()), deviceName: "Fixture", payload: session)
        let envelope = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        #expect(envelope["accountID"] == nil)
    }

    @Test(arguments: ["queue", "orderedQueue", "currentTrack", "playNext"])
    func compactPlaybackSnapshotRejectsInvalidReferences(field: String) throws {
        let track = try JSONDecoder().decode(Track.self, from: Data("{\"id\":1}".utf8))
        let session = PlaybackSession(accountID: 42, queue: [track], orderedQueue: [track],
                                      currentIndex: 0, currentTrack: track, playNext: [], source: .none,
                                      repeatMode: "off", shuffled: false, automaticOrder: false, isFM: false, progress: 0)
        let encoded = try JSONEncoder().encode(session)
        for reference in [-1, 1] {
            var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            object[field] = field == "currentTrack" ? reference : [reference]
            let invalid = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: SyncError.self) { try JSONDecoder().decode(PlaybackSession.self, from: invalid) }
        }
    }

    @Test func repositoryRetainsIndependentDevicesAndRejectsAnOldConnection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-sync-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SyncRepository()
        let connection = UUID()
        _ = try await repository.connect(to: root, connectionID: connection)
        let first = SyncRecord(revision: .init(counter: 1, deviceID: UUID()), deviceName: "Mac", payload: SyncedPreferences())
        let second = SyncRecord(revision: .init(counter: 1, deviceID: UUID()), deviceName: "iPhone", payload: SyncedPreferences(fields: ["new-key": .init(value: .boolean(true), revision: first.revision)]))
        try await repository.write(first, domain: .preferences, connectionID: connection)
        try await repository.write(second, domain: .preferences, connectionID: connection)
        let records = try await repository.read(.preferences, as: SyncedPreferences.self, connectionID: connection)
        #expect(Set(records.map(\.id)) == [first.id, second.id])
        await repository.disconnect(connectionID: connection)
        await #expect(throws: CancellationError.self) {
            try await repository.write(first, domain: .preferences, connectionID: connection)
        }
    }

    @Test func validationClientCannotPersistReceivedCredentials() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-auth-sync-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = NeteaseClient(cookieDirectory: directory, configuration: .ephemeral, persistsCookies: false)
        client.setCookies(["MUSIC_U": "synthetic-received-session"])
        #expect(client.isLoggedIn)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test(arguments: [Int?(42), Int?(99), nil])
    func handoffRequiresTheSameSignedInAccount(accountID: Int?) throws {
        let publicTrack = try JSONDecoder().decode(Track.self, from: Data("{\"id\":1,\"name\":\"Public\"}".utf8))
        let privateTrack = try JSONDecoder().decode(Track.self, from: Data("{\"id\":2,\"name\":\"Private\",\"pc\":{}}".utf8))
        let publicSession = PlaybackSession(accountID: 42, queue: [publicTrack], orderedQueue: [publicTrack],
                                            currentIndex: 0, currentTrack: publicTrack, playNext: [], source: .none,
                                            repeatMode: "off", shuffled: false, automaticOrder: false, isFM: false, progress: 0)
        let privateSession = PlaybackSession(accountID: 42, queue: [publicTrack], orderedQueue: [publicTrack],
                                             currentIndex: 0, currentTrack: privateTrack, playNext: [], source: .cloud,
                                             repeatMode: "off", shuffled: false, automaticOrder: false, isFM: false, progress: 0)
        for session in [publicSession, privateSession] {
            if accountID == 42 { try session.validateAccess(accountID: accountID) }
            else { #expect(throws: SyncError.self) { try session.validateAccess(accountID: accountID) } }
        }
        let guestSession = PlaybackSession(accountID: nil, queue: [publicTrack], orderedQueue: [publicTrack],
                                           currentIndex: 0, currentTrack: publicTrack, playNext: [], source: .none,
                                           repeatMode: "off", shuffled: false, automaticOrder: false, isFM: false, progress: 0)
        #expect(throws: SyncError.self) { try guestSession.validateAccess(accountID: nil) }
    }

    @Test func authenticationReplacementPreservesDeviceCookiesAndDropsOldCSRF() throws {
        let client = NeteaseClient(configuration: .ephemeral, persistsCookies: false)
        client.setCookies(["MUSIC_U": "synthetic-old", "__csrf": "synthetic-old-csrf", "device": "local-device"])
        let before = client.authenticationFingerprint
        try client.replaceAuthentication(with: ["MUSIC_U": "synthetic-new"])
        #expect(client.cookie(named: "MUSIC_U") == "synthetic-new")
        #expect(client.cookie(named: "__csrf") == nil)
        #expect(client.cookie(named: "device") == "local-device")
        #expect(client.authenticationFingerprint != before)
    }

    @Test(arguments: [false, true])
    func failedAuthenticationPersistenceLeavesTheLiveLoginIntact(signingOut: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-sync-auth-failure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = NeteaseClient(cookieDirectory: root)
        client.setCookies(["MUSIC_U": "synthetic-current"])
        let binding = client.authenticationFingerprint
        let file = root.appendingPathComponent("cookies.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            if signingOut { try client.clearAuthCookies() }
            else { try client.replaceAuthentication(with: ["MUSIC_U": "synthetic-received"]) }
        }
        #expect(client.cookie(named: "MUSIC_U") == "synthetic-current")
        #expect(client.authenticationFingerprint == binding)
    }

    @Test func renamedRepositoryIsReusedAndNewerDataIsNotOverwritten() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-sync-rename-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SyncRepository()
        let firstConnection = UUID()
        _ = try await repository.connect(to: root, connectionID: firstConnection)
        let record = SyncRecord(revision: .init(counter: 5, deviceID: UUID()), deviceName: "Mac", payload: SyncedPreferences())
        try await repository.write(record, domain: .preferences, connectionID: firstConnection)
        await repository.disconnect(connectionID: firstConnection)
        let original = root.appendingPathComponent("Kumone")
        let renamed = root.appendingPathComponent("Renamed")
        try FileManager.default.moveItem(at: original, to: renamed)
        let connection = UUID()
        _ = try await repository.connect(to: renamed, connectionID: connection)
        let records = try await repository.read(.preferences, as: SyncedPreferences.self, connectionID: connection)
        #expect(records.map(\.id) == [record.id])
        #expect(!FileManager.default.fileExists(atPath: renamed.appendingPathComponent("Kumone").path))

        let file = renamed.appendingPathComponent("Devices").appendingPathComponent(record.id.uuidString)
            .appendingPathComponent("preferences.json")
        let encoded = try JSONEncoder().encode(record)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["schemaVersion"] = 99
        object["payload"] = ["future-shape": true]
        let newer = try JSONSerialization.data(withJSONObject: object)
        try newer.write(to: file, options: .atomic)
        await #expect(throws: SyncError.self) {
            try await repository.read(.preferences, as: SyncedPreferences.self, connectionID: connection)
        }
        #expect(try Data(contentsOf: file) == newer)
        await repository.disconnect(connectionID: connection)
    }
}
