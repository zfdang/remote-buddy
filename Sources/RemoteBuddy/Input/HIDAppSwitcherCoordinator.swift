import AppKit
import Foundation

/// Coordinates a single macOS App Switcher (`Command+Tab`) session and its
/// lifecycle timers across all active `HIDRemoteMonitor` instances.
final class HIDAppSwitcherCoordinator {
    let session: KeyboardInjector.AppSwitcherSession
    private let scheduler: HIDRemoteScheduling
    private let frontmostBundleIdentifier: () -> String?
    private let switcherHUDVisible: () -> Bool?
    private let diagnosticLogger: (String) -> Void
    private var timeoutTask: HIDRemoteScheduledTask?
    private var hudMonitorTask: HIDRemoteScheduledTask?
    private var confirmationProbeTask: HIDRemoteScheduledTask?
    private var ownerToken: UUID?
    private var hudAbsentTicks = 0

    var isActive: Bool {
        session.isActive
    }

    func isOwned(by owner: UUID) -> Bool {
        isActive && ownerToken == owner
    }

    init(
        session: KeyboardInjector.AppSwitcherSession = KeyboardInjector.AppSwitcherSession(),
        scheduler: HIDRemoteScheduling = DispatchHIDRemoteScheduler(),
        frontmostBundleIdentifier: @escaping () -> String? = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        },
        switcherHUDVisible: @escaping () -> Bool? = {
            KeyboardInjector.isAppSwitcherHUDVisible()
        },
        diagnosticLogger: @escaping (String) -> Void = AppLogger.shared.write
    ) {
        self.session = session
        self.scheduler = scheduler
        self.frontmostBundleIdentifier = frontmostBundleIdentifier
        self.switcherHUDVisible = switcherHUDVisible
        self.diagnosticLogger = diagnosticLogger
    }

    func trigger(
        for button: RemoteButton,
        trigger: ButtonTrigger,
        owner: UUID
    ) -> Bool {
        let wasActive = session.isActive
        let phase = session.isActive ? "tab" : "start"
        let submitted = session.trigger()
        diagnosticLogger(
            "HID APP SWITCHER button=\(button.rawValue) trigger=\(trigger.rawValue) " +
                "phase=\(phase) success=\(submitted)"
        )
        if submitted, !wasActive {
            ownerToken = owner
            startLifecycle()
        } else if submitted {
            ownerToken = owner
            hudAbsentTicks = 0
            scheduleTimeout()
        } else if wasActive {
            finishLifecycle(reason: "tab_failed", confirmed: false)
        } else {
            ownerToken = nil
        }
        return submitted
    }

    func handleControlPress(_ button: RemoteButton, owner: UUID) -> Bool {
        switch button {
        case .ok:
            let confirmed = session.confirm()
            finishLifecycle(
                reason: confirmed ? "confirmed" : "confirm_failed",
                confirmed: confirmed
            )
            return true
        case .back:
            finishLifecycle(reason: "back", confirmed: false)
            return true
        case .left, .right:
            let moved = session.moveSelection(left: button == .left)
            diagnosticLogger(
                "HID APP SWITCHER button=\(button.rawValue) phase=navigate success=\(moved)"
            )
            if !moved {
                finishLifecycle(reason: "navigate_failed", confirmed: false)
            } else {
                ownerToken = owner
                hudAbsentTicks = 0
                scheduleTimeout()
            }
            return true
        case .up, .down:
            diagnosticLogger(
                "HID APP SWITCHER button=\(button.rawValue) phase=navigate success=true " +
                    "direction=unsupported"
            )
            return true
        default:
            return false
        }
    }

    func finishLifecycle(reason: String, confirmed: Bool, dismissSwitcher: Bool = true) {
        timeoutTask?.cancel()
        timeoutTask = nil
        hudMonitorTask?.cancel()
        hudMonitorTask = nil
        hudAbsentTicks = 0
        if session.isActive {
            _ = session.cancel(dismissSwitcher: dismissSwitcher)
        }
        diagnosticLogger(
            "HID APP SWITCHER ended reason=\(reason) confirmed=\(confirmed)"
        )
        if confirmed {
            confirmationProbeTask?.cancel()
            confirmationProbeTask = scheduler.schedule(
                afterMilliseconds: HIDRemoteTiming.appSwitcherConfirmationProbeMilliseconds,
                repeatingEveryMilliseconds: nil
            ) { [weak self] in
                guard let self else { return }
                self.confirmationProbeTask = nil
                self.diagnosticLogger(
                    "HID APP SWITCHER selection bundle_id=" +
                        (self.frontmostBundleIdentifier() ?? "unknown")
                )
            }
        }
        ownerToken = nil
    }

    func finishIfActive(reason: String, confirmed: Bool) {
        guard isActive else { return }
        finishLifecycle(reason: reason, confirmed: confirmed)
    }

    func finishIfActive(forOwner owner: UUID, reason: String, confirmed: Bool) {
        guard isOwned(by: owner) else { return }
        finishLifecycle(reason: reason, confirmed: confirmed)
    }

    /// Cancels an active session only when the monitor that owns it resets its input state,
    /// so an idle or disconnecting second remote cannot dismiss another remote's switcher.
    func cancelForInputReset(owner: UUID) {
        guard ownerToken == owner else { return }
        if session.isActive {
            _ = session.cancel()
            diagnosticLogger("HID APP SWITCHER cancelled reason=input_reset")
        }
        resetState()
    }

    func cancelAll() {
        if session.isActive {
            _ = session.cancel()
            diagnosticLogger("HID APP SWITCHER cancelled reason=monitors_stopped")
        }
        resetState()
    }

    private func resetState() {
        timeoutTask?.cancel()
        timeoutTask = nil
        hudMonitorTask?.cancel()
        hudMonitorTask = nil
        confirmationProbeTask?.cancel()
        confirmationProbeTask = nil
        ownerToken = nil
        hudAbsentTicks = 0
    }

    private func startLifecycle() {
        scheduleTimeout()
        confirmationProbeTask?.cancel()
        confirmationProbeTask = nil
        hudAbsentTicks = 0
        hudMonitorTask?.cancel()
        hudMonitorTask = scheduler.schedule(
            afterMilliseconds: HIDRemoteTiming.appSwitcherFrontmostPollMilliseconds,
            repeatingEveryMilliseconds: HIDRemoteTiming.appSwitcherFrontmostPollMilliseconds
        ) { [weak self] in
            guard let self, self.session.isActive else { return }
            switch self.switcherHUDVisible() {
            case true?:
                self.hudAbsentTicks = 0
            case nil:
                // An unreadable AX state must not be mistaken for dismissal.
                return
            case false?:
                self.hudAbsentTicks += 1
                guard self.hudAbsentTicks >= 2 else { return }
                self.finishLifecycle(
                    reason: "hud_dismissed",
                    confirmed: false,
                    dismissSwitcher: false
                )
            }
        }
    }

    private func scheduleTimeout() {
        timeoutTask?.cancel()
        timeoutTask = scheduler.schedule(
            afterMilliseconds: HIDRemoteTiming.appSwitcherTimeoutMilliseconds,
            repeatingEveryMilliseconds: nil
        ) { [weak self] in
            guard let self, self.session.isActive else { return }
            self.finishLifecycle(reason: "timeout", confirmed: false)
        }
    }
}
