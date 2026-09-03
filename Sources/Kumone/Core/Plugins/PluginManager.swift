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
        .init(name: "哔哩哔哩", mirrors: githubMirrors("https://raw.githubusercontent.com/zhuguibiao/m-plugins/main/bilibili.js")),
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
        guard let value = try? await engine.call(
            platform: platform, method: "getMediaSource", args: [itemObject, quality], timeout: 30
        ), let result = value as? [String: Any] else {
            return PluginMediaSource(url: nil, headers: nil)
        }
        var url: URL?
        if let urlString = result["url"] as? String, !urlString.isEmpty {
            url = URL(string: urlString.replacingOccurrences(of: "http://", with: "https://"))
        }
        let headers = (result["headers"] as? [String: Any])?.reduce(into: [String: String]()) { dict, pair in
            if let value = pair.value as? String { dict[pair.key] = value }
        }
        return PluginMediaSource(url: url, headers: headers)
    }

}
