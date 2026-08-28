import SwiftUI

/// Vector mechanical tonearm (唱臂与唱针) matching vintage / NetEase turntable styling.
/// Features metallic pivot base, curved tonearm tube, headshell, cartridge, stylus tip,
/// and smooth engaging/disengaging rotation animation.
public struct VinylTonearmView: View {
    public let isPlaying: Bool
    public let height: CGFloat
    public let reduceMotion: Bool

    public init(isPlaying: Bool, height: CGFloat = 170, reduceMotion: Bool = false) {
        self.isPlaying = isPlaying
        self.height = height
        self.reduceMotion = reduceMotion
    }

    public var body: some View {
        // Base width proportional to height
        let width = height * 0.55
        let pivotSize = width * 0.44

        ZStack(alignment: .top) {
            // 1. Static Pivot Base (固定底座)
            pivotBase(size: pivotSize)
                .zIndex(2)

            // 2. Rotating Arm Assembly (可旋转的臂杆总成)
            TimelineView(.animation(paused: !isPlaying || reduceMotion)) { timeline in
                let wobble = wobbleDegrees(at: timeline.date)
                armAssembly(width: width, height: height)
                    .rotationEffect(
                        .degrees(rotationAngle + wobble),
                        anchor: UnitPoint(x: 0.5, y: pivotSize * 0.5 / height)
                    )
            }
            .animation(
                reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.76, blendDuration: 0.1),
                value: isPlaying
            )
            .zIndex(1)
        }
        .frame(width: width, height: height, alignment: .top)
    }

    private var rotationAngle: Double {
        // Playing: resting onto outer track (0°); Paused: lifted and parked away (-30°)
        isPlaying ? 0.0 : -30.0
    }

    private func wobbleDegrees(at date: Date) -> Double {
        guard isPlaying, !reduceMotion else { return 0 }
        let seconds = date.timeIntervalSinceReferenceDate
        let harmonic1 = sin(seconds * 2.0 * .pi / 3.2) * 0.22
        let harmonic2 = sin(seconds * 2.0 * .pi / 1.1 + 0.6) * 0.08
        return harmonic1 + harmonic2
    }

    // MARK: - Pivot Base View

    private func pivotBase(size: CGFloat) -> some View {
        ZStack {
            // Outer drop shadow
            Circle()
                .fill(Color.black.opacity(0.45))
                .frame(width: size * 1.08, height: size * 1.08)
                .blur(radius: 2)
                .offset(y: 2)

            // Outer metallic rim
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.75), Color(white: 0.3)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(0.4), lineWidth: 0.8)
                }

            // Dark inner disc
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(white: 0.28), Color(white: 0.12)],
                        center: .center,
                        startRadius: 0,
                        endRadius: size * 0.4
                    )
                )
                .frame(width: size * 0.78, height: size * 0.78)

            // Inner pivot chrome cap
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.9), Color(white: 0.45)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size * 0.38, height: size * 0.38)
                .shadow(color: .black.opacity(0.4), radius: 1, y: 1)

            // Center bearing screw
            Circle()
                .fill(Color(white: 0.15))
                .frame(width: size * 0.14, height: size * 0.14)
        }
        .frame(width: size, height: size)
    }

    // MARK: - Rotating Arm Assembly

    private func armAssembly(width: CGFloat, height: CGFloat) -> some View {
        let pivotY = (width * 0.44) * 0.5
        let tubeWidth: CGFloat = max(3.5, width * 0.055)

        return ZStack(alignment: .top) {
            // Shadow behind the entire arm
            TonearmPath()
                .stroke(Color.black.opacity(0.35), lineWidth: tubeWidth * 1.4)
                .blur(radius: 2)
                .offset(x: 2, y: 3)

            // Curved Metallic Tonearm Tube
            TonearmPath()
                .stroke(
                    LinearGradient(
                        colors: [
                            Color(white: 0.95),
                            Color(white: 0.6),
                            Color(white: 0.85),
                            Color(white: 0.45)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: tubeWidth, lineCap: .round, lineJoin: .round)
                )

            // Headshell & Cartridge at the bottom-left of the arm curve
            headshellAndCartridge(width: width, height: height)
        }
        .frame(width: width, height: height)
        .offset(y: pivotY)
    }

    private func headshellAndCartridge(width: CGFloat, height: CGFloat) -> some View {
        let headWidth = width * 0.22
        let headHeight = height * 0.2

        return ZStack {
            // Headshell plate (angular cover)
            RoundedRectangle(cornerRadius: 2)
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.3), Color(white: 0.12)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: headWidth, height: headHeight)
                .overlay {
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color.white.opacity(0.3), lineWidth: 0.8)
                }

            // Perforations on headshell
            HStack(spacing: 3) {
                ForEach(0..<2, id: \.self) { _ in
                    Capsule()
                        .fill(Color.black.opacity(0.8))
                        .frame(width: 2.5, height: headHeight * 0.4)
                }
            }

            // Cartridge / Stylus tip (red indicator)
            VStack {
                Spacer()
                RoundedRectangle(cornerRadius: 1)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.88, green: 0.2, blue: 0.2), Color(red: 0.5, green: 0.05, blue: 0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: headWidth * 0.55, height: 4)
                    .offset(y: 2)
            }
        }
        .frame(width: headWidth, height: headHeight)
        .rotationEffect(.degrees(22))
        .position(x: width * 0.32, y: height * 0.72)
    }
}

// MARK: - Tonearm S-Curve Path

private struct TonearmPath: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let startPoint = CGPoint(x: rect.width * 0.5, y: 0)
        let midPoint1 = CGPoint(x: rect.width * 0.58, y: rect.height * 0.28)
        let midPoint2 = CGPoint(x: rect.width * 0.42, y: rect.height * 0.55)
        let endPoint = CGPoint(x: rect.width * 0.32, y: rect.height * 0.72)

        path.move(to: startPoint)
        path.addCurve(
            to: midPoint1,
            control1: CGPoint(x: rect.width * 0.52, y: rect.height * 0.1),
            control2: CGPoint(x: rect.width * 0.58, y: rect.height * 0.2)
        )
        path.addCurve(
            to: midPoint2,
            control1: CGPoint(x: rect.width * 0.58, y: rect.height * 0.38),
            control2: CGPoint(x: rect.width * 0.45, y: rect.height * 0.48)
        )
        path.addCurve(
            to: endPoint,
            control1: CGPoint(x: rect.width * 0.38, y: rect.height * 0.62),
            control2: CGPoint(x: rect.width * 0.34, y: rect.height * 0.68)
        )
        return path
    }
}
