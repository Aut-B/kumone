import SwiftUI

struct SyncedLoginButtons: View {
    @ObservedObject private var sync = SyncService.shared
    @ObservedObject private var account = AccountStore.shared
    var onStart: () -> Void = {}
    var onFinished: (Bool) -> Void = { _ in }

    var body: some View {
        if sync.enabled, sync.connected, account.isBootstrapped, account.authenticatedAccountID == nil {
            ForEach(sync.logins) { record in
                if let login = record.payload {
                    Button {
                        onStart()
                        Task {
                            do {
                                let signedIn = try await sync.importLogin(record)
                                onFinished(signedIn)
                                if let error = sync.errorMessage { ToastCenter.shared.show(error) }
                            } catch is CancellationError {
                                onFinished(false)
                            } catch {
                                onFinished(false)
                                ToastCenter.shared.show(error.localizedDescription)
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "icloud")
                            Text("以\(login.nickname)登录").lineLimit(1)
                            if sync.importingLogin { ProgressView().controlSize(.small) }
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(sync.importingLogin)
                }
            }
            if !sync.logins.isEmpty {
                Text("在已连接的设备间同步登录状态")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
