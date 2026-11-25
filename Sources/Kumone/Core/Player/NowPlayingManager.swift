import AVFoundation
import Combine
import Foundation
import MediaPlayer

/// System Now Playing integration: media keys, Control Center, lock-screen metadata.
@MainActor
final class NowPlayingManager {
    static let shared = NowPlayingManager()

    private weak var player: PlayerService?
    private var artworkTask: Task<Void, Never>?
    private var playbackStateCancellables: Set<AnyCancellable> = []
    private var info: [String: Any] = [:]
    /// Every handler this manager added, so re-registering replaces instead of
    /// stacking. Two `play` handlers would turn one lock-screen tap into
    /// pause+play.
    private var commandTargets: [(command: MPRemoteCommand, token: Any)] = []
    #if os(iOS)
    /// Binds the app's Now Playing state to its AVPlayer. The system's Now
    /// Playing / lock-screen / Dynamic Island surface launches the app behind
    /// the session on a tap; publishing through the process-wide centers
    /// leaves that association implicit. `MPNowPlayingSession` is the iOS 16+
    /// API for it (macOS has no equivalent). This is the client-side
    /// hardening for #124/#40 — the launch itself is still controlled by the
    /// system and the installed app's signing identity.
    /// Typed as `AnyObject` because a stored property cannot reference an
    /// iOS 16-only type when the deployment target is 15. Every access casts
    /// back inside an `#available(iOS 16.0, *)` block.
    private var session: AnyObject?
    #endif

    /// Where metadata is published. With a session this must be the session's
    /// own center — the default center is not associated with it.
    private var infoCenter: MPNowPlayingInfoCenter {
        #if os(iOS)
        if #available(iOS 16.0, *), let session, let session = session as? MPNowPlayingSession { return session.nowPlayingInfoCenter }
        #endif
        return .default()
    }

    /// Where remote commands are registered. The session owns its own
    /// command center; registering on `.shared()` would leave those commands
    /// outside the session.
    private var commandCenter: MPRemoteCommandCenter {
        #if os(iOS)
        if #available(iOS 16.0, *), let session, let session = session as? MPNowPlayingSession { return session.remoteCommandCenter }
        #endif
        return .shared()
    }

    private init() {}

    #if os(iOS)
    private var activationAttemptInFlight = false
    private var lastActivationAttempt: Date = .distantPast
    private var sessionObserversInstalled = false
    /// `updateElapsed` ticks several times a second; activation is retried
    /// no more often than this.
    private static let activationRetryInterval: TimeInterval = 2

    /// Re-asserts the audio session before publishing. On iOS 15 there is no
    /// `MPNowPlayingSession`: the process-wide center is the only lock-screen
    /// surface, and nothing else re-asserts the session there — the reclaim
    /// path below is iOS 16-only, and `setActive(true)` otherwise runs only at
    /// launch and when the audio-mix setting changes. A slot lost to another
    /// app, an interruption or a media-services reset therefore stayed lost
    /// until the next launch re-ran `PlayerService.init()`.
    /// `setActive(true)` is a no-op while active and is rate-limited because
    /// `updateElapsed` ticks several times a second.
    private func ensureActiveSharedCenter() {
        let now = Date()
        guard now.timeIntervalSince(lastActivationAttempt) >= Self.activationRetryInterval else { return }
        lastActivationAttempt = now
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    /// Republishes what is already known after the system dropped it (media
    /// services reset, an interruption ending, a card claimed by another app).
    private func republishInfo() {
        guard !info.isEmpty else { return }
        let rate = info[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? 0
        infoCenter.nowPlayingInfo = info
        infoCenter.playbackState = rate > 0 ? .playing : .paused
    }

    /// Media services resets drop the now-playing registration without any
    /// playback callback, so they are observed directly.
    private func installSessionObserversIfNeeded() {
        guard !sessionObserversInstalled else { return }
        sessionObserversInstalled = true
        let center = NotificationCenter.default
        center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recoverAfterSystemEvent()
            }
        }
        center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let value = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: value) == .ended
                else { return }
                self.recoverAfterSystemEvent()
            }
        }
    }

    /// Re-registers the commands and republishes the card. iOS 16 keeps its
    /// session path: ask the existing session to become active again (its
    /// established fallback takes over if it cannot) instead of moving to the
    /// shared centers.
    private func recoverAfterSystemEvent() {
        guard let player else { return }
        if #available(iOS 16.0, *) {
            reclaimSessionIfNeeded(whilePlaying: player.isPlaying)
            republishInfo()
            return
        }
        // A media-services reset discards the session configuration and an
        // interruption can leave the session inactive; re-apply the player's
        // category before re-asserting. This is the moment the slot was
        // taken, so the tick rate limit must not swallow it.
        player.applyAudioMixPreference()
        lastActivationAttempt = Date()
        registerRemoteCommands(for: player)
        republishInfo()
    }

    /// Claims the session again when it has lost its active slot (another app
    /// took Now Playing while we were paused). While audio is audibly playing
    /// a refusal means this install cannot activate a session at all, which
    /// happens with some re-signed builds; the shared centers then take over
    /// so the lock screen and Control Center keep their controls.
    @available(iOS 16.0, *)
    private func reclaimSessionIfNeeded(whilePlaying playing: Bool) {
        guard let session, let session = session as? MPNowPlayingSession, !session.isActive,
              !activationAttemptInFlight,
              Date().timeIntervalSince(lastActivationAttempt) >= Self.activationRetryInterval
        else { return }
        activationAttemptInFlight = true
        lastActivationAttempt = Date()
        session.becomeActiveIfPossible { [weak self] success in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.activationAttemptInFlight = false
                if !success, playing { self.fallBackToSharedCenters() }
            }
        }
    }

    /// Gives up the session: commands move to `MPRemoteCommandCenter.shared()`
    /// and the current metadata is republished on the default info center.
    @available(iOS 16.0, *)
    private func fallBackToSharedCenters() {
        guard session != nil, let player else { return }
        session = nil
        registerRemoteCommands(for: player)
        let rate = info[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? 0
        infoCenter.nowPlayingInfo = info.isEmpty ? nil : info
        infoCenter.playbackState = info.isEmpty ? .stopped : (rate > 0 ? .playing : .paused)
        refreshLikeState()
    }
    #endif

    /// - Parameter avPlayer: the iOS AVPlayer backing playback. When supplied,
    ///   the Now Playing session is bound to it so the system can identify the
    ///   app behind the session.
    func attach(to player: PlayerService, avPlayer: AVPlayer? = nil) {
        self.player = player
        #if os(iOS)
        installSessionObserversIfNeeded()
        if #available(iOS 16.0, *), let avPlayer {
            let session = MPNowPlayingSession(players: [avPlayer])
            // We publish the full dictionary ourselves (elapsed time, queue
            // count, artwork), which the automatic publisher would omit.
            session.automaticallyPublishesNowPlayingInfo = false
            self.session = session
            session.becomeActiveIfPossible { _ in }
        }
        #endif
        registerRemoteCommands(for: player)
    }

    /// Registers the remote commands on the current command center. Run again
    /// when that center changes, i.e. when the session is given up.
    private func registerRemoteCommands(for player: PlayerService) {
        removeRegisteredCommandTargets()
        playbackStateCancellables.removeAll()
        let center = commandCenter

        addTarget(center.playCommand) { [weak player] _ in
            guard let player, player.hasCurrentTrack else { return .noActionableNowPlayingItem }
            if !player.isPlaying { player.togglePlayPause() }
            return .success
        }
        addTarget(center.pauseCommand) { [weak player] _ in
            guard let player, player.hasCurrentTrack else { return .noActionableNowPlayingItem }
            if player.isPlaying { player.togglePlayPause() }
            return .success
        }
        addTarget(center.togglePlayPauseCommand) { [weak player] _ in
            guard let player, player.hasCurrentTrack else { return .noActionableNowPlayingItem }
            player.togglePlayPause()
            return .success
        }
        addTarget(center.nextTrackCommand) { [weak player] _ in
            player?.next()
            return .success
        }
        addTarget(center.previousTrackCommand) { [weak player] _ in
            player?.previous()
            return .success
        }
        addTarget(center.changePlaybackPositionCommand) { [weak player] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            player?.seek(to: event.positionTime)
            return .success
        }

        // Like feedback (Control Center long-press / CarPlay; isActive = hearted)
        center.likeCommand.isEnabled = true
        center.likeCommand.localizedTitle = String(localized: "喜欢")
        center.likeCommand.localizedShortTitle = String(localized: "喜欢")
        addTarget(center.likeCommand) { [weak player] _ in
            guard let track = player?.currentTrack else { return .noActionableNowPlayingItem }
            Task { @MainActor in
                await AccountStore.shared.toggleLike(trackID: track.id)
                NowPlayingManager.shared.refreshLikeState()
            }
            return .success
        }

        // NB: we deliberately do NOT register skipForward/skipBackward (±15s).
        // Enabling those commands makes iOS show "back 15s / forward 15s" on the
        // lock screen and Dynamic Island *instead of* previous/next track — a
        // podcast-style layout that's wrong for a music player and hid the
        // skip-track buttons (#83, #87). Previous/next above stay the system
        // media buttons everywhere, including CarPlay.

        // Shuffle / Repeat — backs the shuffle and repeat buttons on the CarPlay Now Playing screen.
        addTarget(center.changeShuffleModeCommand) { [weak player] event in
            guard let player,
                  let event = event as? MPChangeShuffleModeCommandEvent else { return .commandFailed }
            let wantOn = event.shuffleType != .off
            if player.shuffleEnabled != wantOn { player.toggleShuffle() }
            return .success
        }
        addTarget(center.changeRepeatModeCommand) { [weak player] event in
            guard let player,
                  let event = event as? MPChangeRepeatModeCommandEvent else { return .commandFailed }
            // MPRepeatType: .off / .one / .all → RepeatMode: .off / .one / .all
            let target: RepeatMode? = switch event.repeatType {
                case .off:  .off
                case .one:  .one
                case .all:  .all
                default:    nil
            }
            if let target, player.repeatMode != target { player.repeatMode = target }
            return .success
        }

        #if os(macOS)
        // Shuffle is one of the queue orders on macOS (`shuffleEnabled` is
        // derived), so observe the order and map it back to on/off.
        player.$queueOrder
            .map { $0 == .shuffled }
            .removeDuplicates()
            .sink { enabled in
                center.changeShuffleModeCommand.currentShuffleType = enabled ? .items : .off
            }
            .store(in: &playbackStateCancellables)
        #else
        player.$shuffleEnabled
            .removeDuplicates()
            .sink { enabled in
                center.changeShuffleModeCommand.currentShuffleType = enabled ? .items : .off
            }
            .store(in: &playbackStateCancellables)
        #endif

        player.$repeatMode
            .removeDuplicates()
            .sink { mode in
                center.changeRepeatModeCommand.currentRepeatType = switch mode {
                case .off: .off
                case .one: .one
                case .all: .all
                }
            }
            .store(in: &playbackStateCancellables)
    }

    private func addTarget(
        _ command: MPRemoteCommand,
        handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
    ) {
        commandTargets.append((command, command.addTarget(handler: handler)))
    }

    private func removeRegisteredCommandTargets() {
        for (command, token) in commandTargets { command.removeTarget(token) }
        commandTargets.removeAll()
    }

    /// Reflects the current track's hearted state on the like command.
    func refreshLikeState() {
        guard let track = player?.currentTrack else {
            commandCenter.likeCommand.isActive = false
            return
        }
        commandCenter.likeCommand.isActive =
            AccountStore.shared.isLiked(track.id)
    }

    func updateMetadata(for track: Track, duration: TimeInterval) {
        #if os(iOS)
        // A session can lose its active slot while playback was stopped;
        // claim it again as soon as a new track is put up. The player may not
        // be audible yet, so a refusal here is not held against the session.
        if #available(iOS 16.0, *) {
            reclaimSessionIfNeeded(whilePlaying: false)
        } else {
            // One attempt per track: the rate limit exists for the several
            // `updateElapsed` ticks a second, and it must not swallow the
            // publish the lock screen keys off after a quick skip.
            lastActivationAttempt = .distantPast
            ensureActiveSharedCenter()
        }
        #endif
        info = [
            MPMediaItemPropertyTitle: track.name,
            MPMediaItemPropertyArtist: track.artistNames,
            MPMediaItemPropertyAlbumTitle: track.album.name,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
            // Declare the session as audio so system surfaces treat it as a
            // complete now-playing app (best-effort hardening for #36/#40).
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        infoCenter.nowPlayingInfo = info
        infoCenter.playbackState = .playing
        refreshLikeState()

        artworkTask?.cancel()
        // 1024px: the lock screen's tap-to-fullscreen artwork presentation
        // needs high-resolution art to engage.
        guard let url = track.album.picUrl?.resizedImageURL(1024) else { return }
        artworkTask = Task { [weak self] in
            let apply: ImageCache.CachedImageHandler = { [weak self] image in
                guard let self, !Task.isCancelled else { return }
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.info[MPMediaItemPropertyArtwork] = artwork
                self.infoCenter.nowPlayingInfo = self.info
            }
            if let image = await ImageCache.shared.image(for: url, onCachedImage: apply) {
                apply(image)
            }
        }
    }

    func updateElapsed(_ elapsed: TimeInterval, rate: Double) {
        #if os(iOS)
        // Resuming the same track publishes through here, not updateMetadata.
        if #available(iOS 16.0, *) {
            if rate > 0 { reclaimSessionIfNeeded(whilePlaying: true) }
        } else if rate > 0, (info[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? 0) <= 0 {
            // Only the paused→playing edge needs the session re-asserted; the
            // steady ticks several times a second must not call into
            // AVAudioSession.
            lastActivationAttempt = .distantPast
            ensureActiveSharedCenter()
        }
        #endif
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        infoCenter.nowPlayingInfo = info
        infoCenter.playbackState = rate > 0 ? .playing : .paused
    }

    /// Re-asserts the card when the app moves to the background — the moment
    /// the lock screen renders it. On iOS 15 the shared slot may have been
    /// taken since the last publish (another app, an interruption, a media
    /// services reset); iOS 16 keeps its session and is merely asked to
    /// become active again if it lost the slot.
    func refreshSystemCard() {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            reclaimSessionIfNeeded(whilePlaying: player?.isPlaying == true)
        } else {
            guard player?.currentTrack != nil else { return }
            lastActivationAttempt = .distantPast
            ensureActiveSharedCenter()
        }
        republishInfo()
        #endif
    }

    func clear() {
        artworkTask?.cancel()
        artworkTask = nil
        info = [:]
        infoCenter.nowPlayingInfo = nil
        infoCenter.playbackState = .stopped
        commandCenter.likeCommand.isActive = false
    }
}
