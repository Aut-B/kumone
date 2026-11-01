#if os(iOS)
import Foundation
import UIKit

/// 把收藏里的视频下到本地，播放时直接读文件。
///
/// 抖音 / TikTok 网页里拿到的直链都带过期签名（两小时左右），放着不动的收藏
/// 会一条条变成「不能听」。抖音还能用 `video_id` 换个长期地址，TikTok 没有
/// 这种接口——不落本地就只能趁刚抓完那一会儿听。
///
/// 所以：抓完自动下到 `Documents/ShortVideo/media/<platform>/<id>.mp4`，
/// 播放时优先用本地文件，文件不在才回落到网络地址。
@MainActor
final class ShortVideoMediaCache: ObservableObject {
    static let shared = ShortVideoMediaCache()

    /// 一次最多缓存这么多条（一条 15~60 秒的视频大约 2~6 MB）。
    static let maxItems = 500

    @Published private(set) var runningPlatform: ShortVideoPlatform?
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    @Published private(set) var lastError: String?

    private var worker: Task<Void, Never>?

    var isRunning: Bool { worker != nil }

    // MARK: - 路径

    nonisolated private static var root: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShortVideo/media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    nonisolated private static func folder(_ platform: ShortVideoPlatform) -> URL {
        let dir = root.appendingPathComponent(platform.rawValue, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 本地已经有这个文件就返回它。
    nonisolated static func localURL(platform: ShortVideoPlatform, id: String) -> URL? {
        guard !id.isEmpty else { return nil }
        let url = folder(platform).appendingPathComponent("\(id).mp4")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    nonisolated static func cachedCount(_ platform: ShortVideoPlatform) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder(platform).path)) ?? []
        return names.filter { $0.hasSuffix(".mp4") }.count
    }

    nonisolated static func cachedBytes(_ platform: ShortVideoPlatform) -> Int64 {
        let dir = folder(platform)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var total: Int64 = 0
        for name in names where name.hasSuffix(".mp4") {
            let values = try? dir.appendingPathComponent(name)
                .resourceValues(forKeys: [.fileSizeKey])
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

    // MARK: - 下载

    /// 把还没缓存过的条目按顺序下下来。已经在跑的不会重入。
    func cacheAll(_ videos: [ShortVideo], platform: ShortVideoPlatform) {
        guard !isRunning else { return }
        let pending = videos.prefix(Self.maxItems).filter {
            !$0.playURL.isEmpty && Self.localURL(platform: platform, id: $0.id) == nil
        }
        guard !pending.isEmpty else { return }

        runningPlatform = platform
        completed = 0
        total = pending.count
        lastError = nil

        // 下几百条要几分钟；申请一点后台时间，切出去也别立刻断。
        let background = UIApplication.shared.beginBackgroundTask(withName: "ShortVideoCache")
        worker = Task { [weak self] in
            for video in pending {
                if Task.isCancelled { break }
                await self?.download(video, platform: platform)
                self?.completed += 1
            }
            self?.runningPlatform = nil
            self?.worker = nil
            if background != .invalid {
                UIApplication.shared.endBackgroundTask(background)
            }
        }
    }

    func cancel() {
        worker?.cancel()
        worker = nil
        runningPlatform = nil
    }

    func clear(_ platform: ShortVideoPlatform) {
        cancel()
        let dir = Self.folder(platform)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names where name.hasSuffix(".mp4") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        objectWillChange.send()
    }

    private func download(_ video: ShortVideo, platform: ShortVideoPlatform) async {
        guard let url = URL(string: video.playURL) else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(platform.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(platform.referer, forHTTPHeaderField: "Referer")

        do {
            let (temp, response) = try await URLSession.shared.download(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                lastError = "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"
                return
            }
            let target = Self.folder(platform).appendingPathComponent("\(video.id).mp4")
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: temp, to: target)
        } catch {
            lastError = error.localizedDescription
        }
    }
}
#endif