import CoreGraphics
import Foundation
import os

extension KeyboardInjector {
    final class AppSwitcherSession: @unchecked Sendable {
        typealias OwnedKeyStatePoster = (CGKeyCode, Bool, CGEventFlags, CGEventFlags) -> Bool

        static let leftOptionKeyCode: CGKeyCode = 58
        /// Option down and Command up must arrive in separate event cycles so Dock reads
        /// Option as still held when Command releases and restores minimized windows.
        static let optionHoldDuration: TimeInterval = 0.06
        static let optionReleaseDuration: TimeInterval = 0.10
        private static let maxModifierReleaseAttempts = 4
        private static let activeSyntheticModifierCounts = OSAllocatedUnfairLock(initialState: (command: 0, option: 0))

        static var activeSyntheticModifiers: CGEventFlags {
            activeSyntheticModifierCounts.withLock { counts in
                var flags: CGEventFlags = []
                if counts.command > 0 { flags.formUnion(.maskCommand) }
                if counts.option > 0 { flags.formUnion(.maskAlternate) }
                return flags
            }
        }

        private let lock = NSRecursiveLock()
        private let keyStatePoster: OwnedKeyStatePoster
        private let hardwareFlags: () -> CGEventFlags
        private var diagnosticLogger: ((String) -> Void)?
        private var active = false
        private var registeredSyntheticModifiers: CGEventFlags = []
        private var ownedCommandFlags: CGEventFlags = [] {
            didSet { syncRegisteredSyntheticModifiers() }
        }
        private var isBorrowingCommand = false
        private var releaseTask: ScheduledOperation?
        private var optionReleaseTask: ScheduledOperation?
        private var hasPendingOptionRelease = false {
            didSet { syncRegisteredSyntheticModifiers() }
        }
        private var ownedCommandPendingRelease = false {
            didSet { syncRegisteredSyntheticModifiers() }
        }
        private var releaseGeneration: UInt64 = 0
        private var releaseAttempts = 0
        private var commandReleaseAttempts = 0
        private var optionReleaseAttempts = 0
        private var scheduleRelease: OperationScheduler

        var isActive: Bool {
            lock.withLock { active }
        }

        var hasPendingModifierRelease: Bool {
            lock.withLock { ownedCommandPendingRelease || hasPendingOptionRelease }
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
                ownedCommandFlags = []
                ownedCommandPendingRelease = false
                hasPendingOptionRelease = false
                releaseGeneration &+= 1
                releaseTask?.cancel()
                releaseTask = nil
                optionReleaseTask?.cancel()
                optionReleaseTask = nil
            }
        }

        private func syncRegisteredSyntheticModifiers() {
            var next: CGEventFlags = []
            if !ownedCommandFlags.isEmpty || ownedCommandPendingRelease {
                next.formUnion(.maskCommand)
            }
            if hasPendingOptionRelease {
                next.formUnion(.maskAlternate)
            }
            guard next != registeredSyntheticModifiers else { return }
            let previous = registeredSyntheticModifiers
            let updated = next
            registeredSyntheticModifiers = updated
            Self.activeSyntheticModifierCounts.withLock { counts in
                if previous.contains(.maskCommand) != updated.contains(.maskCommand) {
                    counts.command = max(0, counts.command + (updated.contains(.maskCommand) ? 1 : -1))
                }
                if previous.contains(.maskAlternate) != updated.contains(.maskAlternate) {
                    counts.option = max(0, counts.option + (updated.contains(.maskAlternate) ? 1 : -1))
                }
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
                guard flushPendingOptionConfirmationIfNeeded() else { return false }
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
        func cancel(dismissSwitcher: Bool = true) -> Bool {
            lock.withLock {
                let flushed = flushPendingOptionConfirmationIfNeeded()
                guard active else { return flushed }
                if endBorrowedSessionIfCommandReleased() { return flushed }
                // Releasing Command confirms the selection. When the native switcher HUD is still
                // active, Escape must dismiss it while Command is held before releasing Command;
                // if the HUD was already dismissed externally, skip Escape so we don't forward it.
                var cancelled = true
                if dismissSwitcher {
                    let pressed = post(53, isDown: true, flags: .maskCommand, role: "cancel")
                    let released = post(53, isDown: false, flags: .maskCommand, role: "cancel")
                    cancelled = pressed && released
                }
                let commandReleased = releaseCommandKey()
                return flushed && cancelled && commandReleased
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
                optionReleaseAttempts = 0
                ownedCommandPendingRelease = true
                commandReleaseAttempts = 0
                let generation = releaseGeneration

                releaseTask = scheduleRelease(Self.optionHoldDuration) { [weak self] in
                    guard let self else { return }
                    self.lock.withLock {
                        self.releaseConfirmedCommandKey(generation: generation)
                    }
                }
                return true
            }
        }

        private static func releaseRetryDelay(attempt: Int) -> TimeInterval {
            0.05 * pow(2, Double(max(0, attempt - 1)))
        }

        private func scheduleConfirmedCommandRetry(generation: UInt64) {
            commandReleaseAttempts += 1
            guard commandReleaseAttempts < Self.maxModifierReleaseAttempts else {
                diagnosticLogger?("confirm_command_release_blocked attempts=\(commandReleaseAttempts)")
                return
            }
            releaseTask = scheduleRelease(Self.releaseRetryDelay(attempt: commandReleaseAttempts)) {
                [weak self] in
                guard let self else { return }
                self.lock.withLock {
                    self.releaseConfirmedCommandKey(generation: generation)
                }
            }
        }

        private func scheduleConfirmedOptionRelease(after delay: TimeInterval, generation: UInt64) {
            optionReleaseTask?.cancel()
            optionReleaseTask = scheduleRelease(delay) { [weak self] in
                guard let self else { return }
                self.lock.withLock {
                    self.releaseConfirmedOptionKey(generation: generation)
                }
            }
        }

        private func scheduleConfirmedOptionRetry(generation: UInt64) {
            optionReleaseAttempts += 1
            guard optionReleaseAttempts < Self.maxModifierReleaseAttempts else {
                diagnosticLogger?("confirm_option_release_blocked attempts=\(optionReleaseAttempts)")
                return
            }
            scheduleConfirmedOptionRelease(
                after: Self.releaseRetryDelay(attempt: optionReleaseAttempts),
                generation: generation
            )
        }

        private func releaseConfirmedCommandKey(generation: UInt64) {
            guard releaseGeneration == generation, ownedCommandPendingRelease else { return }
            releaseTask = nil
            let released = post(
                leftCommandKeyCode,
                isDown: false,
                flags: hasPendingOptionRelease ? [.maskAlternate] : [],
                excludingOwned: ownedCommandFlags,
                role: "command"
            )
            if released {
                ownedCommandPendingRelease = false
                ownedCommandFlags = []
                commandReleaseAttempts = 0
                if hasPendingOptionRelease, optionReleaseTask == nil {
                    scheduleConfirmedOptionRelease(
                        after: Self.optionReleaseDuration,
                        generation: generation
                    )
                }
            } else {
                scheduleConfirmedCommandRetry(generation: generation)
                if !ownedCommandPendingRelease || commandReleaseAttempts >= Self.maxModifierReleaseAttempts,
                   hasPendingOptionRelease,
                   optionReleaseTask == nil {
                    scheduleConfirmedOptionRelease(
                        after: Self.optionReleaseDuration,
                        generation: generation
                    )
                }
            }
        }

        private func releaseConfirmedOptionKey(generation: UInt64) {
            guard releaseGeneration == generation, hasPendingOptionRelease else { return }
            optionReleaseTask = nil
            let released = post(
                Self.leftOptionKeyCode,
                isDown: false,
                flags: ownedCommandPendingRelease ? [.maskCommand] : [],
                excludingOwned: ShortcutEventSequence.modifierFlags(for: Self.leftOptionKeyCode),
                role: "option"
            )
            if released {
                hasPendingOptionRelease = false
                optionReleaseAttempts = 0
            } else {
                scheduleConfirmedOptionRetry(generation: generation)
            }
        }

        @discardableResult
        private func flushPendingOptionConfirmationIfNeeded() -> Bool {
            guard ownedCommandPendingRelease || hasPendingOptionRelease else { return true }
            releaseGeneration &+= 1
            let generation = releaseGeneration
            releaseTask?.cancel()
            releaseTask = nil
            optionReleaseTask?.cancel()
            optionReleaseTask = nil
            if ownedCommandPendingRelease {
                let commandReleased = post(
                    leftCommandKeyCode,
                    isDown: false,
                    flags: hasPendingOptionRelease ? [.maskAlternate] : [],
                    excludingOwned: ownedCommandFlags,
                    role: "command"
                )
                if commandReleased {
                    ownedCommandPendingRelease = false
                    ownedCommandFlags = []
                    commandReleaseAttempts = 0
                } else {
                    scheduleConfirmedCommandRetry(generation: generation)
                }
            }
            if hasPendingOptionRelease {
                let optionReleased = post(
                    Self.leftOptionKeyCode,
                    isDown: false,
                    flags: ownedCommandPendingRelease ? [.maskCommand] : [],
                    excludingOwned: ShortcutEventSequence.modifierFlags(for: Self.leftOptionKeyCode),
                    role: "option"
                )
                if optionReleased {
                    hasPendingOptionRelease = false
                    optionReleaseAttempts = 0
                } else {
                    scheduleConfirmedOptionRetry(generation: generation)
                }
            }
            return !ownedCommandPendingRelease && !hasPendingOptionRelease
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
