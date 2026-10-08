import SwiftUI

enum AudioQuality: String, CaseIterable, Identifiable {
    case standard
    case higher
    case exhigh
    case lossless
    case hires

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: return String(localized: "标准")
        case .higher: return String(localized: "较高")
        case .exhigh: return String(localized: "极高")
        case .lossless: return String(localized: "无损")
        case .hires: return "Hi-Res"
        }
    }

    var badge: String {
        switch self {
        case .standard: return String(localized: "标准")
        case .higher: return String(localized: "较高")
        case .exhigh: return String(localized: "极高")
        case .lossless: return String(localized: "无损")
        case .hires: return String(localized: "高解析")
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case auto, light, dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return String(localized: "跟随系统")
        case .light: return String(localized: "浅色")
        case .dark: return String(localized: "深色")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .auto: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// What to show above Japanese lyrics.
enum LyricsAnnotation: String, CaseIterable, Identifiable {
    case off
    case romaji
    case furigana

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return String(localized: "关闭")
        case .romaji: return String(localized: "罗马音")
        case .furigana: return String(localized: "汉字读音")
        }
    }
}

public enum NowPlayingMode: String, CaseIterable, Identifiable {
    case vinyl
    case classic
    case immersive
    case minimal

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .vinyl: return String(localized: "黑胶模式")
        case .classic: return String(localized: "经典模式")
        case .immersive: return String(localized: "沉浸模式")
        case .minimal: return String(localized: "简洁模式")
        }
    }
}

@MainActor
final class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    /// Internal rather than private: `AudioCache` reads its own limit straight
    /// from `UserDefaults` before any settings object exists, and must spell
    /// the key the same way.
    enum Keys {
        static let quality = "settings.audioQuality"
        static let appearance = "settings.appearance"
        static let nowPlayingMode = "settings.nowPlayingMode"
        static let showTranslation = "settings.showLyricsTranslation"
        static let showRomaji = "settings.showLyricsRomaji"  // migrated to `annotation`
        static let annotation = "settings.lyricsAnnotation"
        static let verbatimLyrics = "settings.verbatimLyrics"
        static let volume = "settings.volume"
        static let fmMode = "settings.fmMode"
        static let unblock = "settings.enableUnblock"
        /// Keep in sync with `UnblockService.fallbackDefaultsKey`.
        static let unblockFallback = "settings.enableUnblockFallback"
        static let unblockSources = "settings.enabledUnblockSources"
        static let autoCheckUpdates = "settings.autoCheckUpdates"
        static let desktopLyrics = "settings.showDesktopLyrics"
        #if os(macOS)
        static let automix = "settings.automixEnabled"
        static let automixTransitions = "settings.automixTransitions"
        static let automixOrder = "settings.automixOrder"
        static let automixStems = "settings.automixStems"
        static let loudnessCompensation = "settings.loudnessCompensation"
        static let audioCacheLimit = "settings.audioCacheLimit"
        static let outputDevice = "settings.outputDeviceUID"
        #endif
        static let desktopLyricsCentered = "settings.desktopLyricsCentered"
        static let mainWindowAmbientBackground = "settings.showMainWindowAmbientBackground"
        static let mainWindowAmbientBackgroundIntensity = "settings.mainWindowAmbientBackgroundIntensity"
        static let enableAudioCache = "settings.enableAudioCache"
        static let audioCacheSizeMB = "settings.audioCacheSizeMB"
        // Player customisation (ported from Beans-Music)
        static let progressBarStyle = "settings.progressBarStyle"   // 0流光 1辉光 2极光 3波浪
        static let playerBreath = "settings.playerBreath"           // 0...1 呼吸光晕强度
        static let djVisual = "settings.djVisual"                   // DJ 节奏脉冲
        static let djIntensity = "settings.djIntensity"             // 0...1
        static let mixWithOthers = "settings.mixWithOthers"         // 与其他音频同时播放
        static let lyricFontSize = "settings.lyricFontSize"         // 12...28
        static let lyricSpacing = "settings.lyricSpacing"           // 14...40
        static let circularCover = "settings.circularCover"
        static let circularCoverSpin = "settings.circularCoverSpin"
        // Beans-style effects
        static let progressAccentHex = "settings.progressAccentHex"   // "" = follow accent
        static let lyricBlurAmount = "settings.lyricBlurAmount"       // 0...10
        static let lyricTiltX = "settings.lyricTiltX"                 // -30...30
        static let lyricTiltY = "settings.lyricTiltY"                 // -20...20
        static let lyricGlow = "settings.lyricGlow"                   // 0...5
        /// iOS 26 folds overflowing tabs into a "更多" tab; this keeps the
        /// hand-built bar with every tab laid out flat instead.
        static let flattenTabs = "settings.flattenTabs"
    }

    /// Progress bar style: 0 流光 / 1 辉光 / 2 极光 / 3 波浪.
    @Published var progressBarStyle: Int {
        didSet { UserDefaults.standard.set(progressBarStyle, forKey: Keys.progressBarStyle) }
    }

    /// Breathing ambient glow behind the player, 0 (off) ... 1 (full).
    @Published var playerBreath: Double {
        didSet { UserDefaults.standard.set(playerBreath, forKey: Keys.playerBreath) }
    }

    /// DJ-style beat pulse rings (time-driven, decorative).
    @Published var djVisual: Bool {
        didSet { UserDefaults.standard.set(djVisual, forKey: Keys.djVisual) }
    }

    @Published var djIntensity: Double {
        didSet { UserDefaults.standard.set(djIntensity, forKey: Keys.djIntensity) }
    }

    /// Keep playing while other apps play audio.
    @Published var mixWithOthers: Bool {
        didSet {
            UserDefaults.standard.set(mixWithOthers, forKey: Keys.mixWithOthers)
            PlayerService.shared.applyAudioMixPreference()
        }
    }

    @Published var lyricFontSize: Double {
        didSet { UserDefaults.standard.set(lyricFontSize, forKey: Keys.lyricFontSize) }
    }

    @Published var lyricSpacing: Double {
        didSet { UserDefaults.standard.set(lyricSpacing, forKey: Keys.lyricSpacing) }
    }

    @Published var circularCover: Bool {
        didSet { UserDefaults.standard.set(circularCover, forKey: Keys.circularCover) }
    }

    @Published var circularCoverSpin: Bool {
        didSet { UserDefaults.standard.set(circularCoverSpin, forKey: Keys.circularCoverSpin) }
    }

    /// Custom progress-bar color (hex RRGGBB); empty follows the theme accent.
    @Published var progressAccentHex: String {
        didSet { UserDefaults.standard.set(progressAccentHex, forKey: Keys.progressAccentHex) }
    }

    @Published var lyricBlurAmount: Double {
        didSet { UserDefaults.standard.set(lyricBlurAmount, forKey: Keys.lyricBlurAmount) }
    }

    @Published var lyricTiltX: Double {
        didSet { UserDefaults.standard.set(lyricTiltX, forKey: Keys.lyricTiltX) }
    }

    @Published var lyricTiltY: Double {
        didSet { UserDefaults.standard.set(lyricTiltY, forKey: Keys.lyricTiltY) }
    }

    @Published var lyricGlow: Double {
        didSet { UserDefaults.standard.set(lyricGlow, forKey: Keys.lyricGlow) }
    }

    @Published var audioQuality: AudioQuality {
        didSet { UserDefaults.standard.set(audioQuality.rawValue, forKey: Keys.quality) }
    }

    static let audioCacheSizeRangeMB = 100...1_000
    static let audioCacheSizeStepMB = 100

    /// Use locally stored audio files before resolving a remote source and
    /// retain completed remote playback for future requests.
    @Published var enableAudioCache: Bool {
        didSet { UserDefaults.standard.set(enableAudioCache, forKey: Keys.enableAudioCache) }
    }

    static func normalizedAudioCacheSizeMB(_ value: Int) -> Int {
        let boundedValue = min(
            max(value, audioCacheSizeRangeMB.lowerBound),
            audioCacheSizeRangeMB.upperBound
        )
        let distanceFromLowerBound = boundedValue - audioCacheSizeRangeMB.lowerBound
        return audioCacheSizeRangeMB.lowerBound
            + Int((Double(distanceFromLowerBound) / Double(audioCacheSizeStepMB)).rounded())
                * audioCacheSizeStepMB
    }

    @Published var audioCacheSizeMB: Int {
        didSet {
            let normalizedValue = Self.normalizedAudioCacheSizeMB(audioCacheSizeMB)
            guard normalizedValue == audioCacheSizeMB else {
                audioCacheSizeMB = normalizedValue
                return
            }
            UserDefaults.standard.set(audioCacheSizeMB, forKey: Keys.audioCacheSizeMB)
        }
    }

    @Published var appearance: AppAppearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    @Published var nowPlayingMode: NowPlayingMode {
        didSet { UserDefaults.standard.set(nowPlayingMode.rawValue, forKey: Keys.nowPlayingMode) }
    }

    @Published var showLyricsTranslation: Bool {
        didSet { UserDefaults.standard.set(showLyricsTranslation, forKey: Keys.showTranslation) }
    }

    /// Check for updates on launch. When off, no update sheet appears
    /// automatically; the user can still check manually (#42).
    @Published var autoCheckUpdates: Bool {
        didSet {
            UserDefaults.standard.set(autoCheckUpdates, forKey: Keys.autoCheckUpdates)
            #if os(macOS)
            UpdaterManager.shared.setAutomaticChecks(autoCheckUpdates)
            #endif
        }
    }

    /// Reading shown for Japanese lyrics: a romaji line above, furigana over
    /// the kanji, or nothing.
    @Published var lyricsAnnotation: LyricsAnnotation {
        didSet { UserDefaults.standard.set(lyricsAnnotation.rawValue, forKey: Keys.annotation) }
    }

    /// Karaoke-style word-by-word highlighting when the song has verbatim
    /// (yrc) lyrics; falls back to line highlighting when it doesn't.
    @Published var verbatimLyrics: Bool {
        didSet { UserDefaults.standard.set(verbatimLyrics, forKey: Keys.verbatimLyrics) }
    }

    /// Resolve gray tracks from third-party sources (UnblockNeteaseMusic-style).
    @Published var enableUnblock: Bool {
        didSet { UserDefaults.standard.set(enableUnblock, forKey: Keys.unblock) }
    }

    /// Allow the fuzzy 酷狗 / 酷我 fallback when pyncmd has no copy of a track.
    /// Off by default: pyncmd resolves by the original NetEase id, while those two
    /// match on name + duration and can return the wrong recording.
    /// Acts as the master switch: when off, only pyncmd is ever asked.
    @Published var enableUnblockFallback: Bool {
        didSet { UserDefaults.standard.set(enableUnblockFallback, forKey: Keys.unblockFallback) }
    }

    /// Built-in third-party sources eligible for gray-track resolution.
    @Published var enabledAudioSourceIDs: Set<AudioSourceID> {
        didSet {
            UserDefaults.standard.set(
                enabledAudioSourceIDs.map(\.rawValue).sorted(),
                forKey: Keys.unblockSources
            )
        }
    }

    var canResolveUnblockedTracks: Bool {
        enableUnblock && !enabledAudioSourceIDs.isEmpty
    }

    /// Floating desktop lyrics window (LyricsX-style).
    @Published var showDesktopLyrics: Bool {
        didSet { UserDefaults.standard.set(showDesktopLyrics, forKey: Keys.desktopLyrics) }
    }
    #if os(macOS)

    /// The AutoMix master switch. Off means no per-track analysis at all, and
    /// every sub-setting below is inert. Opt-in: AutoMix costs CPU (analysis),
    /// sometimes network (the order's candidates) and sometimes GPU (stems),
    /// so it does not turn itself on. macOS-only for now (spec §7).
    @Published var automixEnabled: Bool {
        didSet { UserDefaults.standard.set(automixEnabled, forKey: Keys.automix) }
    }

    /// Beat-matched / crossfaded hand-overs between queue tracks. Off still
    /// gives gapless playback, and off is *only* a statement about the seam:
    /// analysis still runs when another sub-setting below wants it.
    @Published var automixTransitionsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(automixTransitionsEnabled,
                                      forKey: Keys.automixTransitions)
        }
    }

    /// The `.autoMix` queue order — reorder the queue by how well the seams
    /// come out. It scores candidates, which means downloading tracks the
    /// listener has not asked for yet, so it is off by default even under an
    /// AutoMix that is on.
    @Published var automixOrderEnabled: Bool {
        didSet { UserDefaults.standard.set(automixOrderEnabled, forKey: Keys.automixOrder) }
    }

    /// Let a hand-over separate stems on the GPU. Real money in heat and
    /// battery, and it needs a model on disk, so it is opt-in on top of
    /// opt-in; without it every gesture plays its whole-mix form.
    @Published var automixStemsEnabled: Bool {
        didSet { UserDefaults.standard.set(automixStemsEnabled, forKey: Keys.automixStems) }
    }

    /// Even out mastering loudness differences between songs, so the next
    /// track does not arrive several dB louder. Needs AutoMix's per-track
    /// analysis, so it is inert while AutoMix is off.
    @Published var loudnessCompensationEnabled: Bool {
        didSet {
            UserDefaults.standard.set(loudnessCompensationEnabled,
                                      forKey: Keys.loudnessCompensation)
        }
    }

    /// Audio cache LRU limit in bytes; 0 = unlimited. AudioCache reads the
    /// same defaults key at startup and receives changes from here.
    @Published var audioCacheLimit: Int64 {
        didSet {
            UserDefaults.standard.set(audioCacheLimit, forKey: Keys.audioCacheLimit)
            Task { await EngineAudioCache.shared.setLimitBytes(audioCacheLimit) }
        }
    }

    /// CoreAudio UID of the chosen output device; "" follows the system
    /// default. UID rather than the numeric AudioDeviceID, which is not
    /// stable across launches. Written by `AudioOutputController`.
    @Published var outputDeviceUID: String {
        didSet { UserDefaults.standard.set(outputDeviceUID, forKey: Keys.outputDevice) }
    }
    #endif

    /// Lock the desktop-lyrics capsule to the horizontal centre of the screen
    /// instead of the free-drag position (#48).
    @Published var desktopLyricsCentered: Bool {
        didSet { UserDefaults.standard.set(desktopLyricsCentered, forKey: Keys.desktopLyricsCentered) }
    }

    static let mainWindowAmbientBackgroundIntensityRange = 0.5...1.5

    #if os(macOS)
    /// Default song-cache ceiling, shared with `AudioCache` so the two cannot
    /// disagree about what "unset" means.
    nonisolated static let defaultAudioCacheLimit: Int64 = 2_147_483_648  // 2 GB
    #endif

    /// Artwork-tinted overlay on the main app interface.
    @Published var showMainWindowAmbientBackground: Bool {
        didSet {
            UserDefaults.standard.set(
                showMainWindowAmbientBackground,
                forKey: Keys.mainWindowAmbientBackground
            )
        }
    }

    /// Multiplier applied to the main interface's artwork tint.
    @Published var mainWindowAmbientBackgroundIntensity: Double {
        didSet {
            UserDefaults.standard.set(
                mainWindowAmbientBackgroundIntensity,
                forKey: Keys.mainWindowAmbientBackgroundIntensity
            )
        }
    }
    /// Draw the tab bar ourselves instead of letting iOS 26 collapse the
    /// overflow (搜索 / 插件) into a single "更多" tab.
    @Published var flattenTabs: Bool {
        didSet { UserDefaults.standard.set(flattenTabs, forKey: Keys.flattenTabs) }
    }

    private init() {
        let defaults = UserDefaults.standard
        audioQuality = defaults.string(forKey: Keys.quality).flatMap(AudioQuality.init) ?? .exhigh
        enableAudioCache = defaults.object(forKey: Keys.enableAudioCache) as? Bool ?? true
        let storedAudioCacheSizeMB = defaults.object(forKey: Keys.audioCacheSizeMB) as? Int
            ?? AudioCache.defaultMaximumSizeMB
        let normalizedAudioCacheSizeMB = Self.normalizedAudioCacheSizeMB(storedAudioCacheSizeMB)
        audioCacheSizeMB = normalizedAudioCacheSizeMB
        defaults.set(normalizedAudioCacheSizeMB, forKey: Keys.audioCacheSizeMB)
        appearance = defaults.string(forKey: Keys.appearance).flatMap(AppAppearance.init) ?? .auto
        nowPlayingMode = defaults.string(forKey: Keys.nowPlayingMode).flatMap(NowPlayingMode.init) ?? .immersive
        showLyricsTranslation = defaults.object(forKey: Keys.showTranslation) as? Bool ?? true
        // Carry over the old on/off romaji toggle for anyone who had it on.
        lyricsAnnotation = defaults.string(forKey: Keys.annotation).flatMap(LyricsAnnotation.init)
            ?? (defaults.bool(forKey: Keys.showRomaji) ? .romaji : .off)
        verbatimLyrics = defaults.object(forKey: Keys.verbatimLyrics) as? Bool ?? true
        enableUnblock = defaults.object(forKey: Keys.unblock) as? Bool ?? true
        enableUnblockFallback = defaults.object(forKey: Keys.unblockFallback) as? Bool ?? false
        if let rawSourceIDs = defaults.stringArray(forKey: Keys.unblockSources) {
            enabledAudioSourceIDs = Set(rawSourceIDs.compactMap(AudioSourceID.init))
        } else {
            enabledAudioSourceIDs = Set(AudioSourceID.allCases)
        }
        autoCheckUpdates = defaults.object(forKey: Keys.autoCheckUpdates) as? Bool ?? true
        showDesktopLyrics = defaults.object(forKey: Keys.desktopLyrics) as? Bool ?? false
        #if os(macOS)
        automixEnabled = defaults.object(forKey: Keys.automix) as? Bool ?? false
        automixTransitionsEnabled =
            defaults.object(forKey: Keys.automixTransitions) as? Bool ?? true
        automixOrderEnabled = defaults.object(forKey: Keys.automixOrder) as? Bool ?? false
        automixStemsEnabled = defaults.object(forKey: Keys.automixStems) as? Bool ?? false
        loudnessCompensationEnabled =
            defaults.object(forKey: Keys.loudnessCompensation) as? Bool ?? true
        audioCacheLimit = (defaults.object(forKey: Keys.audioCacheLimit) as? Int64)
            ?? Self.defaultAudioCacheLimit
        outputDeviceUID = defaults.string(forKey: Keys.outputDevice) ?? ""
        #endif
        desktopLyricsCentered = defaults.object(forKey: Keys.desktopLyricsCentered) as? Bool ?? false
        showMainWindowAmbientBackground = defaults.object(
            forKey: Keys.mainWindowAmbientBackground
        ) as? Bool ?? true
        let storedAmbientBackgroundIntensity = defaults.object(
            forKey: Keys.mainWindowAmbientBackgroundIntensity
        ) as? Double ?? 1
        mainWindowAmbientBackgroundIntensity = min(
            max(storedAmbientBackgroundIntensity, Self.mainWindowAmbientBackgroundIntensityRange.lowerBound),
            Self.mainWindowAmbientBackgroundIntensityRange.upperBound
        )
        progressBarStyle = defaults.object(forKey: Keys.progressBarStyle) as? Int ?? 0
        playerBreath = defaults.object(forKey: Keys.playerBreath) as? Double ?? 0.6
        djVisual = defaults.object(forKey: Keys.djVisual) as? Bool ?? false
        djIntensity = defaults.object(forKey: Keys.djIntensity) as? Double ?? 0.5
        mixWithOthers = defaults.object(forKey: Keys.mixWithOthers) as? Bool ?? false
        lyricFontSize = defaults.object(forKey: Keys.lyricFontSize) as? Double ?? 20
        lyricSpacing = defaults.object(forKey: Keys.lyricSpacing) as? Double ?? 24
        circularCover = defaults.object(forKey: Keys.circularCover) as? Bool ?? false
        circularCoverSpin = defaults.object(forKey: Keys.circularCoverSpin) as? Bool ?? false
        progressAccentHex = defaults.string(forKey: Keys.progressAccentHex) ?? ""
        lyricBlurAmount = defaults.object(forKey: Keys.lyricBlurAmount) as? Double ?? 4
        lyricTiltX = defaults.object(forKey: Keys.lyricTiltX) as? Double ?? 8
        lyricTiltY = defaults.object(forKey: Keys.lyricTiltY) as? Double ?? 0
        lyricGlow = defaults.object(forKey: Keys.lyricGlow) as? Double ?? 2.5
        flattenTabs = defaults.object(forKey: Keys.flattenTabs) as? Bool ?? true
    }
}
