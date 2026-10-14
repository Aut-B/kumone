import SwiftUI

struct PlaybackHandoffList: View {
    @ObservedObject private var sync = SyncService.shared
    @ObservedObject private var account = AccountStore.shared

    private var availableSessions: [SyncRecord<PlaybackSession>] {
        guard let accountID = account.authenticatedAccountID else { return [] }
        return sync.sessions.filter { $0.payload?.accountID == accountID }
    }

    var body: some View {
        if !availableSessions.isEmpty {
            VStack(spacing: 6) {
                ForEach(availableSessions) { record in
                    if let session = record.payload {
                        HStack(spacing: 10) {
                            Image(systemName: record.deviceSymbolName)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 28, height: 28)
                                .background(Theme.accent.opacity(0.12), in: Circle())

                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.deviceName)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .lineLimit(1)
                                Text(session.currentTrack.name)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 8)

                            Button {
                                do { try sync.resume(record) }
                                catch { ToastCenter.shared.show(error.localizedDescription) }
                            } label: {
                                Text("接续")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(Theme.accent)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Theme.accent.opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
        }
    }
}
