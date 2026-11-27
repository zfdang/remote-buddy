import AppKit
import Combine
import CoreGraphics
import SwiftUI

/// Renders action feedback presentations inside `NoticeBubble`.
struct ActionFeedbackView: View {
    let presentation: ActionFeedbackPresentation
    let isCopied: Bool
    let onAction: (ActionFeedbackAction) -> Void
    let onCopy: () -> Void
    let onClose: () -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        content
            .padding(ActionFeedbackLayout.contentPadding)
            .onHover(perform: onHover)
    }

    @ViewBuilder
    private var content: some View {
        switch presentation.kind {
        case .success:
            NoticeBubble(tier: .tip, title: presentation.title)
                .frame(maxWidth: 400)
        case .failure:
            NoticeBubble(
                tier: .error,
                title: presentation.title,
                text: presentation.detail,
                context: presentation.context,
                action: primaryAction,
                secondaryAction: copyAction,
                onClose: onClose,
                accessibilityPrefix: presentation.errorPrefix,
                closeAccessibilityLabel: presentation.closeLabel
            )
            .frame(maxWidth: 380)
        }
    }

    private var primaryAction: NoticeAction? {
        guard let action = presentation.action,
              let title = presentation.actionTitle
        else { return nil }
        return NoticeAction(title: title) {
            onAction(action)
        }
    }

    private var copyAction: NoticeAction? {
        guard let title = presentation.copyTitle else { return nil }
        return NoticeAction(
            title: isCopied ? (presentation.copiedTitle ?? title) : title
        ) {
            onCopy()
        }
    }
}

/// Observes `ActionFeedbackCenter` and presents or hides the floating non-activating HUD panel.
@MainActor
final class ActionFeedbackWindowCoordinator {
    private let center: ActionFeedbackCenter
    private var panel: ActionFeedbackPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var cancellable: AnyCancellable?
    private var loggedPresentationID: UUID?

    init(center: ActionFeedbackCenter? = nil) {
        self.center = center ?? .shared
    }

    func start() {
        cancellable = Publishers.CombineLatest(
            center.$presentation,
            center.$copiedPresentationID
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] presentation, copiedID in
            self?.render(presentation, copiedID: copiedID)
        }
    }

    func stop() {
        cancellable?.cancel()
        cancellable = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        hostingView = nil
    }

    private func render(
        _ presentation: ActionFeedbackPresentation?,
        copiedID: UUID?
    ) {
        guard let presentation else {
            panel?.ignoresMouseEvents = true
            panel?.orderOut(nil)
            if loggedPresentationID != nil {
                loggedPresentationID = nil
                AppLogger.shared.write("ACTION FEEDBACK panel phase=hidden")
            }
            return
        }
        guard let screen = ActionFeedbackScreenResolver.preferredScreen() else { return }
        let view = ActionFeedbackView(
            presentation: presentation,
            isCopied: copiedID == presentation.id,
            onAction: { [weak center] action in center?.perform(action) },
            onCopy: { [weak center] in center?.copyDiagnostics() },
            onClose: { [weak center] in center?.dismiss() },
            onHover: { [weak center] hovering in center?.setHovering(hovering) }
        )
        // Fresh NSHostingView ensures SwiftUI computes an uncached intrinsic fittingSize
        // rather than reusing stale height from an earlier presentation or EmptyView.
        let host = NSHostingView(rootView: AnyView(view))
        host.sizingOptions = [.intrinsicContentSize]
        host.autoresizingMask = [.width, .height]
        host.layoutSubtreeIfNeeded()
        var size = host.fittingSize
        let minimumHeight: CGFloat = presentation.kind == .success ? 76 : 120
        size.width = min(max(size.width, 140), 432)
        size.height = max(size.height, minimumHeight)
        let panel = ensurePanel()
        panel.ignoresMouseEvents = presentation.kind == .success
        hostingView = host
        panel.contentView = host
        panel.setContentSize(size)
        let origin = ActionFeedbackLayout.origin(
            visibleFrame: screen.visibleFrame,
            panelSize: size
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        host.frame = NSRect(origin: .zero, size: size)
        panel.orderFrontRegardless()
        if loggedPresentationID != presentation.id {
            loggedPresentationID = presentation.id
            AppLogger.shared.write(
                "ACTION FEEDBACK panel phase=shown kind=\(presentation.kind) " +
                    "width=\(Int(size.width)) height=\(Int(size.height)) " +
                    "x=\(Int(origin.x)) y=\(Int(origin.y)) " +
                    "window_number=\(panel.windowNumber) " +
                    "screen_width=\(Int(screen.visibleFrame.width)) " +
                    "screen_height=\(Int(screen.visibleFrame.height)) " +
                    "ignores_mouse=\(presentation.kind == .success)"
            )
        }
        if presentation.announces,
           let announcement = presentation.accessibilityAnnouncement,
           let contentView = panel.contentView {
            let userInfo: [NSAccessibility.NotificationUserInfoKey: Any] = [
                .announcement: announcement,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
            NSAccessibility.post(
                element: contentView,
                notification: .announcementRequested,
                userInfo: userInfo
            )
        }
    }

    private func ensureHostingView() -> NSHostingView<AnyView> {
        if let hostingView { return hostingView }
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        host.autoresizingMask = [.width, .height]
        hostingView = host
        return host
    }

    private func ensurePanel() -> ActionFeedbackPanel {
        if let panel { return panel }
        let panel = ActionFeedbackPanel(
            contentRect: NSRect(x: 0, y: 0, width: 412, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
        ]
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.contentView = ensureHostingView()
        self.panel = panel
        return panel
    }
}

private final class ActionFeedbackPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Resolves the target screen using public window bounds geometry only.
enum ActionFeedbackScreenResolver {
    static func preferredScreen(
        frontmostPID: pid_t? = NSWorkspace.shared.frontmostApplication?.processIdentifier,
        windowInfo: [[String: Any]]? = nil,
        screens: [NSScreen] = NSScreen.screens,
        mainScreen: NSScreen? = NSScreen.main
    ) -> NSScreen? {
        let fallback = mainScreen ?? screens.first
        guard let frontmostPID, !screens.isEmpty else { return fallback }
        let windows = windowInfo ?? (
            CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]] ?? []
        )
        let displayFrames: [(screen: NSScreen, frame: CGRect)] = screens.map { screen in
            let displayID = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? CGDirectDisplayID
            let frame = displayID.map(CGDisplayBounds)
                ?? CGRect(
                    x: screen.frame.minX,
                    y: (mainScreen?.frame.maxY ?? 0) - screen.frame.maxY,
                    width: screen.frame.width,
                    height: screen.frame.height
                )
            return (screen, frame)
        }
        for window in windows {
            guard let ownerPID = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  ownerPID == frontmostPID,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width > 1, frame.height > 1
            else { continue }
            var windowBest: (screen: NSScreen, area: CGFloat)?
            for entry in displayFrames {
                let area = entry.frame.intersection(frame).area
                if area > (windowBest?.area ?? 0) {
                    windowBest = (entry.screen, area)
                }
            }
            if let matched = windowBest, matched.area > 0 {
                return matched.screen
            }
        }
        return fallback
    }

    static func bestScreenIndex(
        windowFrame: CGRect,
        screenFrames: [CGRect]
    ) -> Int? {
        guard !screenFrames.isEmpty else { return nil }
        var best: (index: Int, area: CGFloat)?
        for (index, frame) in screenFrames.enumerated() {
            let area = frame.intersection(windowFrame).area
            if area > (best?.area ?? 0) {
                best = (index, area)
            }
        }
        guard let best, best.area > 0 else { return nil }
        return best.index
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else { return 0 }
        return width * height
    }
}
