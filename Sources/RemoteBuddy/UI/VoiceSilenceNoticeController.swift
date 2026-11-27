import AppKit
import SwiftUI

/// Tracks continuous hands-free streaming silence so Remote Buddy can display a single
/// reminder when a user forgets to end a G9N9N hands-free session.
///
/// The remote gates audio frames via hardware VAD, so the countdown begins only after
/// the first decoded audio batch arrives in the active hands-free session, and fires at
/// most once per session.
struct VoiceSilenceNoticeTracker: Equatable {
    static let silenceThreshold: TimeInterval = 60

    private(set) var lastAudioAt: TimeInterval?
    private(set) var didPresent = false

    mutating func beginSession() {
        lastAudioAt = nil
        didPresent = false
    }

    mutating func audioReceived(at time: TimeInterval) {
        guard time.isFinite else { return }
        lastAudioAt = time
    }

    mutating func consumePresentationIfDue(now: TimeInterval) -> Bool {
        guard !didPresent,
              let lastAudioAt,
              now.isFinite,
              lastAudioAt.isFinite,
              now - lastAudioAt >= Self.silenceThreshold
        else { return false }
        didPresent = true
        return true
    }

    mutating func endSession() {
        lastAudioAt = nil
        didPresent = false
    }
}

/// Non-activating, click-through floating reminder shown over any space or full-screen app.
@MainActor
final class VoiceSilenceNoticeController {
    static let visibleDuration: TimeInterval = 5

    private var window: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?
    private let logger: (String) -> Void

    init(logger: @escaping (String) -> Void = { AppLogger.shared.write($0) }) {
        self.logger = logger
    }

    var isVisible: Bool { window != nil }

    func present(title: String, text: String) {
        dismiss(reason: "replaced")
        guard let screen = ActionFeedbackScreenResolver.preferredScreen() else {
            logger("VOICE SILENCE NOTICE phase=shown result=failed reason=no_screen")
            return
        }
        let hosting = NSHostingView(
            rootView: NoticeBubble(tier: .tip, title: title, text: text)
                .padding(ActionFeedbackLayout.contentPadding)
        )
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.autoresizingMask = [.width, .height]
        hosting.layoutSubtreeIfNeeded()
        var size = hosting.fittingSize
        size.width = min(max(size.width, 180), 432)
        size.height = max(size.height, 88)

        let panel = VoiceSilenceNoticePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        panel.setContentSize(size)

        let origin = ActionFeedbackLayout.origin(
            visibleFrame: screen.visibleFrame,
            panelSize: size
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)

        window = panel
        panel.orderFrontRegardless()
        logger(
            "VOICE SILENCE NOTICE phase=shown result=visible "
                + "size=\(Int(size.width))x\(Int(size.height)) duration_s=\(Int(Self.visibleDuration))"
        )

        let work = DispatchWorkItem { [weak self] in
            self?.dismiss(reason: "timeout")
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.visibleDuration,
            execute: work
        )
    }

    func dismiss(reason: String) {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        guard let window else { return }
        window.orderOut(nil)
        self.window = nil
        logger("VOICE SILENCE NOTICE phase=hidden reason=\(reason)")
    }
}

private final class VoiceSilenceNoticePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
