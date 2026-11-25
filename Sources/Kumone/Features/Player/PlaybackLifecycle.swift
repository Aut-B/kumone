#if os(iOS)
import Combine
import SwiftUI
import UIKit
#else
import SwiftUI
#endif

struct PlaybackLifecycle: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .task { await SyncService.shared.start() }
            #if os(macOS)
            .onChange(of: scenePhase) { _, phase in
                PlayerService.shared.checkpointPlayback()
                Task { await SyncService.shared.setForeground(phase == .active) }
            }
            #else
            .onChange(of: scenePhase) { phase in
                PlayerService.shared.checkpointPlayback()
                Task { await SyncService.shared.setForeground(phase == .active) }
                // The lock screen renders the card as the app leaves the
                // foreground; republish there so a slot taken since the last
                // track change cannot leave playback without a card.
                if phase == .background {
                    NowPlayingManager.shared.refreshSystemCard()
                }
            }
            // Best-effort exit hook. The player has no user-facing "stop" and
            // a paused track must keep its card so playback can resume from
            // the lock screen; termination is the one point where the card
            // would otherwise outlive the playback it describes.
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
                NowPlayingManager.shared.clear()
            }
            #endif
    }
}
