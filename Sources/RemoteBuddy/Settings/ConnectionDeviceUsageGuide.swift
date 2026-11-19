import SwiftUI

struct ConnectionDeviceUsageItem: Equatable, Identifiable {
    let symbol: String
    let tint: Color
    let titleKey: String
    let detailKey: String

    var id: String { titleKey }
}

/// Concise, user-facing hardware and voice usage notes rendered in each
/// device's Connection detail panel.
struct ConnectionDeviceUsageGuide: Equatable {
    let badgeKey: String?
    let badgeSymbol: String?
    let badgeTint: Color
    let items: [ConnectionDeviceUsageItem]

    static func make(for profile: RemoteDeviceProfile) -> Self? {
        switch profile.model {
        case .rc001, .rc003:
            return xiaomiGuide()
        case .t1Remote:
            return t1Guide()
        case .chromecastVoiceRemote:
            return chromecastGuide(voiceMode: profile.effectiveG9N9NVoiceButtonMode)
        case .appleSiriRemoteA2540, .appleSiriRemoteA2854, .unknown:
            return nil
        }
    }

    private static func xiaomiGuide() -> Self {
        Self(
            badgeKey: "connection.device_guide.badge.xiaomi_hold_only",
            badgeSymbol: "hand.point.up.left.fill",
            badgeTint: .blue,
            items: [
                ConnectionDeviceUsageItem(
                    symbol: "mic.fill",
                    tint: .blue,
                    titleKey: "connection.device_guide.xiaomi.voice.title",
                    detailKey: "connection.device_guide.xiaomi.voice.detail"
                ),
                ConnectionDeviceUsageItem(
                    symbol: "timer",
                    tint: .orange,
                    titleKey: "connection.device_guide.xiaomi.limit.title",
                    detailKey: "connection.device_guide.xiaomi.limit.detail"
                ),
            ]
        )
    }

    private static func t1Guide() -> Self {
        Self(
            badgeKey: "connection.device_guide.badge.t1_toggle",
            badgeSymbol: "waveform",
            badgeTint: .indigo,
            items: [
                ConnectionDeviceUsageItem(
                    symbol: "waveform",
                    tint: .indigo,
                    titleKey: "connection.device_guide.t1.voice.title",
                    detailKey: "connection.device_guide.t1.voice.detail"
                ),
                ConnectionDeviceUsageItem(
                    symbol: "sparkles",
                    tint: .blue,
                    titleKey: "connection.device_guide.t1.hold_compat.title",
                    detailKey: "connection.device_guide.t1.hold_compat.detail"
                ),
            ]
        )
    }

    private static func chromecastGuide(voiceMode: G9N9NVoiceButtonMode) -> Self {
        var items = [
            ConnectionDeviceUsageItem(
                symbol: "record.circle.fill",
                tint: .blue,
                titleKey: "connection.device_guide.g9n9n.led.title",
                detailKey: "connection.device_guide.g9n9n.led.detail"
            ),
            ConnectionDeviceUsageItem(
                symbol: "timer",
                tint: .green,
                titleKey: "connection.device_guide.g9n9n.limit.title",
                detailKey: "connection.device_guide.g9n9n.limit.detail"
            ),
        ]
        if voiceMode == .smartToggle {
            items.append(
                ConnectionDeviceUsageItem(
                    symbol: "hand.raised.fill",
                    tint: .orange,
                    titleKey: "connection.device_guide.g9n9n.other_key_stops.title",
                    detailKey: "connection.device_guide.g9n9n.other_key_stops.detail"
                )
            )
        }
        return Self(
            badgeKey: nil,
            badgeSymbol: nil,
            badgeTint: .blue,
            items: items
        )
    }
}

struct G9N9NVoiceButtonModeSelector: View {
    let selection: G9N9NVoiceButtonMode
    let isDisabled: Bool
    let onSelect: (G9N9NVoiceButtonMode) -> Void

    @EnvironmentObject private var localization: LocalizationStore
    @State private var hoveredMode: G9N9NVoiceButtonMode?

    private struct Option {
        let mode: G9N9NVoiceButtonMode
        let titleKey: String
        let symbol: String
        let tint: Color
    }

    private let options: [Option] = [
        Option(
            mode: .smartToggle,
            titleKey: "connection.g9n9n.voice_button_mode.smart_toggle",
            symbol: "hand.tap.fill",
            tint: .blue
        ),
        Option(
            mode: .holdToTalk,
            titleKey: "connection.g9n9n.voice_button_mode.hold",
            symbol: "hand.point.up.left.fill",
            tint: .indigo
        ),
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.mode) { option in
                let isSelected = selection == option.mode
                let isHovered = hoveredMode == option.mode
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        onSelect(option.mode)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: option.symbol)
                            .font(.system(size: 11, weight: .semibold))
                        Text(localization.text(option.titleKey))
                            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(isSelected ? Color.white : (isHovered ? option.tint : Color.primary.opacity(0.84)))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(minWidth: 108)
                    .background {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(
                                isSelected
                                    ? option.tint
                                    : (isHovered ? option.tint.opacity(0.14) : option.tint.opacity(0.06))
                            )
                    }
                    .overlay {
                        if !isSelected {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(option.tint.opacity(isHovered ? 0.45 : 0.22), lineWidth: 1)
                        }
                    }
                    .shadow(color: isSelected ? option.tint.opacity(0.32) : .clear, radius: 4, y: 1)
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    hoveredMode = hovering ? option.mode : (hoveredMode == option.mode ? nil : hoveredMode)
                }
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
        }
        .opacity(isDisabled ? 0.55 : 1)
        .disabled(isDisabled)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("g9n9n-voice-button-mode-picker")
    }
}

struct ConnectionDeviceUsageSection: View {
    let guide: ConnectionDeviceUsageGuide
    @EnvironmentObject private var localization: LocalizationStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Text(localization.text("connection.device_guide.title"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let badgeKey = guide.badgeKey {
                    badgePill(titleKey: badgeKey, symbol: guide.badgeSymbol, tint: guide.badgeTint)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(guide.items) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(item.tint)
                            .frame(width: 14)
                        (
                            Text(localization.text(item.titleKey))
                                .fontWeight(.semibold)
                                .foregroundStyle(.primary)
                            + Text(" · ")
                                .foregroundStyle(.tertiary)
                            + Text(localization.text(item.detailKey))
                                .foregroundStyle(.secondary)
                        )
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        }
    }

    private func badgePill(titleKey: String, symbol: String?, tint: Color) -> some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(localization.text(titleKey))
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(tint.opacity(0.12), in: Capsule())
    }
}
