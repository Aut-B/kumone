import Foundation
import SwiftUI

// MARK: - WebDAV config

struct WebDAVConfig: Codable {
    var server: String = ""
    var username: String = ""
    var password: String = ""

    var isValid: Bool {
        !server.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.isEmpty && !password.isEmpty
    }

    func authorizationHeader() -> String? {
        guard !username.isEmpty, !password.isEmpty else { return nil }
        let raw = "\(username):\(password)"
        return "Basic \(Data(raw.utf8).base64EncodedString())"
    }
}

enum WebDAVError: LocalizedError {
    case badServer
    case unauthorized
    case malformedResponse
    case downloadFailed(Int)
    case listFailed(Int)
    case uploadFailed(Int, String)
    case mkdirFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .badServer:
            return String(localized: "WebDAV 地址无效")
        case .unauthorized:
            return String(localized: "WebDAV 账号或密码错误（注意要填应用授权密码，不是登录密码）")
        case .malformedResponse:
            return String(localized: "WebDAV 响应解析失败")
        case .downloadFailed(let code):
            return String(localized: "下载失败（HTTP \(code)）")
        case .listFailed(let code):
            if code == 401 || code == 403 {
                return String(localized: "连接失败（HTTP \(code)）：账号或密码不对。注意要填应用授权密码，不是登录密码。")
            }
            if code == 404 {
                return String(localized: "连接失败（HTTP 404）：服务器上没有这个目录。请检查「WebDAV 设置」里的地址，坚果云一般是 https://dav.jianguoyun.com/dav/")
            }
            return String(localized: "连接失败（HTTP \(code)）")
        case .uploadFailed(let code, let url):
            if code == 404 || code == 409 {
                return String(localized: "上传失败（HTTP \(code)）：地址指向的目录在服务器上不存在，而且自动创建也没成功。请确认地址形如 https://dav.jianguoyun.com/dav/ ，再试一次。\n目标：\(url)")
            }
            if code == 401 || code == 403 {
                return String(localized: "上传失败（HTTP \(code)）：账号或密码不对，或者这个目录没有写入权限。")
            }
            if code == 507 {
                return String(localized: "上传失败（HTTP 507）：网盘空间不足。")
            }
            return String(localized: "上传失败（HTTP \(code)）：\n目标：\(url)")
        case .mkdirFailed(let code, let url):
            if code == 401 || code == 403 {
                return String(localized: "无法创建远程目录（HTTP \(code)）：账号或密码不对，或者没有权限。")
            }
            return String(localized: "无法创建远程目录（HTTP \(code)）：\n\(url)")
        }
    }
}

// MARK: - WebDAV client

struct WebDAVEntry: Identifiable, Hashable {
    let id = UUID()
    let name: String
    /// Absolute URL of the entry.
    let urlString: String
    let isDirectory: Bool
    let size: Int?
}

/// Minimal native WebDAV client: PROPFIND directory listing + GET download.
enum WebDAVClient {
    /// Builds a URL tolerantly (WebDAV hrefs may contain percent-escapes
    /// that `URL(string:)` rejects, or raw spaces in display paths).
    static func robustURL(_ string: String) -> URL? {
        if let url = URL(string: string), url.scheme != nil { return url }
        if let url = URLComponents(string: string)?.url, url.scheme != nil { return url }
        return URL(string: string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? string)
    }

    /// Lists entries under an absolute collection URL (from a PROPFIND href).
    static func list(urlString: String, username: String, password: String) async throws -> [WebDAVEntry] {
        guard let url = robustURL(urlString) else { throw WebDAVError.badServer }

        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.timeoutInterval = 20
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Basic \(Data("\(username):\(password)".utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:">
          <d:prop>
            <d:resourcetype/>
            <d:displayname/>
            <d:getcontentlength/>
          </d:prop>
        </d:propfind>
        """
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.malformedResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw WebDAVError.unauthorized }
        guard http.statusCode == 207 else { throw WebDAVError.listFailed(http.statusCode) }
        guard let xml = String(data: data, encoding: .utf8) else { throw WebDAVError.malformedResponse }

        var entries: [WebDAVEntry] = []
        let parser = WebDAVListParser()
        parser.parse(xml) { entry in
            // Drop the collection's own href (same as the requested URL).
            if entry.urlString == urlString { return }
            entries.append(entry)
        }
        // Some servers return scheme-less hrefs ("/dav/musicfree/"); resolve
        // them against the requested collection URL so navigation always
        // yields an absolute URL.
        let resolved = entries.map { entry -> WebDAVEntry in
            if let existing = robustURL(entry.urlString), existing.scheme != nil {
                return entry
            }
            var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
            let href = entry.urlString
            if href.hasPrefix("/") {
                components?.path = href
                components?.query = nil
                components?.fragment = nil
            } else {
                var basePath = components?.path ?? "/"
                if !basePath.hasSuffix("/") { basePath += "/" }
                components?.path = basePath + href
                components?.query = nil
                components?.fragment = nil
            }
            let absolute = components?.string ?? (url.absoluteString + entry.urlString)
            return WebDAVEntry(
                name: entry.name,
                urlString: absolute,
                isDirectory: entry.isDirectory,
                size: entry.size
            )
        }
        return resolved.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// Lists the root of a server. `server` must end with the collection
    /// path (e.g. https://dav.jianguoyun.com/dav/).
    static func listRoot(server: String, username: String, password: String) async throws -> [WebDAVEntry] {
        var urlString = server.trimmingCharacters(in: .whitespaces)
        if !urlString.hasSuffix("/") { urlString += "/" }
        return try await list(urlString: urlString, username: username, password: password)
    }

    /// Downloads a file over WebDAV.
    static func download(urlString: String, username: String, password: String) async throws -> Data {
        guard let url = robustURL(urlString) else { throw WebDAVError.badServer }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Basic \(Data("\(username):\(password)".utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw WebDAVError.downloadFailed((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return data
    }

    /// Uploads (PUT) a file over WebDAV, creating the target collection first
    /// when the server does not have it yet.
    ///
    /// PUT alone never creates folders: 坚果云 (and most other servers) answer
    /// `404` — not `409` — when the parent collection is missing, so a path the
    /// user typed but never created used to look like a broken upload. The
    /// address is still the account root or an existing folder in the common
    /// case, where `ensureParentCollection` is a no-op.
    static func upload(data: Data, urlString: String, username: String, password: String) async throws {
        guard let url = robustURL(urlString) else { throw WebDAVError.badServer }
        try await ensureParentCollection(of: url, username: username, password: password)
        let status = try await put(data: data, url: url, username: username, password: password)
        if (200..<300).contains(status) { return }
        if status == 401 || status == 403 { throw WebDAVError.unauthorized }
        // The folder may have been renamed or removed between the check and the
        // write; create the chain once more and retry a single time.
        if status == 404 || status == 409 {
            try await createCollectionChain(for: url, username: username, password: password)
            let retried = try await put(data: data, url: url, username: username, password: password)
            if (200..<300).contains(retried) { return }
            throw WebDAVError.uploadFailed(retried, url.absoluteString)
        }
        throw WebDAVError.uploadFailed(status, url.absoluteString)
    }

    /// The collection a PUT writes into, for telling the user where the backup
    /// landed (it is easy to be unsure which folder a URL points at).
    static func directoryDescription(of urlString: String) -> String {
        guard let url = robustURL(urlString) else { return urlString }
        return directoryURL(of: url)?.absoluteString ?? urlString
    }

    // MARK: - Upload plumbing

    /// Makes sure the file's folder exists, creating the whole chain when the
    /// server does not have it yet.
    private static func ensureParentCollection(of url: URL, username: String, password: String) async throws {
        guard let directory = directoryURL(of: url) else { return }
        if try await collectionExists(directory, username: username, password: password) { return }
        try await createCollectionChain(for: url, username: username, password: password)
    }

    private static func authHeader(_ username: String, _ password: String) -> String {
        "Basic \(Data("\(username):\(password)".utf8).base64EncodedString())"
    }

    /// The collection part of a file URL (keeps the trailing slash).
    private static func directoryURL(of url: URL) -> URL? {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var path = components?.path ?? ""
        if path.hasSuffix("/") { return url }
        if let slash = path.range(of: "/", options: .backwards) {
            path = String(path[path.startIndex..<slash.lowerBound])
        } else {
            path = ""
        }
        if !path.hasSuffix("/") { path += "/" }
        components?.path = path
        components?.query = nil
        components?.fragment = nil
        return components?.url
    }

    private static func put(data: Data, url: URL, username: String, password: String) async throws -> Int {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 60
        request.setValue(authHeader(username, password), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.malformedResponse }
        return http.statusCode
    }

    private static func mkcol(url: URL, username: String, password: String) async throws -> Int {
        var request = URLRequest(url: url)
        request.httpMethod = "MKCOL"
        request.timeoutInterval = 20
        request.setValue(authHeader(username, password), forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.malformedResponse }
        return http.statusCode
    }

    private static func collectionExists(_ url: URL, username: String, password: String) async throws -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.timeoutInterval = 20
        request.setValue("0", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeader(username, password), forHTTPHeaderField: "Authorization")
        let body = #"<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>"#
        request.httpBody = body.data(using: .utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.malformedResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw WebDAVError.unauthorized }
        return http.statusCode == 207
    }

    /// Creates every missing collection along the file's directory path — the
    /// equivalent of `mkdir -p`. Servers answer `405` for a folder that is
    /// already there, which is a success here.
    private static func createCollectionChain(for url: URL, username: String, password: String) async throws {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw WebDAVError.badServer
        }
        var path = components.path
        if !path.hasSuffix("/") {
            if let slash = path.range(of: "/", options: .backwards) {
                path = String(path[path.startIndex..<slash.lowerBound])
            } else {
                path = ""
            }
        }
        components.query = nil
        components.fragment = nil
        var built = ""
        for segment in path.split(separator: "/") {
            built += "/" + segment
            components.path = built
            guard let dirURL = components.url else { continue }
            let code = try await mkcol(url: dirURL, username: username, password: password)
            // 201 created · 405 already exists · 3xx redirected. A `409` on a
            // middle segment means the server considers the parent missing, but
            // the PUT below still decides the outcome, so let it through rather
            // than failing the upload on a guess.
            if (200..<300).contains(code) || code == 405 || code == 409 || (300..<400).contains(code) {
                continue
            }
            if code == 401 || code == 403 { throw WebDAVError.unauthorized }
            throw WebDAVError.mkdirFailed(code, dirURL.absoluteString)
        }
    }
}

/// SAX-ish parser for the WebDAV multistatus response.
private final class WebDAVListParser: NSObject, XMLParserDelegate {
    private var currentHref = ""
    private var currentName = ""
    private var isDirectory = false
    private var currentSize: Int?
    private var inHref = false
    private var inDisplayName = false
    private var inCollection = false
    private var inContentLength = false
    private var textBuffer = ""
    private var completion: ((WebDAVEntry) -> Void)?

    func parse(_ xml: String, completion: @escaping (WebDAVEntry) -> Void) {
        self.completion = completion
        guard let data = xml.data(using: .utf8) else { return }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = true
        parser.parse()
    }

    private func localName(_ qName: String) -> String {
        qName.split(separator: ":").last.map(String.init) ?? qName
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = localName(qName ?? elementName)
        textBuffer = ""
        switch name {
        case "response":
            currentHref = ""; currentName = ""; isDirectory = false; currentSize = nil
        case "href": inHref = true
        case "displayname": inDisplayName = true
        case "collection": inCollection = true
        case "getcontentlength": inContentLength = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBuffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let name = localName(qName ?? elementName)
        switch name {
        case "href":
            inHref = false
            currentHref = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        case "displayname":
            inDisplayName = false
            currentName = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        case "collection":
            inCollection = false
            isDirectory = true
        case "getcontentlength":
            inContentLength = false
            currentSize = Int(textBuffer.trimmingCharacters(in: .whitespacesAndNewlines))
        case "response":
            let displayName = currentName.isEmpty ? (currentHref as NSString).lastPathComponent.removingPercentEncoding ?? "" : currentName
            guard !currentHref.isEmpty else { return }
            let entry = WebDAVEntry(
                name: displayName,
                urlString: currentHref,
                isDirectory: isDirectory,
                size: currentSize
            )
            completion?(entry)
        default: break
        }
    }
}

// MARK: - Imported playlist store

struct ImportedPlaylist: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var fileName: String
    var itemCount: Int
    var source: String
    var importedAt: Date

    init(name: String, fileName: String, itemCount: Int, source: String) {
        id = UUID()
        self.name = name
        self.fileName = fileName
        self.itemCount = itemCount
        self.source = source
        importedAt = Date()
    }
}

/// Playlists imported from MusicFree backups (e.g. exported JSON on WebDAV).
@MainActor
final class ImportedPlaylistStore: ObservableObject {
    static let shared = ImportedPlaylistStore()

    @Published private(set) var playlists: [ImportedPlaylist] = []

    private var directory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ImportedPlaylists", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    private init() {
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([ImportedPlaylist].self, from: data) else { return }
        playlists = list
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(playlists) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    /// Imports parsed MusicFree playlist items under a name.
    func importItems(_ items: [PluginMusicItem], name: String, source: String) throws {
        let fileName = UUID().uuidString + ".json"
        try writeItems(items, fileName: fileName)
        playlists.removeAll { $0.name == name }
        playlists.insert(ImportedPlaylist(name: name, fileName: fileName, itemCount: items.count, source: source), at: 0)
        persist()
    }

    /// Creates an empty local playlist for plugin tracks.
    @discardableResult
    func createPlaylist(name: String) throws -> ImportedPlaylist {
        let fileName = UUID().uuidString + ".json"
        try writeItems([], fileName: fileName)
        let playlist = ImportedPlaylist(name: name, fileName: fileName, itemCount: 0, source: String(localized: "本地"))
        playlists.insert(playlist, at: 0)
        persist()
        return playlist
    }

    /// Appends a plugin track to a local playlist (deduplicates by id).
    func addItem(_ item: PluginMusicItem, to playlist: ImportedPlaylist) throws {
        var items = loadItems(of: playlist)
        guard !items.contains(where: { $0.id == item.id }) else {
            throw WebDAVError.malformedResponse
        }
        items.append(item)
        try writeItems(items, fileName: playlist.fileName)
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[index].itemCount = items.count
        persist()
    }

    /// Appends many items at once, writing the file a single time.
    ///
    /// Used when a whole mixed playlist is copied over: calling `addItem` per
    /// entry would re-read and re-write the JSON for every song. Existing
    /// entries (same `id`) are skipped instead of throwing, so re-running an
    /// export is harmless. Returns how many were actually appended.
    @discardableResult
    func addItems(_ newItems: [PluginMusicItem], to playlist: ImportedPlaylist) throws -> Int {
        var items = loadItems(of: playlist)
        let existing = Set(items.map(\.id))
        let additions = newItems.filter { !existing.contains($0.id) }
        guard !additions.isEmpty else { return 0 }
        items.append(contentsOf: additions)
        try writeItems(items, fileName: playlist.fileName)
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return 0 }
        playlists[index].itemCount = items.count
        persist()
        return additions.count
    }

    private func writeItems(_ items: [PluginMusicItem], fileName: String) throws {
        // Store the FULL original item (bvid/cid/qualities live in rawJSON) —
        // a reduced dict loses the fields playback resolution needs.
        let payload: [[String: Any]] = items.map { item in
            if let data = item.rawJSON.data(using: .utf8),
               let full = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                return full
            }
            return [
                "id": item.itemID,
                "platform": item.platform,
                "title": item.title,
                "artist": item.artist,
                "album": item.album,
                "duration": Double(item.durationMS) / 1000,
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else {
            throw WebDAVError.malformedResponse
        }
        try data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
    }

    /// Loads the stored items of an imported playlist.
    func loadItems(of playlist: ImportedPlaylist) -> [PluginMusicItem] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(playlist.fileName)),
              let rawItems = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return []
        }
        return rawItems.compactMap { PluginMusicItem(normalizing: $0, platform: "") }
    }

    func remove(_ playlist: ImportedPlaylist) {
        playlists.removeAll { $0.id == playlist.id }
        persist()
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(playlist.fileName))
    }
}
