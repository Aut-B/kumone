#if os(iOS)
import SwiftUI

/// 短视频收藏的 WebDAV 同步配置。
///
/// 远端只有一个文件（`<服务器>/ShortVideo/shortvideo.json`），抖音和 TikTok 都在
/// 里面，Kumone 与 PiliPlus 也共用同一份格式——一台手机抓到的收藏，另一台
/// 打开就能看到。
struct ShortVideoSyncConfig: Codable, Equatable {
    var server: String = ""
    var username: String = ""
    var password: String = ""
    /// 只有填了才会在服务器上多一层目录，留空就是根目录。
    var directory: String = ""

    var isValid: Bool {
        !server.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.isEmpty
            && !password.isEmpty
    }

    private static let storageKey = "shortVideoWebdavConfig"

    static func load() -> ShortVideoSyncConfig {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let config = try? JSONDecoder().decode(ShortVideoSyncConfig.self, from: data) else {
            return ShortVideoSyncConfig()
        }
        return config
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    /// `<server>/[directory/]ShortVideo/shortvideo.json`
    var remoteFileURL: String {
        var base = server.trimmingCharacters(in: .whitespaces)
        if !base.hasSuffix("/") { base += "/" }
        let trimmed = directory.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        if !trimmed.isEmpty { base += trimmed + "/" }
        return base + "ShortVideo/shortvideo.json"
    }
}

enum ShortVideoSyncService {
    /// 下载远端文档；远端还没有文件时返回空文档（不是错误）。
    static func fetchRemote(_ config: ShortVideoSyncConfig) async throws -> ShortVideoSyncDocument {
        do {
            let data = try await WebDAVClient.download(
                urlString: config.remoteFileURL,
                username: config.username,
                password: config.password
            )
            if let doc = try? JSONDecoder().decode(ShortVideoSyncDocument.self, from: data) {
                return doc
            }
            // 兼容手写的 { "items": [...] }
            if let raw = try? JSONSerialization.jsonObject(with: data),
               let object = raw as? [String: Any],
               let items = object["items"],
               let itemsData = try? JSONSerialization.data(withJSONObject: items),
               let list = try? JSONDecoder().decode([ShortVideo].self, from: itemsData) {
                return ShortVideoSyncDocument(items: list)
            }
            return ShortVideoSyncDocument()
        } catch WebDAVError.downloadFailed(let code) where code == 404 {
            return ShortVideoSyncDocument()
        } catch WebDAVError.downloadFailed(let code) where code == 401 || code == 403 {
            throw WebDAVError.unauthorized
        }
    }

    static func upload(_ document: ShortVideoSyncDocument, config: ShortVideoSyncConfig) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try await WebDAVClient.upload(
            data: data,
            urlString: config.remoteFileURL,
            username: config.username,
            password: config.password
        )
    }

    /// 本地 + 远端取并集，写回本地两个平台，再把合并结果推上去。
    /// 返回合并后的总条数。
    @discardableResult
    static func synchronize(_ config: ShortVideoSyncConfig) async throws -> Int {
        let remote = try await fetchRemote(config)
        let local = ShortVideoPlatform.allCases.flatMap { ShortVideoStore.load($0) }
        let merged = ShortVideoMerge.merge(local, remote.items)

        for platform in ShortVideoPlatform.allCases {
            let subset = merged.filter { $0.platform == platform.rawValue }
            ShortVideoStore.save(subset, for: platform)
        }

        var document = remote
        document.items = merged
        document.updatedAt = Date().timeIntervalSince1970
        try await upload(document, config: config)
        return merged.count
    }
}

/// 设置页：服务器 / 账号 / 应用密码 / 可选子目录。
struct ShortVideoSyncSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var config = ShortVideoSyncConfig.load()
    @State private var message: String?
    @State private var isBusy = false

    var body: some View {
        AppNavStack {
            Form {
                Section {
                    TextField("服务器地址，例如 https://dav.jianguoyun.com/dav/", text: $config.server)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("账号", text: $config.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("应用密码", text: $config.password)
                    TextField("子目录（可留空）", text: $config.directory)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("WebDAV")
                } footer: {
                    Text("坚果云要填「应用密码」，不是登录密码。远端文件：\(config.remoteFileURL)")
                        .font(.caption)
                }

                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        Label("测试连接", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .disabled(!config.isValid || isBusy)

                    Button {
                        Task { await syncNow() }
                    } label: {
                        Label("立即同步", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(!config.isValid || isBusy)
                } footer: {
                    if let message {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("收藏同步")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        config.save()
                        ToastCenter.shared.show("WebDAV 设置已保存")
                        dismiss()
                    }
                }
            }
        }
    }

    private func test() async {
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await WebDAVClient.listRoot(
                server: config.server,
                username: config.username,
                password: config.password
            )
            message = "连接正常"
        } catch {
            message = error.localizedDescription
        }
    }

    private func syncNow() async {
        isBusy = true
        defer { isBusy = false }
        do {
            config.save()
            let count = try await ShortVideoSyncService.synchronize(config)
            message = "同步完成，共 \(count) 条"
            NotificationCenter.default.post(name: .shortVideoDidSync, object: nil)
        } catch {
            message = error.localizedDescription
        }
    }
}

extension Notification.Name {
    static let shortVideoDidSync = Notification.Name("shortVideoDidSync")
}
#endif