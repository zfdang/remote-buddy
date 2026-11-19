import CoreGraphics
import Foundation

/// Holds a complete chord between the remote's voice-session edges.
/// Only modifiers acquired by this session are released.
final class HeldVoiceShortcut: @unchecked Sendable {
    static let shared = HeldVoiceShortcut()
    private struct HeldKey {
        let code: CGKeyCode
        let flags: CGEventFlags
    }
    private let lock = NSRecursiveLock()
    private var held: [HeldKey] = []
    private var shortcut: CustomKeyboardShortcut?
    private var ownedModifierFlags: CGEventFlags = []
    private var post: KeyboardInjector.KeyStatePoster?
    private var readHardware: (() -> CGEventFlags)?
    private var recovery: ScheduledOperation?

    func setPressed(
        _ pressed: Bool, shortcut requested: CustomKeyboardShortcut,
        post: @escaping KeyboardInjector.KeyStatePoster,
        hardwareFlags: @escaping () -> CGEventFlags = KeyboardHardwareModifierPolicy.currentForMappedAction,
        schedule: @escaping OperationScheduler = ScheduledOperation.mainQueue
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if !pressed { return release() }
        if shortcut == requested { return true }
        guard release(), VoiceKeyMode.supportsShortcut(requested) else { return false }
        self.post = post
        readHardware = hardwareFlags
        let physical = hardwareFlags()
        let modifiers = ShortcutEventSequence.selectedModifiers(for: requested.cgEventFlags)
        for modifier in modifiers {
            let alreadyHeld = modifier.sideSpecific
                ? physical.contains(modifier.deviceBit) : physical.contains(modifier.flag)
            if alreadyHeld { continue }
            let key = HeldKey(code: modifier.key, flags: modifier.flag.union(modifier.deviceBit))
            ownedModifierFlags.formUnion(key.flags)
            held.append(key) // Even a failed submission must be cleaned up.
            if !post(key.code, true, flags()) {
                recover(schedule: schedule)
                return false
            }
        }
        held.append(HeldKey(code: requested.keyCode, flags: []))
        guard post(requested.keyCode, true, flags()) else {
            recover(schedule: schedule)
            return false
        }
        shortcut = requested
        return true
    }

    private func physicalFlags() -> CGEventFlags {
        ShortcutEventSequence.hardwareFlags(readHardware?() ?? [], excludingOwned: ownedModifierFlags)
    }

    private func flags() -> CGEventFlags {
        held.reduce(physicalFlags()) { $0.union($1.flags) }
    }

    private func release() -> Bool {
        recovery?.cancel()
        recovery = nil
        guard let post else { return held.isEmpty }
        for index in held.indices.reversed() {
            let key = held[index]
            let releaseFlags = held.enumerated().reduce(physicalFlags()) {
                $1.offset == index ? $0 : $0.union($1.element.flags)
            }
            if post(key.code, false, releaseFlags) || post(key.code, false, releaseFlags) {
                held.remove(at: index)
            }
        }
        shortcut = nil
        if held.isEmpty { self.post = nil; readHardware = nil; ownedModifierFlags = [] }
        return held.isEmpty
    }

    private func recover(schedule: @escaping OperationScheduler, attempt: Int = 0) {
        guard !release(), attempt < 8 else { return }
        recovery = schedule(min(1, 0.05 * pow(2, Double(attempt)))) { [self] in
            lock.lock()
            defer { lock.unlock() }
            recover(schedule: schedule, attempt: attempt + 1)
        }
    }
}

/// Retains the chosen trigger through start/stop pulses and release recovery,
/// including cleanup after its owning app model has been released.
final class VoiceTapTrigger {
    private let selectedMode: () -> VoiceKeyMode
    private let setKey: (VoiceKeyMode, Bool) -> Bool
    private var sessionMode: VoiceKeyMode?

    init(selectedMode: @escaping () -> VoiceKeyMode,
         setKey: @escaping (VoiceKeyMode, Bool) -> Bool = { KeyboardInjector.setVoiceKeyPressed($0, isPressed: $1) }) {
        self.selectedMode = selectedMode
        self.setKey = setKey
    }

    func setPressed(_ pressed: Bool) -> Bool {
        let mode = sessionMode ?? selectedMode()
        sessionMode = mode
        return setKey(mode, pressed)
    }

    func reset() { sessionMode = nil }
}
