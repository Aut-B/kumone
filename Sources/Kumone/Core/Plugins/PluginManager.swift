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
        let url: String
    }

    /// Preset store — user-provided sources plus well-known community plugins.
    static let presetSources: [PresetSource] = [
        .init(name: "网易云音乐 (ThomasBy2025)", url: "https://raw.githubusercontent.com/ThomasBy2025/musicfree/refs/heads/main/plugins/wy.js"),
        .init(name: "网易云音乐 (元力)", url: "https://13413.kstore.vip/yuanli/wy.js"),
        .init(name: "QQ 音乐 (元力)", url: "https://13413.kstore.vip/yuanli/qq.js"),
        .init(name: "酷我音乐 (元力)", url: "https://13413.kstore.vip/yuanli/kw.js"),
        .init(name: "哔哩哔哩", url: "https://raw.githubusercontent.com/zhuguibiao/m-plugins/main/bilibili.js"),
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

    @discardableResult
    func install(from urlString: String) async throws -> InstalledPlugin {
        guard let url = URL(string: urlString), url.scheme != nil else {
            throw PluginEngineError.script(String(localized: "无效的插件地址"))
        }
        isInstalling = true
        defer { isInstalling = false }

        // Download the plugin source.
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let code = String(data: data, encoding: .utf8), code.count > 100 else {
            throw PluginEngineError.script(String(localized: "插件下载失败（请检查地址）"))
        }

        // Mount to validate and learn its platform name.
        let mount = try await engine.mount(code: code, installName: url.lastPathComponent)
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
            sourceURL: urlString,
            enabled: true,
            fileName: fileName,
            hash: hash
        )
        plugins.removeAll { $0.platform == mount.platform }
        plugins.append(installed)
        persistRegistry()
        lastError = nil
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
        let items = rawItems.compactMap { normalizeItem($0, platform: platform) }
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

    private func normalizeItem(_ dict: [String: Any], platform: String) -> PluginMusicItem? {
        guard let itemID = dict["id"] as? String, !itemID.isEmpty else { return nil }
        let title = (dict["title"] as? String) ?? (dict["name"] as? String) ?? itemID
        let artist = (dict["artist"] as? String) ?? String(localized: "未知歌手")
        let album = (dict["album"] as? String) ?? String(localized: "未知专辑")
        let artwork = (dict["artwork"] as? String) ?? (dict["picUrl"] as? String)
        let durationSeconds = (dict["duration"] as? NSNumber)?.doubleValue ?? 0
        let rawJSON = (try? JSONSerialization.data(withJSONObject: dict)).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? "{}"
        return PluginMusicItem(
            id: "\(platform)|\(itemID)",
            platform: platform,
            itemID: itemID,
            title: title,
            artist: artist,
            album: album,
            artwork: artwork,
            durationMS: Int(durationSeconds * 1000),
            rawJSON: rawJSON
        )
    }
}
