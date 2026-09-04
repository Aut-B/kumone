import CryptoKit
import Foundation
import SwiftUI

/// Manages the MusicFree-compatible plugin ecosystem: installation from URL,
/// persistence, mounting, search and media-source resolution.
@MainActor
final class PluginManager: ObservableObject {
    static let shared = PluginManager()

    struct InstalledPlugin: Codable, Identifiable, Hashable {
        var id: String { platform }
        var platform: String
        var name: String
        var version: String?
        var sourceURL: String?
        var enabled: Bool
        var fileName: String
        var hash: String
    }

    struct PresetSource: Identifiable, Hashable {
        let id = UUID()
        let name: String
        /// Ordered candidate URLs; the first reachable one wins.
        let mirrors: [String]
    }

    private static func githubMirrors(_ rawURL: String) -> [String] {
        [
            rawURL,
            rawURL.replacingOccurrences(of: "raw.githubusercontent.com/", with: "cdn.jsdelivr.net/gh/")
                .replacingOccurrences(of: "/refs/heads/", with: "@")
                .replacingOccurrences(of: "@main", with: "@main"),
            "https://ghfast.top/" + rawURL,
            "https://gh-proxy.com/" + rawURL,
        ]
    }

    /// Preset store — user-provided sources plus well-known community plugins.
    /// GitHub-hosted entries carry raw/jsdelivr/ghproxy mirrors so mainland
    /// networks that block raw.githubusercontent.com can still install.
    static let presetSources: [PresetSource] = [
        .init(name: "网易云音乐 (ThomasBy2025)", mirrors: githubMirrors("https://raw.githubusercontent.com/ThomasBy2025/musicfree/refs/heads/main/plugins/wy.js")),
        .init(name: "网易云音乐 (元力)", mirrors: ["https://13413.kstore.vip/yuanli/wy.js"]),
        .init(name: "QQ 音乐 (元力)", mirrors: ["https://13413.kstore.vip/yuanli/qq.js"]),
        .init(name: "酷我音乐 (元力)", mirrors: ["https://13413.kstore.vip/yuanli/kw.js"]),
        .init(name: "哔哩哔哩 (官方)", mirrors: githubMirrors("https://raw.githubusercontent.com/maotoumao/MusicFreePlugins/master/dist/bilibili/index.js")),
        .init(name: "哔哩哔哩 (zhuguibiao)", mirrors: githubMirrors("https://raw.githubusercontent.com/zhuguibiao/m-plugins/main/bilibili.js")),
        // From the user's MusicFree backup — the sources their playlists rely on.
        .init(name: "网易云音乐 (备份同款)", mirrors: githubMirrors("https://raw.githubusercontent.com/ThomasBy2025/musicfree/refs/heads/main/plugins/wy.js")),
        .init(name: "歌词千寻", mirrors: ["https://gitee.com/maotoumao/MusicFreePlugins/raw/v0.1/dist/geciqianxun/index.js"]),
        .init(name: "歌词王", mirrors: ["https://gitee.com/maotoumao/MusicFreePlugins/raw/v0.1/dist/geciwang/index.js"]),
        .init(name: "QQ (海棠)", mirrors: ["http://music.haitangw.net/cqapi/qq.js"]),
        .init(name: "酷狗 (海棠)", mirrors: ["http://music.haitangw.net/cqapi/kg.js"]),
        .init(name: "酷我 (海棠)", mirrors: ["http://music.haitangw.net/cqapi/kw.js"]),
        .init(name: "小米音乐 (海棠)", mirrors: ["http://music.haitangw.net/cqapi/xiaomi.js"]),
        .init(name: "小蜗音乐", mirrors: ["https://gitee.com/kevinr/tvbox/raw/master/musicfree/plugins/xiaowo.js"]),
        .init(name: "AT 音源", mirrors: ["https://gitee.com/kevinr/tvbox/raw/master/musicfree/plugins/at.js"]),
        .init(name: "酷狗 (teyonds)", mirrors: ["http://cdn.teyonds.com/music/kg"]),
        .init(name: "QQ (teyonds)", mirrors: ["http://cdn.teyonds.com/music/qq"]),
        .init(name: "酷我 (teyonds)", mirrors: ["http://cdn.teyonds.com/music/kw"]),
        .init(name: "网易云电台", mirrors: ["https://fastly.jsdelivr.net/gh/GuGuMur/MusicFreePlugin-NeteaseRadio@master/dist/plugin.js"]),
    ]

    @Published private(set) var plugins: [InstalledPlugin] = []
    @Published var lastError: String?
    @Published private(set) var isInstalling = false

    private let engine = PluginEngine.shared

    // MARK: - Storage

    private var baseDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Plugins", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var registryURL: URL { baseDirectory.appendingPathComponent("plugins.json") }
    private var variablesDirectory: URL {
        let dir = baseDirectory.appendingPathComponent("Variables", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {
        engine.setVariablesDirectory(variablesDirectory)
        loadRegistry()
    }

    private func loadRegistry() {
        guard let data = try? Data(contentsOf: registryURL),
              let list = try? JSONDecoder().decode([InstalledPlugin].self, from: data) else { return }
        plugins = list
        Task { await mountEnabled() }
    }

    private func persistRegistry() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(plugins) {
            try? data.write(to: registryURL, options: .atomic)
        }
    }

    private func mountEnabled() async {
        for plugin in plugins where plugin.enabled {
            let codeURL = baseDirectory.appendingPathComponent(plugin.fileName)
            guard let code = try? String(contentsOf: codeURL, encoding: .utf8) else { continue }
            _ = try? await engine.mount(code: code, installName: plugin.name)
        }
    }

    // MARK: - Install / remove / toggle

    /// Installs a plugin from a single URL.
    @discardableResult
    func install(from urlString: String) async throws -> InstalledPlugin {
        try await install(fromMirrors: [urlString])
    }

    /// Installs a plugin, trying each mirror URL in order until one works.
    @discardableResult
    func install(fromMirrors mirrors: [String]) async throws -> InstalledPlugin {
        guard !mirrors.isEmpty else {
            throw PluginEngineError.script(String(localized: "无效的插件地址"))
        }
        isInstalling = true
        defer { isInstalling = false }

        var lastError: Error = PluginEngineError.script(String(localized: "插件下载失败"))
        var failedCount = 0
        for urlString in mirrors {
            guard let url = URL(string: urlString), url.scheme != nil else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let code = String(data: data, encoding: .utf8), code.count > 100 else {
                    lastError = PluginEngineError.script(
                        String(localized: "下载失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)）：\(url.host ?? urlString)"))
                    failedCount += 1
                    continue
                }
                let installed = try await finishInstall(code: code, sourceURL: urlString, fallbackName: url.lastPathComponent)
                self.lastError = nil
                return installed
            } catch {
                lastError = error
                failedCount += 1
            }
        }
        let detail = failedCount > 1 ? String(localized: "已尝试 \(failedCount) 个下载地址") : ""
        throw PluginEngineError.script("\(lastError.localizedDescription) \(detail)")
    }

    private func finishInstall(code: String, sourceURL: String, fallbackName: String) async throws -> InstalledPlugin {
        // Mount to validate and learn its platform name.
        let mount = try await engine.mount(code: code, installName: fallbackName)
        let hash = SHA256.hash(data: Data(code.utf8)).map { String(format: "%02x", $0) }.joined()

        // Persist the code file.
        let fileName = mount.platform + ".js"
        try code.write(to: baseDirectory.appendingPathComponent(fileName), atomically: true, encoding: .utf8)

        // Initialize declared userVariables with their defaults.
        initializeVariables(mount.userVariables, platform: mount.platform)

        // Update registry (replace an existing plugin with the same platform).
        let installed = InstalledPlugin(
            platform: mount.platform,
            name: mount.platform,
            version: nil,
            sourceURL: sourceURL,
            enabled: true,
            fileName: fileName,
            hash: hash
        )
        plugins.removeAll { $0.platform == mount.platform }
        plugins.append(installed)
        persistRegistry()
        return installed
    }

    func remove(_ plugin: InstalledPlugin) {
        plugins.removeAll { $0.platform == plugin.platform }
        persistRegistry()
        try? FileManager.default.removeItem(at: baseDirectory.appendingPathComponent(plugin.fileName))
        try? FileManager.default.removeItem(at: variablesDirectory.appendingPathComponent(plugin.platform + ".json"))
    }

    func setEnabled(_ enabled: Bool, for plugin: InstalledPlugin) {
        guard let index = plugins.firstIndex(where: { $0.platform == plugin.platform }) else { return }
        plugins[index].enabled = enabled
        persistRegistry()
        if enabled {
            Task {
                let codeURL = baseDirectory.appendingPathComponent(plugin.fileName)
                guard let code = try? String(contentsOf: codeURL, encoding: .utf8) else { return }
                _ = try? await engine.mount(code: code, installName: plugin.name)
            }
        }
    }

    private func initializeVariables(_ declarations: [[String: Any]], platform: String) {
        var variables = [String: Any]()
        for declaration in declarations {
            guard let key = declaration["key"] as? String else { continue }
            if let current = storedVariables(platform: platform)[key] {
                variables[key] = current
            } else if let defaultValue = declaration["defaultValue"] {
                variables[key] = defaultValue
            }
        }
        guard !variables.isEmpty else { return }
        if let data = try? JSONSerialization.data(withJSONObject: variables, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: variablesDirectory.appendingPathComponent(platform + ".json"), options: .atomic)
        }
    }

    private func storedVariables(platform: String) -> [String: Any] {
        let url = variablesDirectory.appendingPathComponent(platform + ".json")
        guard let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return [:]
        }
        return object
    }

    // MARK: - Search & playback resolution

    /// Installs plugin code directly (e.g. from a MusicFree backup file).
    func installFromCode(_ code: String, sourceName: String) async throws {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 100 else {
            throw PluginEngineError.script(String(localized: "插件代码无效"))
        }
        _ = try await finishInstall(code: trimmed, sourceURL: sourceName, fallbackName: sourceName)
        lastError = nil
    }

    /// Bilibili BV-id exact resolution: when the query IS a BV id, resolve the
    /// video directly via the `view` API instead of keyword search, so the
    /// result always matches the intended video.
    func resolveBilibiliBV(_ query: String, platform: String) async -> PluginMusicItem? {
        guard query.range(of: "^BV[0-9A-Za-z]{10}$", options: .regularExpression) != nil,
              platform.lowercased().contains("bili") else { return nil }
        guard let url = URL(string: "https://api.bilibili.com/x/web-interface/view?bvid=\(query)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/89.0.4389.90 Safari/537.36",
            forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let detail = json["data"] as? [String: Any] else { return nil }
        let title = (detail["title"] as? String) ?? query
        let owner = ((detail["owner"] as? [String: Any])?["name"] as? String) ?? "哔哩哔哩"
        let pic = detail["pic"] as? String
        let durationSeconds = (detail["duration"] as? NSNumber)?.intValue ?? 0
        var itemDict: [String: Any] = [
            "id": query,
            "platform": platform,
            "bvid": query,
            "title": title,
            "artist": owner,
            "album": "哔哩哔哩",
            "duration": Double(durationSeconds),
        ]
        if let pic { itemDict["artwork"] = pic }
        return PluginMusicItem(normalizing: itemDict, platform: platform)
    }

    /// Searches a single plugin for music. `page` starts at 1.
    func search(platform: String, query: String, page: Int) async throws -> (isEnd: Bool, items: [PluginMusicItem]) {
        let value = try await engine.call(platform: platform, method: "search", args: [query, page, "music"])
        guard let result = value as? [String: Any] else {
            throw PluginEngineError.script(String(localized: "搜索返回格式异常"))
        }
        let isEnd = result["isEnd"] as? Bool ?? true
        let rawItems = result["data"] as? [[String: Any]] ?? []
        let items = rawItems.compactMap { PluginMusicItem(normalizing: $0, platform: platform) }
        return (isEnd, items)
    }

    /// Resolves a playable URL (+ optional headers) via the plugin's `getMediaSource`.
    func getMediaSource(platform: String, item: PluginMusicItem, quality: String) async -> PluginMediaSource {
        guard let itemData = item.rawJSON.data(using: .utf8),
              let itemObject = (try? JSONSerialization.jsonObject(with: itemData)) as? [String: Any] else {
            return PluginMediaSource(url: nil, headers: nil)
        }
        // Bilibili: resolve natively FIRST. The native path (view -> cid ->
        // playurl -> audio) is proven on-device independent of the JS engine;
        // the plugin's JS only handles search. Older saved playlists may lack
        // `bvid` — for BV ids the item id IS the bvid.
        let bvid = (itemObject["bvid"] as? String)
            ?? ((itemObject["id"] as? String).flatMap { $0.hasPrefix("BV") ? $0 : nil })
        if let bvid {
            let native = await Self.nativeBilibiliMediaURL(bvid: bvid)
            if let nativeURL = native.url {
                return PluginMediaSource(url: nativeURL, headers: native.headers)
            }
        }
        // Netease-family: resolve natively FIRST — fast and correct (the item
        // id IS the Netease song id); no JS involvement, no long waits.
        if isNeteasePlatform(platform) {
            if let nativeURL = await Self.nativeNeteaseURL(itemObject: itemObject, title: item.title, artist: item.artist) {
                return PluginMediaSource(url: nativeURL, headers: nil)
            }
        }
        // Other platforms: the item's own plugin first, then a BOUNDED set of
        // other enabled plugins (short timeouts so a song never hangs).
        var result: [String: Any]?
        let others = plugins.filter { $0.enabled && $0.platform != platform }.map(\.platform)
        let candidates = [platform] + others.prefix(4)
        for (index, candidate) in candidates.enumerated() {
            let timeout: TimeInterval = index == 0 ? 12 : 8
            guard let value = try? await engine.call(
                platform: candidate, method: "getMediaSource", args: [itemObject, quality], timeout: timeout
            ), let dict = value as? [String: Any],
            let urlString = dict["url"] as? String, !urlString.isEmpty else { continue }
            result = dict
            break
        }
        var url: URL?
        if let result, let urlString = result["url"] as? String, !urlString.isEmpty {
            url = URL(string: urlString.replacingOccurrences(of: "http://", with: "https://"))
        }
        let headers = (result?["headers"] as? [String: Any])?.reduce(into: [String: String]()) { dict, pair in
            if let value = pair.value as? String { dict[pair.key] = value }
        }
        return PluginMediaSource(url: url, headers: headers)
    }

    /// Native Netease resolution: eapi songURL (valid levels) then unblock.
    private static func nativeNeteaseURL(itemObject: [String: Any], title: String, artist: String) async -> URL? {
        guard let songID = Int(itemObject["id"] as? String ?? "") else { return nil }
        let level = SettingsManager.shared.audioQuality.rawValue
        var data = try? await NeteaseAPI.songURL(ids: [songID], level: level).first
        if data?.url == nil {
            data = try? await NeteaseAPI.songURL(ids: [songID], level: "standard").first
        }
        if let urlString = data?.url, !urlString.isEmpty {
            return URL(string: urlString.replacingOccurrences(of: "http://", with: "https://"))
        }
        let fallback = Track(fallbackNeteaseID: songID, name: title, artist: artist)
        return await UnblockService.resolve(fallback)?.url
    }

    private func isNeteasePlatform(_ platform: String) -> Bool {
        let lower = platform.lowercased()
        return lower.contains("网易") || lower.contains("netease") || lower.contains("163")
    }

    /// Direct B站 resolution: view → cid → playurl → first audio stream.
    static func nativeBilibiliMediaURL(bvid: String) async -> (url: URL?, headers: [String: String]?) {
        let browserHeaders = [
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/89.0.4389.90 Safari/537.36",
            "Referer": "https://www.bilibili.com/",
        ]
        var viewRequest = URLRequest(url: URL(string: "https://api.bilibili.com/x/web-interface/view?bvid=\(bvid)")!)
        viewRequest.timeoutInterval = 10
        browserHeaders.forEach { viewRequest.setValue($0.value, forHTTPHeaderField: $0.key) }
        guard let (viewData, _) = try? await URLSession.shared.data(for: viewRequest),
              let viewJSON = (try? JSONSerialization.jsonObject(with: viewData)) as? [String: Any],
              let detail = viewJSON["data"] as? [String: Any],
              let cid = (detail["cid"] as? NSNumber)?.stringValue ?? detail["cid"] as? String else {
            return (nil, nil)
        }
        var playRequest = URLRequest(url: URL(string: "https://api.bilibili.com/x/player/playurl?bvid=\(bvid)&cid=\(cid)&fnval=16&platform=html5")!)
        playRequest.timeoutInterval = 10
        browserHeaders.forEach { playRequest.setValue($0.value, forHTTPHeaderField: $0.key) }
        guard let (playData, _) = try? await URLSession.shared.data(for: playRequest),
              let playJSON = (try? JSONSerialization.jsonObject(with: playData)) as? [String: Any],
              let data = playJSON["data"] as? [String: Any] else {
            return (nil, nil)
        }
        // Prefer DASH audio (best quality), fall back to durl.
        var urlString: String?
        if let dash = data["dash"] as? [String: Any],
           let audios = dash["audio"] as? [[String: Any]],
           let first = audios.first {
            urlString = first["baseUrl"] as? String
        }
        if urlString == nil, let durl = data["durl"] as? [[String: Any]], let first = durl.first {
            urlString = first["url"] as? String
        }
        guard let urlString, !urlString.isEmpty,
              let url = URL(string: urlString.replacingOccurrences(of: "http://", with: "https://")) else {
            return (nil, nil)
        }
        return (url, browserHeaders)
    }

}
