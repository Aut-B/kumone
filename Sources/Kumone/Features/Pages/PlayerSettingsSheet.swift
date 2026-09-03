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
        }
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
