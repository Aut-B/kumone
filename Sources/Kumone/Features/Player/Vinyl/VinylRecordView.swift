import SwiftUI

/// High-fidelity programmatic vector vinyl record disc.
/// Features realistic vinyl grooves, angular specular shine, and center circular artwork.
public struct VinylRecordView: View {
    public let artworkImage: PlatformImage?
    public let size: CGFloat

    public init(artworkImage: PlatformImage?, size: CGFloat = 280) {
        self.artworkImage = artworkImage
        self.size = size
    }

    public var body: some View {
        let discDiameter = size
        let labelDiameter = discDiameter * 0.65 // Classic NetEase ratio
        let spindleHoleDiameter = max(8, discDiameter * 0.035)

        return ZStack {
            // 1. Base Vinyl Disc with Depth Shadow
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.12), Color(white: 0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: discDiameter, height: discDiameter)
                .shadow(color: .black.opacity(0.55), radius: max(10, discDiameter * 0.06), x: 0, y: discDiameter * 0.035)

            // 2. Vinyl Matte Texture with Outer Rim
            Circle()
                .fill(
                    AngularGradient(
                        gradient: Gradient(colors: [
                            Color(white: 0.08),
                            Color(white: 0.22),
                            Color(white: 0.06),
                            Color(white: 0.18),
                            Color(white: 0.07),
                            Color(white: 0.22),
                            Color(white: 0.08)
                        ]),
                        center: .center
                    )
                )
                .frame(width: discDiameter - 4, height: discDiameter - 4)

            // 3. Realistic Concentric Audio Grooves
            ForEach([0.72, 0.76, 0.80, 0.84, 0.88, 0.92, 0.96], id: \.self) { scale in
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.12), .white.opacity(0.03)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: max(0.6, discDiameter * 0.0025)
                    )
                    .frame(width: discDiameter * scale, height: discDiameter * scale)
            }

            // 4. Specular Sheen (Screen Blend)
            Circle()
                .fill(
                    AngularGradient(
                        gradient: Gradient(colors: [
                            .clear,
                            Color.white.opacity(0.14),
                            .clear,
                            Color.white.opacity(0.06),
                            .clear,
                            Color.white.opacity(0.14),
                            .clear
                        ]),
                        center: .center,
                        angle: .degrees(45)
                    )
                )
                .frame(width: discDiameter - 4, height: discDiameter - 4)
                .blendMode(.screen)
                .allowsHitTesting(false)

            // 5. Center Label Rim & Artwork
            ZStack {
                // Outer label bevel ring
                Circle()
                    .fill(Color(white: 0.08))
                    .frame(width: labelDiameter + 4, height: labelDiameter + 4)

                // Album Artwork
                Group {
                    if let artworkImage {
                        Image(platformImage: artworkImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            LinearGradient(
                                colors: [Color(white: 0.2), Color(white: 0.1)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            Image(systemName: "music.note")
                                .font(.system(size: labelDiameter * 0.35, weight: .light))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                }
                .frame(width: labelDiameter, height: labelDiameter)
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .stroke(Color.black.opacity(0.4), lineWidth: max(1, discDiameter * 0.004))
                }

                // Inner label groove ring
                Circle()
                    .stroke(Color.white.opacity(0.15), lineWidth: 0.8)
                    .frame(width: labelDiameter * 0.85, height: labelDiameter * 0.85)

                // 6. Center Spindle Bevel & Hole
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 0.85), Color(white: 0.35)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: spindleHoleDiameter * 2.2, height: spindleHoleDiameter * 2.2)
                    .shadow(color: .black.opacity(0.4), radius: 1, y: 1)

                Circle()
                    .fill(Color.black)
                    .frame(width: spindleHoleDiameter, height: spindleHoleDiameter)
            }
        }
        .frame(width: discDiameter, height: discDiameter)
    }
}
