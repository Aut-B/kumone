import Foundation
import os.log

/// Resolves gray tracks from the direct pyncmd source, then built-in search
/// providers when pyncmd cannot serve the original song ID.
enum UnblockService {
    private static let log = Logger(subsystem: "sb.moe.kumone", category: "audio-source")
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
        guard !Task.isCancelled else { return Resolution(source: nil, attemptedSources: []) }
        if enabledSources.contains(.pyncmd), !attemptedSources.contains(.pyncmd) {
            newlyAttemptedSources.insert(.pyncmd)
            do {
                return Resolution(
                    source: try await pyncmd(track),
                    attemptedSources: newlyAttemptedSources
                )
            } catch {
                if Task.isCancelled { return Resolution(source: nil, attemptedSources: newlyAttemptedSources) }
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
            guard !Task.isCancelled else { break }
            newlyAttemptedSources.insert(provider.id)
            do {
                if let resolved = try await provider.resolve(track: track) {
                    return Resolution(source: resolved, attemptedSources: newlyAttemptedSources)
                }
            } catch {
                if Task.isCancelled { break }
                logFailure(source: provider.id, operation: "resolve", error: error)
            }
        }
        return Resolution(source: nil, attemptedSources: newlyAttemptedSources)
    }

    private static func pyncmd(_ track: Track) async throws -> ResolvedAudioSource {
        let urlString = "https://music-api.gdstudio.xyz/api.php?types=url&source=\(Upstream.tag)&id=\(track.id)&br=320"
        let data = try await httpClient.data(
            from: urlString,
            source: .pyncmd,
            operation: "resolve"
        )
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AudioSourceProviderError.invalidResponse
        }
        throw lastError
    }

    private static func logFailure(source: AudioSourceID, operation: String, error: Error) {
        log.error(
            "source=\(source.rawValue, privacy: .public) operation=\(operation, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
        )
    }
}
