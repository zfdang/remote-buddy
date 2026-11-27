import SwiftUI

/// Semantic visual tier for floating and inline notice bubbles.
/// Tiers map to user attention required rather than internal subsystems:
/// informational tips and confirmations use `.tip` so they stay lightweight.
enum NoticeTier: String, CaseIterable {
    case tip
    case warning
    case error

    /// Higher priority prevents lower-tier notices from replacing active alerts.
    var priority: Int {
        switch self {
        case .tip: return 0
        case .warning: return 1
        case .error: return 2
        }
    }

    /// Optional VoiceOver prefix key so screen readers announce severity up front.
    var accessibilityPrefixKey: String? {
        switch self {
        case .tip: return nil
        case .warning: return "notice.accessibility.warning_prefix"
        case .error: return "notice.accessibility.error_prefix"
        }
    }
}

/// Interactive button descriptor rendered inside a `NoticeBubble`.
struct NoticeAction {
    let title: String
    let perform: @MainActor () -> Void

    init(title: String, perform: @escaping @MainActor () -> Void) {
        self.title = title
        self.perform = perform
    }
}

/// Complete color token set for a single appearance and tier.
struct NoticeBubbleColors: Equatable {
    let fill: UInt32
    let border: UInt32
    let title: UInt32
    let body: UInt32
    let close: UInt32
    let accent: UInt32
}

/// Hex palette tokens shared between notice UI and unit-level contrast checks.
enum NoticePalette {
    static let darkSurface: UInt32 = 0x1C1C1E

    static func inlineAccent(_ tier: NoticeTier, dark: Bool) -> UInt32 {
        bubble(tier, dark: dark).accent
    }

    static func inlineSurface(_ tier: NoticeTier) -> UInt32 {
        bubble(tier, dark: false).fill
    }

    static func inlineBorder(_ tier: NoticeTier) -> UInt32 {
        bubble(tier, dark: false).border
    }

    static func bubble(_ tier: NoticeTier, dark: Bool) -> NoticeBubbleColors {
        if dark {
            switch tier {
            case .tip:
                return NoticeBubbleColors(
                    fill: 0x1E2B27, border: 0x5F6F65, title: 0xE8F5EF,
                    body: 0xB9CFC5, close: 0x8FA99D, accent: 0x5FBF97
                )
            case .warning:
                return NoticeBubbleColors(
                    fill: 0x2C251A, border: 0x7A6A48, title: 0xFFF4E3,
                    body: 0xD8C4A6, close: 0xB29B79, accent: 0xD9A24E
                )
            case .error:
                return NoticeBubbleColors(
                    fill: 0x2E1F1E, border: 0x8A625A, title: 0xFFF0EE,
                    body: 0xD9B9B5, close: 0xB98E89, accent: 0xE07A70
                )
            }
        }
        switch tier {
        case .tip:
            return NoticeBubbleColors(
                fill: 0xEAF6F0, border: 0xCBE5D9, title: 0x14553F,
                body: 0x4E6A5F, close: 0x6C8A7E, accent: 0x2B7A5C
            )
        case .warning:
            return NoticeBubbleColors(
                fill: 0xFFF7E8, border: 0xF0DDBA, title: 0x6A4515,
                body: 0x7A5B2E, close: 0x8A6A3A, accent: 0xA26A1E
            )
        case .error:
            return NoticeBubbleColors(
                fill: 0xFFF1EF, border: 0xF2D2CD, title: 0x7A2C26,
                body: 0x8A4E48, close: 0xA76A63, accent: 0xB24C42
            )
        }
    }
}

/// Optional callout tail pointing toward an anchored control.
struct NoticeTail: Equatable {
    enum Edge: Equatable {
        case leading
        case trailing
        case top
        case bottom

        var isHorizontal: Bool {
            self == .leading || self == .trailing
        }
    }

    var edge: Edge

    static let leading = NoticeTail(edge: .leading)
    static let trailing = NoticeTail(edge: .trailing)
    static let top = NoticeTail(edge: .top)
    static let bottom = NoticeTail(edge: .bottom)
}

/// Floating pill/card view shared across reminder and feedback panels.
struct NoticeBubble: View {
    let tier: NoticeTier
    let title: String
    var text: String?
    var context: String? = nil
    var action: NoticeAction?
    var secondaryAction: NoticeAction? = nil
    var tail: NoticeTail?
    var onClose: (() -> Void)?
    var accessibilityPrefix: String?
    var closeAccessibilityLabel: String? = nil

    @Environment(\.colorScheme) private var colorScheme

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
    }

    private var isDark: Bool { colorScheme == .dark }

    private var palette: NoticeBubbleColors {
        NoticePalette.bubble(tier, dark: isDark)
    }

    private var surface: Color { Color(hex: palette.fill) }
    private var border: Color { Color(hex: palette.border) }
    private var titleColor: Color { Color(hex: palette.title) }
    private var bodyColor: Color { Color(hex: palette.body) }
    private var closeColor: Color { Color(hex: palette.close) }
    private var accentColor: Color { Color(hex: palette.accent) }
    private var actionBackground: Color {
        accentColor.opacity(isDark ? 0.16 : 0.13)
    }

    var body: some View {
        NoticeBubbleWidthLayout(maxWidth: 400) {
            VStack(alignment: .leading, spacing: 5) {
                titleRow
                if let context, !context.isEmpty {
                    Text(context)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(bodyColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let text, !text.isEmpty {
                    Text(text)
                        .font(.system(size: 13.5))
                        .lineSpacing(3)
                        .foregroundStyle(bodyColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if action != nil || secondaryAction != nil {
                    HStack(spacing: 14) {
                        if let action {
                            actionButton(action)
                        }
                        if let secondaryAction {
                            secondaryActionButton(secondaryAction)
                        }
                    }
                    .padding(.top, 6)
                }
            }
            .padding(.leading, 18)
            .padding(.trailing, onClose == nil ? 18 : 31)
            .padding(.vertical, 16)
        }
        .background {
            shape
                .fill(surface)
                .shadow(
                    color: .black.opacity(isDark ? 0.35 : 0.14),
                    radius: isDark ? 16 : 12,
                    x: 0,
                    y: isDark ? 9 : 6
                )
        }
        .overlay(alignment: .topTrailing) { closeButton }
        .overlay { shape.strokeBorder(border, lineWidth: 1) }
        .overlay(alignment: tailAlignment) { tailShape }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityText))
        .accessibilityAddTraits(.isStaticText)
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if tier == .error {
                Image(systemName: "exclamationmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(accentColor)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(titleColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func actionButton(_ action: NoticeAction) -> some View {
        Button {
            action.perform()
        } label: {
            Text(action.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(titleColor)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(
                    actionBackground,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
        }
        .buttonStyle(.plain)
    }

    private func secondaryActionButton(_ action: NoticeAction) -> some View {
        Button {
            action.perform()
        } label: {
            Text(action.title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(bodyColor)
                .underline()
                .padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var closeButton: some View {
        if let onClose {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(closeColor)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 7)
            .padding(.trailing, 7)
            .accessibilityLabel(Text(closeAccessibilityLabel ?? noticeLocalized("notice.accessibility.dismiss")))
        }
    }

    private var tailAlignment: Alignment {
        switch tail?.edge {
        case .leading: return .leading
        case .trailing: return .trailing
        case .top: return .top
        case .bottom: return .bottom
        case nil: return .center
        }
    }

    @ViewBuilder
    private var tailShape: some View {
        if let tail {
            let edge = tail.edge
            ZStack {
                NoticeTailShape(edge: edge)
                    .fill(surface)
                NoticeTailOutline(edge: edge)
                    .stroke(border, lineWidth: 1)
            }
            .frame(
                width: edge.isHorizontal ? 18 : 16,
                height: edge.isHorizontal ? 10 : 9
            )
            .offset(
                x: edge == .leading ? -17 : (edge == .trailing ? 17 : 0),
                y: edge == .top ? -8 : (edge == .bottom ? 8 : 0)
            )
            .accessibilityHidden(true)
        }
    }

    private var accessibilityText: String {
        let prefix = accessibilityPrefix
            ?? tier.accessibilityPrefixKey.map { noticeLocalized($0) }
            ?? ""
        let body = [title, context, text]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ". ")
        return prefix + body
    }
}

private struct NoticeBubbleWidthLayout: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let width = min(maxWidth, proposal.width ?? maxWidth)
        return content.sizeThatFits(
            ProposedViewSize(width: width, height: proposal.height)
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let content = subviews.first else { return }
        content.place(
            at: bounds.origin,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}

struct NoticeTailShape: Shape {
    let edge: NoticeTail.Edge

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch edge {
        case .leading:
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        case .trailing:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        case .top:
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        case .bottom:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        }
        path.closeSubpath()
        return path
    }
}

struct NoticeTailOutline: Shape {
    let edge: NoticeTail.Edge

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch edge {
        case .leading:
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        case .trailing:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        case .top:
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        case .bottom:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
        return path
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

func noticeLocalized(_ key: String) -> String {
    NSLocalizedString(
        key,
        bundle: RemoteBuddyResourceBundle.mainOrDevelopment,
        comment: ""
    )
}
