import SwiftUI
import UniformTypeIdentifiers

struct SyncSettingsSection: View {
    @ObservedObject private var sync = SyncService.shared
    @State private var showDirectoryPicker = false

    var body: some View {
        Section("iCloud") {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("同步", isOn: Binding(
                    get: { sync.enabled },
                    set: { enabled in
                        Task {
                            if enabled {
                                do { showDirectoryPicker = try await !sync.enable() }
                                catch is CancellationError { return }
                                catch { ToastCenter.shared.show(error.localizedDescription) }
                            } else { await sync.disable() }
                        }
                    }
                ))
                Text("在设备间接续播放，同步设置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if sync.enabled {
                Toggle("登录同步", isOn: Binding(
                    get: { sync.loginEnabled },
                    set: { enabled in Task { await sync.setLoginEnabled(enabled) } }
                ))

                Text("允许已连接的设备登录此账号，仅连接你信任的同步位置")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !sync.connected {
                    Button("重新连接") { showDirectoryPicker = true }
                        #if os(macOS)
                        .controlSize(.small)
                        #endif
                }
            }
            if let error = sync.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .fileImporter(isPresented: $showDirectoryPicker, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let directory): Task { await sync.connect(to: directory) }
            case .failure(let error): ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }
}
