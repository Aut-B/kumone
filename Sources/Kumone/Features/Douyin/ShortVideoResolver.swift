#if os(iOS)
import Foundation

/// 把「抓到的签名直链」换成「不会过期的地址」。
///
/// 抖音 / TikTok 网页里拿到的 `play_addr.url_list` 带 `expire` 签名，两小时左右
/// 就失效——放着不动的收藏会一条条变成「不能听」，同步到另一台手机更是全都不能听。
///
/// 站点自己还有一个只用 `video_id` 的老播放接口，它会 302 到一个新鲜的 CDN 地址，
/// 不带过期签名。我们先探一下它通不通：通就用它（长期有效、跨设备有效），
/// 不通再退回签名直链（至少当下能播）。
enum ShortVideoResolver {
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var hits: [String: (url: String, at: Date)] = [:]

        func get(_ key: String) -> String? {
            lock.lock()
            defer { lock.unlock() }
            guard let hit = hits[key],
                  Date().timeIntervalSince(hit.at) < 1800 else { return nil }
            return hit.url
        }

        func set(_ key: String, _ url: String) {
            lock.lock()
            hits[key] = (url, Date())
            lock.unlock()
        }
    }

    private static let cache = Cache()

    /// 优先返回长期有效的地址；探测失败时退回 `fallback`（签名直链）。
    static func resolve(platform: ShortVideoPlatform,
                        videoID: String?,
                        fallback: String) async -> URL? {
        let trimmed = (videoID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let key = "\(platform.rawValue):\(trimmed)"
            if let hit = cache.get(key) { return URL(string: hit) }
            if let stable = stableURL(platform: platform, videoID: trimmed),
               await probe(stable, platform: platform) {
                cache.set(key, stable.absoluteString)
                return stable
            }
        }
        return URL(string: fallback)
    }

    static func stableURL(platform: ShortVideoPlatform, videoID: String) -> URL? {
        let encoded = videoID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? videoID
        switch platform {
        case .douyin:
            return URL(string: "https://www.iesdouyin.com/aweme/v1/play/?video_id=\(encoded)&ratio=720p&line=0")
        case .tiktok:
            return URL(string: "https://api16-normal-c-useast1a.tiktokv.com/aweme/v1/play/?video_id=\(encoded)&ratio=720p&line=0")
        }
    }

    /// 只取两个字节确认能播，别把整段视频拉下来。
    private static func probe(_ url: URL, platform: ShortVideoPlatform) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        request.setValue(platform.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(platform.referer, forHTTPHeaderField: "Referer")
        request.timeoutInterval = 6

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            guard http.statusCode == 200 || http.statusCode == 206 else { return false }
            let type = (http.mimeType ?? "").lowercased()
            return type.isEmpty || type.contains("video") || type.contains("octet-stream")
        } catch {
            return false
        }
    }
}
#endif