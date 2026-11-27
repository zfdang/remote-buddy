import CoreGraphics
import Foundation

extension KeyboardInjector {
    final class AppSwitcherSession: @unchecked Sendable {
        typealias OwnedKeyStatePoster = (CGKeyCode, Bool, CGEventFlags, CGEventFlags) -> Bool

        static let leftOptionKeyCode: CGKeyCode = 58
        /// Option down and Command up must arrive in separate event cycles so Dock reads
        /// Option as still held when Command releases and restores minimized windows.
        static let optionHoldDuration: TimeInterval = 0.06
        static let optionReleaseDuration: TimeInterval = 0.10

        private let lock = NSRecursiveLock()
        private let keyStatePoster: OwnedKeyStatePoster
        private let hardwareFlags: () -> CGEventFlags
        private var diagnosticLogger: ((String) -> Void)?
        private var active = false
        private var ownedCommandFlags: CGEventFlags = []
        private var isBorrowingCommand = false
        private var releaseTask: ScheduledOperation?
        private var optionReleaseTask: ScheduledOperation?
        private var hasPendingOptionRelease = false
        private var ownedCommandPendingRelease = false
        private var releaseGeneration: UInt64 = 0
        private var releaseAttempts = 0
        private var scheduleRelease: OperationScheduler

        var isActive: Bool {
            lock.withLock { active }
        }

        init(
            hardwareFlags: @escaping () -> CGEventFlags = KeyboardHardwareModifierPolicy.currentForAppSwitcher,
            keyStatePoster: @escaping OwnedKeyStatePoster = KeyboardInjector.postOwnedKeyState,
            scheduleRelease: @escaping OperationScheduler = ScheduledOperation.mainQueue
        ) {
            self.hardwareFlags = hardwareFlags
            self.keyStatePoster = keyStatePoster
            self.scheduleRelease = scheduleRelease
        }

        deinit {
            lock.withLock {
                releaseGeneration &+= 1
                releaseTask?.cancel()
                releaseTask = nil
                optionReleaseTask?.cancel()
                optionReleaseTask = nil
            }
        }

        func setDiagnosticLogger(_ logger: @escaping (String) -> Void) {
            lock.withLock {
                diagnosticLogger = logger
            }
        }

        private func hasPhysicalCommand() -> Bool {
            KeyboardHardwareModifierPolicy.mappedActionFlags(hardwareFlags()).contains(.maskCommand)
        }

        private func endBorrowedSessionIfCommandReleased() -> Bool {
            guard active, isBorrowingCommand, !hasPhysicalCommand() else { return false }
            releaseGeneration &+= 1
            releaseTask?.cancel()
            releaseTask = nil
            active = false
            isBorrowingCommand = false
            ownedCommandFlags = []
            releaseAttempts = 0
            return true
        }

        private func post(
            _ keyCode: CGKeyCode,
            isDown: Bool,
            flags: CGEventFlags,
            excludingOwned: CGEventFlags = [],
            role: String
        ) -> Bool {
            let logger = lock.withLock { diagnosticLogger }
            let result = keyStatePoster(keyCode, isDown, flags, excludingOwned)
            logger?(
                "role=\(role) key_code=\(keyCode) edge=\(isDown ? "down" : "up") " +
                    "command=\(flags.contains(.maskCommand)) success=\(result)"
            )
            return result
        }

        @discardableResult
        func trigger() -> Bool {
            lock.withLock {
                flushPendingOptionConfirmationIfNeeded()
                if active {
                    guard releaseAttempts == 0 else { return false }
                    if !endBorrowedSessionIfCommandReleased() {
                        return postTab()
                    }
                    // Borrowed physical Command ended early; acquire fresh synthetic ownership below.
                }

                let shouldOwnCommand = !hasPhysicalCommand()
                let ownedFlags = shouldOwnCommand
                    ? ShortcutEventSequence.modifierFlags(for: leftCommandKeyCode)
                    : []
                if shouldOwnCommand {
                    guard post(leftCommandKeyCode, isDown: true, flags: .maskCommand, role: "command") else {
                        return false
                    }
                }
                ownedCommandFlags = ownedFlags
                isBorrowingCommand = !shouldOwnCommand
                active = true
                guard postTab() else {
                    _ = releaseCommandKey()
                    return false
                }
                return true
            }
        }

        /// One-shot mappings hold Command briefly so the switcher can appear;
        /// repeated triggers extend the hold and cycle the same session.
        @discardableResult
        func triggerTemporarily(
            schedule: OperationScheduler? = nil
        ) -> Bool {
            lock.withLock {
                if let schedule { scheduleRelease = schedule }
                guard trigger() else { return false }
                releaseGeneration &+= 1
                let generation = releaseGeneration
                releaseTask?.cancel()
                releaseTask = scheduleRelease(1) { [weak self] in
                    guard let self else { return }
                    self.lock.withLock {
                        guard self.releaseGeneration == generation else { return }
                        _ = self.confirm(restoreMinimizedWindows: false)
                    }
                }
                return true
            }
        }

        @discardableResult
        func cancel() -> Bool {
            lock.withLock {
                flushPendingOptionConfirmationIfNeeded()
                guard active else { return true }
                if endBorrowedSessionIfCommandReleased() { return true }
                // Releasing Command confirms the selection. Escape must dismiss the
                // native switcher while Command is still held before we release it.
                let pressed = post(53, isDown: true, flags: .maskCommand, role: "cancel")
                let released = post(53, isDown: false, flags: .maskCommand, role: "cancel")
                let commandReleased = releaseCommandKey()
                return pressed && released && commandReleased
            }
        }

        @discardableResult
        func confirm(restoreMinimizedWindows: Bool = true) -> Bool {
            lock.withLock {
                guard active else { return true }
                if endBorrowedSessionIfCommandReleased() { return true }
                if isBorrowingCommand || !restoreMinimizedWindows {
                    return releaseCommandKey()
                }

                releaseGeneration &+= 1
                releaseTask?.cancel()
                releaseTask = nil
                optionReleaseTask?.cancel()
                optionReleaseTask = nil
                active = false
                releaseAttempts = 0

                guard post(
                    Self.leftOptionKeyCode,
                    isDown: true,
                    flags: [.maskCommand, .maskAlternate],
                    role: "option"
                ) else {
                    active = true
                    return releaseCommandKey()
                }

                hasPendingOptionRelease = true
                ownedCommandPendingRelease = true
                let generation = releaseGeneration
                let optionOwnedFlags = ShortcutEventSequence.modifierFlags(for: Self.leftOptionKeyCode)
                let capturedCommandFlags = ownedCommandFlags

                releaseTask = scheduleRelease(Self.optionHoldDuration) { [weak self] in
                    guard let self else { return }
                    self.lock.withLock {
                        guard self.releaseGeneration == generation else { return }
                        self.releaseTask = nil
                        _ = self.post(
                            leftCommandKeyCode,
                            isDown: false,
                            flags: [.maskAlternate],
                            excludingOwned: capturedCommandFlags,
                            role: "command"
                        )
                        self.ownedCommandPendingRelease = false
                        self.ownedCommandFlags = []
                        self.optionReleaseTask = self.scheduleRelease(Self.optionReleaseDuration) {
                            [weak self] in
                            guard let self else { return }
                            self.lock.withLock {
                                guard self.releaseGeneration == generation else { return }
                                self.optionReleaseTask = nil
                                _ = self.post(
                                    Self.leftOptionKeyCode,
                                    isDown: false,
                                    flags: [],
                                    excludingOwned: optionOwnedFlags,
                                    role: "option"
                                )
                                self.hasPendingOptionRelease = false
                            }
                        }
                    }
                }
                return true
            }
        }

        private func flushPendingOptionConfirmationIfNeeded() {
            guard hasPendingOptionRelease else { return }
            releaseGeneration &+= 1
            releaseTask?.cancel()
            releaseTask = nil
            optionReleaseTask?.cancel()
            optionReleaseTask = nil
            if ownedCommandPendingRelease {
                _ = post(
                    leftCommandKeyCode,
                    isDown: false,
                    flags: [.maskAlternate],
                    excludingOwned: ownedCommandFlags,
                    role: "command"
                )
                ownedCommandPendingRelease = false
                ownedCommandFlags = []
            }
            let optionOwnedFlags = ShortcutEventSequence.modifierFlags(for: Self.leftOptionKeyCode)
            _ = post(
                Self.leftOptionKeyCode,
                isDown: false,
                flags: [],
                excludingOwned: optionOwnedFlags,
                role: "option"
            )
            hasPendingOptionRelease = false
        }

        private func releaseCommandKey() -> Bool {
            releaseGeneration &+= 1
            releaseTask?.cancel()
            releaseTask = nil
            guard active else { return true }
            if isBorrowingCommand {
                active = false
                isBorrowingCommand = false
                ownedCommandFlags = []
                releaseAttempts = 0
                return true
            }
            let released = post(
                leftCommandKeyCode,
                isDown: false,
                flags: [],
                excludingOwned: ownedCommandFlags,
                role: "command"
            )
            active = !released
            if released {
                ownedCommandFlags = []
                releaseAttempts = 0
            } else {
                releaseAttempts += 1
                if releaseAttempts < 4 {
                    let generation = releaseGeneration
                    let delay = 0.05 * pow(2, Double(releaseAttempts - 1))
                    releaseTask = scheduleRelease(delay) { [weak self] in
                        guard let self else { return }
                        self.lock.withLock {
                            guard self.releaseGeneration == generation else { return }
                            _ = self.releaseCommandKey()
                        }
                    }
                } else {
                    diagnosticLogger?("command_release_blocked attempts=\(releaseAttempts)")
                }
            }
            return released
        }

        @discardableResult
        func moveSelection(left: Bool) -> Bool {
            lock.withLock {
                guard active else { return false }
                if endBorrowedSessionIfCommandReleased() { return false }
                let keyCode: CGKeyCode = left ? 123 : 124
                let pressed = post(keyCode, isDown: true, flags: .maskCommand, role: "selection")
                let released = post(keyCode, isDown: false, flags: .maskCommand, role: "selection")
                return pressed && released
            }
        }

        private func postTab() -> Bool {
            let pressed = post(48, isDown: true, flags: .maskCommand, role: "tab")
            let released = post(48, isDown: false, flags: .maskCommand, role: "tab")
            return pressed && released
        }
    }
}
