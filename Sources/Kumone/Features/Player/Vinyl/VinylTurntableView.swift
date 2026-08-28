import SwiftUI

/// Complete interactive turntable stage combining rotating vinyl disc, tonearm,
/// continuous timeline rotation, tap-to-flip, and horizontal swipe-to-switch tracks.
public struct VinylTurntableView: View {
    public let artworkImage: PlatformImage?
    public let isPlaying: Bool
    public let trackId: Int?
    public let size: CGFloat
    public var onTap: (() -> Void)? = nil
    public var onNextTrack: (() -> Void)? = nil
    public var onPreviousTrack: (() -> Void)? = nil

    @State private var rotationState = RecordRotationState()
    @State private var dragOffset: CGFloat = 0
    @State private var isTransitioningTrack = false

    public init(
        artworkImage: PlatformImage?,
        isPlaying: Bool,
        trackId: Int? = nil,
        size: CGFloat = 280,
        onTap: (() -> Void)? = nil,
        onNextTrack: (() -> Void)? = nil,
        onPreviousTrack: (() -> Void)? = nil
    ) {
        self.artworkImage = artworkImage
        self.isPlaying = isPlaying
        self.trackId = trackId
        self.size = size
        self.onTap = onTap
        self.onNextTrack = onNextTrack
        self.onPreviousTrack = onPreviousTrack
    }

    public var body: some View {
        let discSize = size
        let armHeight = discSize * 0.62
        let stageWidth = discSize + 40
        let stageHeight = discSize + armHeight * 0.45

        return ZStack(alignment: .top) {
            // MARK: 1. Rotating Vinyl Disc (with horizontal drag & transition)
            TimelineView(.animation(paused: !isPlaying)) { timeline in
                let currentAngle = rotationState.currentAngle(at: timeline.date)

                VinylRecordView(artworkImage: artworkImage, size: discSize)
                    .rotationEffect(.degrees(currentAngle))
            }
            .offset(x: dragOffset)
            .padding(.top, armHeight * 0.35)
            .contentShape(Circle())
            .gesture(dragAndSwipeGesture(discSize: discSize))
            .onTapGesture {
                onTap?()
            }
            .zIndex(1)

            // MARK: 2. Tonearm (Placed above and to the right of the disc)
            VinylTonearmView(isPlaying: isPlaying && !isTransitioningTrack, height: armHeight)
                .offset(x: discSize * 0.22, y: 0)
                .allowsHitTesting(false)
                .zIndex(2)
        }
        .frame(width: stageWidth, height: stageHeight, alignment: .top)
        .onAppear {
            if isPlaying {
                rotationState.start(at: Date())
            }
        }
        .onChange(of: isPlaying) { playing in
            if playing {
                rotationState.start(at: Date())
            } else {
                rotationState.stop(at: Date())
            }
        }
        .onChange(of: trackId) { _ in
            // Temporary lift tonearm on track change
            isTransitioningTrack = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                isTransitioningTrack = false
            }
        }
    }

    // MARK: - Gestures

    private func dragAndSwipeGesture(discSize: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                // Only track primarily horizontal drags
                if abs(value.translation.width) > abs(value.translation.height) {
                    let translation = value.translation.width
                    // Apply resistance damping as user drags further
                    dragOffset = translation * 0.75
                }
            }
            .onEnded { value in
                let translation = value.translation.width
                let velocity = value.predictedEndTranslation.width
                let swipeThreshold: CGFloat = 55

                if translation < -swipeThreshold || velocity < -120 {
                    // Swipe Left -> Next Track
                    withAnimation(.easeOut(duration: 0.22)) {
                        dragOffset = -discSize * 1.1
                    }
                    onNextTrack?()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                        dragOffset = discSize * 1.1
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
                            dragOffset = 0
                        }
                    }
                } else if translation > swipeThreshold || velocity > 120 {
                    // Swipe Right -> Previous Track
                    withAnimation(.easeOut(duration: 0.22)) {
                        dragOffset = discSize * 1.1
                    }
                    onPreviousTrack?()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                        dragOffset = -discSize * 1.1
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
                            dragOffset = 0
                        }
                    }
                } else {
                    // Reset back to center
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        dragOffset = 0
                    }
                }
            }
    }
}
