import Foundation
import os.log

/// Resolves gray tracks from the direct pyncmd source, then built-in search
/// providers when pyncmd cannot serve the original NetEase song ID.
///
/// Provider order mirrors UnblockNeteaseMusic/server:
/// 1. pyncmd — GD Studio API, resolves by the ORIGINAL NetEase id (best fidelity)
/// 2. kugou  — search + strict title/artist/duration match, tracker URL   [opt-in]
/// 3. kuwo   — search + strict title/artist/duration match, convert_url   [opt-in]
///
/// Only pyncmd answers by default. It resolves by the *original* NetEase id, so
/// it always hands back the exact same recording. kugou / kuwo match on song name
/// plus a ±5 s duration window, which means they can still return a cover, a live
/// take or a "请在酷我音乐APP播放" promo clip — so they stay behind the
/// user-facing fallback switch (default off).
enum UnblockService {
    private static let log = Logger(subsystem: "im.missuo.kumone", category: "audio-source")
    private static let httpClient = AudioSourceClient.shared
    private static let fallbackProviders: [any AudioSourceProvider] = [
        KugouAudioSourceProvider(),
        KuwoAudioSourceProvider(),
    ]

    /// Must stay identical to `SettingsManager.Keys.unblockFallback`.
    /// Read straight from UserDefaults because `SettingsManager` is @MainActor
    /// while this helper is not.
    static let fallbackDefaultsKey = "settings.enableUnblockFallback"

    struct Resolution {
        let source: ResolvedAudioSource?
        let attemptedSources: Set<AudioSourceID>
    }

    static func resolve(
        _ track: Track,
        enabledSources: Set<AudioSourceID>,
        excluding attemptedSources: Set<AudioSourceID>
    ) async -> Resolution {
        var newlyAttemptedSources = Set<AudioSourceID>()
        if enabledSources.contains(.pyncmd), !attemptedSources.contains(.pyncmd) {
            newlyAttemptedSources.insert(.pyncmd)
            do {
                return Resolution(
                    source: try await pyncmd(track),
                    attemptedSources: newlyAttemptedSources
                )
            } catch {
                logFailure(source: .pyncmd, operation: "resolve", error: error)
            }
        }

        // The fuzzy providers stay behind the user's fallback switch: even with a
        // strict matcher they can hand back a live take, a cover or a promo clip
        // instead of the real recording. pyncmd above resolves by the original
        // NetEase id and is always an exact match.
        guard UserDefaults.standard.bool(forKey: fallbackDefaultsKey) else {
            return Resolution(source: nil, attemptedSources: newlyAttemptedSources)
        }

        for provider in fallbackProviders where enabledSources.contains(provider.id)
            && !attemptedSources.contains(provider.id) {
            newlyAttemptedSources.insert(provider.id)
            do {
                if let resolved = try await provider.resolve(track: track) {
                    return Resolution(source: resolved, attemptedSources: newlyAttemptedSources)
                }
            } catch {
                logFailure(source: provider.id, operation: "resolve", error: error)
            }
        }
        return Resolution(source: nil, attemptedSources: newlyAttemptedSources)
    }

    private static func pyncmd(_ track: Track) async throws -> ResolvedAudioSource {
        // Ask for the best tier first, then a lower one: GD Studio answers
        // `{"url":"","br":0}` (or 503 when throttled) for a tier it cannot serve,
        // and stepping down recovers tracks that only exist below 320 kbps.
        var lastError: Error = AudioSourceProviderError.missingStreamURL
        for bitrate in [320, 192] {
            let urlString = "https://music-api.gdstudio.xyz/api.php?types=url&source=netease&id=\(track.id)&br=\(bitrate)"
            do {
                let data = try await httpClient.data(
                    from: urlString,
                    source: .pyncmd,
                    operation: "resolve"
                )
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw AudioSourceProviderError.invalidResponse
                }
                guard let br = object["br"] as? Int, br > 0 else {
                    throw AudioSourceProviderError.missingBitrate
                }
                guard let urlValue = object["url"] as? String, !urlValue.isEmpty else {
                    throw AudioSourceProviderError.missingStreamURL
                }
                guard let url = URL(string: urlValue.replacingOccurrences(of: "http://", with: "https://")) else {
                    throw AudioSourceProviderError.invalidURL
                }
                return ResolvedAudioSource(id: .pyncmd, displayName: AudioSourceID.pyncmd.displayName, url: url)
            } catch {
                lastError = error
                logFailure(source: .pyncmd, operation: "resolve(br=\(bitrate))", error: error)
            }
        }
        throw lastError
    }

    private static func logFailure(source: AudioSourceID, operation: String, error: Error) {
        log.error(
            "source=\(source.rawValue, privacy: .public) operation=\(operation, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
        )
    }
}
