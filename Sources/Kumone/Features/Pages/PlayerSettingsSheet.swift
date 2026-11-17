import SwiftUI

/// Player customisation sheet (progress styles, ambience, DJ pulse, audio mix,
/// cover shape and lyrics sizing) — ported from Beans-Music's PlayerSettingsSheet.
struct PlayerSettingsSheet: View {
    @EnvironmentObject private var settings: SettingsManager

    private static let progressStyles: [(name: String, icon: String)] = [
        ("流光", "sparkles"),
        ("辉光", "sun.max"),
        ("极光", "wind"),
        ("波浪", "water.waves"),
    ]

    var body: some View {
        Form {
            playCard
            lyricsCard
            lyricEffectsCard
            coverCard
        }
        .navigationTitle("播放器设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 播放

    @ViewBuilder
    private var playCard: some View {
        Section("播放") {
            VStack(alignment: .leading, spacing: 10) {
                Text("进度条样式")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    ForEach(Array(Self.progressStyles.enumerated()), id: \.offset) { index, style in
                        Button {
                            settings.progressBarStyle = index
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: style.icon)
                                    .font(.system(size: 18))
                                Text(style.name)
                                    .font(.caption2)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(settings.progressBarStyle == index ? Theme.accent.opacity(0.16) : Color.secondary.opacity(0.06))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(settings.progressBarStyle == index ? Theme.accent : .clear, lineWidth: 1.2)
                            )
                            .foregroundStyle(settings.progressBarStyle == index ? Theme.accent : Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("背景光晕强度")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $settings.playerBreath, in: 0...1) {
                    Text("背景光晕强度")
                }
                Text(settings.playerBreath < 0.01 ? "关闭" : "\(Int(settings.playerBreath * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            Toggle("DJ 节奏脉冲灯效", isOn: $settings.djVisual)
            if settings.djVisual {
                VStack(alignment: .leading, spacing: 6) {
                    Slider(value: $settings.djIntensity, in: 0...1)
                    Text("强度 \(Int(settings.djIntensity * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            Toggle("与其他音频同时播放", isOn: $settings.mixWithOthers)
            Text("打开后听歌的同时可以播放其他 App 的声音")
                .font(.caption)
                .foregroundStyle(.secondary)

            ColorPicker("进度条颜色（清空恢复主题色）", selection: progressColorBinding)
        }
    }

    private var progressColorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: settings.progressAccentHex) ?? Theme.accent },
            set: { settings.progressAccentHex = $0.hexString() }
        )
    }

    // MARK: - 歌词显示

    @ViewBuilder
    private var lyricsCard: some View {
        Section("歌词显示") {
            VStack(alignment: .leading, spacing: 6) {
                Text("字号 \(Int(settings.lyricFontSize))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $settings.lyricFontSize, in: 12...28, step: 1)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("行距 \(Int(settings.lyricSpacing))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $settings.lyricSpacing, in: 14...40, step: 1)
            }
            Toggle("显示歌词翻译", isOn: $settings.showLyricsTranslation)
            Toggle("逐字歌词（卡拉OK）", isOn: $settings.verbatimLyrics)
        }
    }

    // MARK: - 歌词特效（Beans 同款烈度）

    @ViewBuilder
    private var lyricEffectsCard: some View {
        Section("歌词特效") {
            VStack(alignment: .leading, spacing: 6) {
                Text("非当前行模糊 \(Int(settings.lyricBlurAmount))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $settings.lyricBlurAmount, in: 0...10, step: 0.5)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("左右 3D 倾斜 \(Int(settings.lyricTiltX))°")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $settings.lyricTiltX, in: -30...30, step: 1)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("上下 3D 倾斜 \(Int(settings.lyricTiltY))°")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $settings.lyricTiltY, in: -20...20, step: 1)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("当前行发光 \(Int(settings.lyricGlow))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $settings.lyricGlow, in: 0...5, step: 0.5)
            }
        }
    }

    // MARK: - 封面

    @ViewBuilder
    private var coverCard: some View {
        Section("封面") {
            Toggle("圆形封面", isOn: $settings.circularCover)
            if settings.circularCover {
                Toggle("封面旋转（黑胶）", isOn: $settings.circularCoverSpin)
            }
            Text("播放页封面显示为圆形，可开启随播放旋转")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Color helpers

extension Color {
    /// Parses "RRGGBB" (optionally "#RRGGBB").
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }

    func hexString() -> String {
        #if canImport(UIKit)
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
        #else
        return ""
        #endif
    }
}
