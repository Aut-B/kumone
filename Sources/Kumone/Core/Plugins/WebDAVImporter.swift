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

    var errorDescription: String? {
        switch self {
        case .badServer: return String(localized: "WebDAV 地址无效")
        case .unauthorized: return String(localized: "WebDAV 账号或密码错误")
        case .malformedResponse: return String(localized: "WebDAV 响应解析失败")
        case .downloadFailed(let code): return String(localized: "下载失败（HTTP \(code)）")
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
    /// Lists entries under `path` (server-relative, "" = root).
    static func list(server: String, username: String, password: String, path: String) async throws -> [WebDAVEntry] {
        guard URL(string: server)?.scheme != nil else {
            throw WebDAVError.badServer
        }
        var urlString = server
        if !path.isEmpty {
            if !urlString.hasSuffix("/") { urlString += "/" }
            urlString += path
            if !urlString.hasSuffix("/") { urlString += "/" }
        }
        guard let url = URL(string: urlString) else { throw WebDAVError.badServer }

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
        guard http.statusCode == 207 else { throw WebDAVError.downloadFailed(http.statusCode) }
        guard let xml = String(data: data, encoding: .utf8) else { throw WebDAVError.malformedResponse }

        var entries: [WebDAVEntry] = []
        let parser = WebDAVListParser()
        parser.parse(xml) { entry in
            // Drop the collection's own href (same as the requested URL).
            if entry.urlString == urlString { return }
            entries.append(entry)
        }
        return entries.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// Downloads a file over WebDAV.
    static func download(urlString: String, username: String, password: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw WebDAVError.badServer }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Basic \(Data("\(username):\(password)".utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw WebDAVError.downloadFailed((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return data
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
        let payload: [[String: Any]] = items.map {
            var dict: [String: Any] = [
                "id": $0.itemID,
                "platform": $0.platform,
                "title": $0.title,
                "artist": $0.artist,
                "album": $0.album,
                "duration": Double($0.durationMS) / 1000,
            ]
            if let artwork = $0.artwork { dict["artwork"] = artwork }
            return dict
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else {
            throw WebDAVError.malformedResponse
        }
        try data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
        playlists.removeAll { $0.name == name }
        playlists.insert(ImportedPlaylist(name: name, fileName: fileName, itemCount: items.count, source: source), at: 0)
        persist()
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
