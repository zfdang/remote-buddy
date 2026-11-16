import SwiftUI

/// What a phrase key shows. Brand keys use plain text, never vendor logos.
enum CommonPhraseKeyGlyph: Equatable {
    case text(String)
    case symbol(String)
    case input

    static func glyph(for button: RemoteButton) -> CommonPhraseKeyGlyph {
        switch button {
        case .ok: .text("OK")
        case .youtube: .text("YouTube")
        case .netflix: .text("NETFLIX")
        case .up: .symbol("chevron.up")
        case .down: .symbol("chevron.down")
        case .left: .symbol("chevron.left")
        case .right: .symbol("chevron.right")
        case .home: .symbol("house")
        case .mute: .symbol("speaker.slash")
        case .menu: .symbol("line.3.horizontal")
        case .tv: .symbol("tv")
        case .volumeUp: .symbol("speaker.plus")
        case .volumeDown: .symbol("speaker.minus")
        case .power: .symbol("power")
        case .input: .input
        default: .symbol("circle")
        }
    }
}

struct CommonPhraseKeyGlyphView: View {
    let button: RemoteButton
    var symbolSize: CGFloat
    var textSize: CGFloat

    var body: some View {
        switch CommonPhraseKeyGlyph.glyph(for: button) {
        case let .text(value):
            Text(value).font(.system(size: textSize, weight: .bold))
                .lineLimit(1).minimumScaleFactor(0.5)
        case let .symbol(name):
            Image(systemName: name).symbolVariant(.fill)
                .font(.system(size: symbolSize, weight: .semibold))
        case .input:
            RemoteInputGlyph(size: symbolSize * 1.15)
        }
    }
}

/// Device-specific extra phrase keys below the directional pad, laid out in
/// physical rows where `nil` keeps an empty slot for alignment.
struct CommonPhraseKeyGrid: View {
    @ObservedObject var store: CommonPhraseStore
    var rows: [[RemoteButton?]]
    var keyDiameter: CGFloat
    var selectedButton: RemoteButton? = nil
    var onSelect: (RemoteButton) -> Void
    @EnvironmentObject private var localization: LocalizationStore

    var body: some View {
        Grid(alignment: .top, horizontalSpacing: 12, verticalSpacing: 12) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, button in
                        if let button {
                            key(button)
                        } else {
                            Color.clear
                                .frame(height: 1)
                                .frame(minWidth: keyDiameter * 1.6, maxWidth: .infinity)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
        }
    }

    private func key(_ button: RemoteButton) -> some View {
        let selected = selectedButton == button
        return Button { onSelect(button) } label: {
            VStack(spacing: 5) {
                CommonPhraseKeyGlyphView(button: button, symbolSize: keyDiameter * 0.38,
                                         textSize: keyDiameter * 0.27)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .frame(width: keyDiameter, height: keyDiameter)
                    .background(
                        LinearGradient(colors: [Color(white: 0.19), Color(white: 0.085)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: Circle()
                    )
                    .overlay(Circle().stroke(selected ? Color.accentColor : Color.white.opacity(0.22),
                                             lineWidth: selected ? 2 : 1))
                Text(store.phrase(for: button)?.label ?? localization.text("common_phrases.unassigned"))
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
                    .lineLimit(2).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minWidth: keyDiameter * 1.6, maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(localization.text("common_phrases.key.\(button.rawValue)"))
        .accessibilityValue(store.phrase(for: button)?.label ?? localization.text("common_phrases.unassigned"))
        .accessibilityIdentifier("common-phrases-position-\(button.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
