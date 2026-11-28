import AppKit
import ApplicationServices
@preconcurrency import CoreGraphics
import Darwin
import Foundation
import os

extension KeyboardInjector {
    struct PostVoicePhantomSweepState {
        private(set) var previousCandidates: [CGKeyCode] = []

        mutating func advance(currentCandidates: [CGKeyCode]) -> [CGKeyCode] {
            guard !currentCandidates.isEmpty else {
                previousCandidates = []
                return []
            }
            let confirmed = currentCandidates.filter { previousCandidates.contains($0) }
            if !confirmed.isEmpty {
                previousCandidates = []
                return confirmed
            }
            previousCandidates = currentCandidates
            return []
        }
    }

    private struct PostVoiceSweepBox {
        var generation: UInt64 = 0
        var ticks: Int = 0
        var timer: DispatchSourceTimer?
        var state = PostVoicePhantomSweepState()
    }

    private static let postVoiceSweep = OSAllocatedUnfairLock(initialState: PostVoiceSweepBox())

    static func cancelPostVoicePhantomModifierSweep() {
        let timer = postVoiceSweep.withLock { box -> DispatchSourceTimer? in
            box.generation &+= 1
            box.ticks = 0
            box.state = PostVoicePhantomSweepState()
            let existing = box.timer
            box.timer = nil
            return existing
        }
        timer?.cancel()
    }

    /// Watches `.hidSystemState` briefly after a voice session ends so if an external voice tool
    /// (such as bageshuo) pastes recognized speech via synthetic `Cmd+V` and leaves virtual key 55
    /// or bare `.maskCommand` stuck without device-side bits, WindowServer is cleaned automatically
    /// after two consecutive observations (avoiding any race mid-`Cmd+V`).
    static func startPostVoicePhantomModifierSweep() {
        guard !AppLogger.isTestProcess(), isAccessibilityTrusted else { return }
        let (generation, previousTimer) = postVoiceSweep.withLock { box -> (UInt64, DispatchSourceTimer?) in
            box.generation &+= 1
            box.ticks = 0
            box.state = PostVoicePhantomSweepState()
            let old = box.timer
            box.timer = nil
            return (box.generation, old)
        }
        previousTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        let maxTicks = 50 // 50 * 120ms = 6.0s window for cloud ASR paste completion
        timer.schedule(deadline: .now() + .milliseconds(120), repeating: .milliseconds(120))
        timer.setEventHandler {
            let owned = currentSyntheticOwnedModifiers()
            let rawFlags = CGEventSource.flagsState(.hidSystemState)
            let heldKeys = KeyboardHardwareModifierPolicy.currentHeldModifierKeys()
            let candidates = KeyboardHardwareModifierPolicy.phantomStuckModifierKeys(
                rawFlags: rawFlags,
                heldKeys: heldKeys,
                ownedModifiers: owned
            )
            let (confirmed, shouldStop) = postVoiceSweep.withLock { box -> ([CGKeyCode], Bool) in
                guard box.generation == generation else { return ([], true) }
                box.ticks += 1
                let confirmed = box.state.advance(currentCandidates: candidates)
                let done = box.ticks >= maxTicks
                if done {
                    box.timer = nil
                }
                return (confirmed, done)
            }
            if !confirmed.isEmpty {
                _ = clearPhantomHIDModifierKeys(confirmed, rawFlags: rawFlags)
            }
            if shouldStop {
                timer.cancel()
            }
        }
        let cancelledBeforeStore = postVoiceSweep.withLock { box -> Bool in
            guard box.generation == generation else { return true }
            box.timer = timer
            return false
        }
        if cancelledBeforeStore {
            timer.cancel()
        }
        timer.resume()
    }

    static func restoredFlagsForPhantomClear(
        hardwareFlags: () -> CGEventFlags = KeyboardHardwareModifierPolicy.current
    ) -> CGEventFlags {
        KeyboardHardwareModifierPolicy.sanitizedEventFlags(hardwareFlags())
    }

    private static func currentSyntheticOwnedModifiers() -> CGEventFlags {
        HeldVoiceShortcut.shared.activeOwnedModifiers.union(AppSwitcherSession.activeSyntheticModifiers)
    }

    @discardableResult
    static func clearPhantomHIDModifiersIfNeeded(
        additionalOwnedModifiers: CGEventFlags = []
    ) -> [CGKeyCode] {
        guard !AppLogger.isTestProcess(), isAccessibilityTrusted else { return [] }
        let owned = currentSyntheticOwnedModifiers().union(additionalOwnedModifiers)
        let rawFlags = CGEventSource.flagsState(.hidSystemState)
        let heldKeys = KeyboardHardwareModifierPolicy.currentHeldModifierKeys()
        let stuckKeys = KeyboardHardwareModifierPolicy.phantomStuckModifierKeys(
            rawFlags: rawFlags,
            heldKeys: heldKeys,
            ownedModifiers: owned
        )
        guard !stuckKeys.isEmpty else { return [] }
        return clearPhantomHIDModifierKeys(stuckKeys, rawFlags: rawFlags)
    }

    @discardableResult
    private static func clearPhantomHIDModifierKeys(
        _ keys: [CGKeyCode],
        rawFlags: CGEventFlags
    ) -> [CGKeyCode] {
        guard !keys.isEmpty, let source = markedKeySource else { return [] }
        let genuineFlags = restoredFlagsForPhantomClear()
        var cleared: [CGKeyCode] = []
        for code in keys {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
                continue
            }
            event.type = .flagsChanged
            event.flags = genuineFlags
            event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
            event.post(tap: .cghidEventTap)
            cleared.append(code)
        }
        if !cleared.isEmpty {
            AppLogger.shared.write(
                "PHANTOM MODIFIER CLEARED keys=\(cleared.map(String.init).joined(separator: ",")) " +
                    "raw_flags=\(rawFlags.rawValue) restored_flags=\(genuineFlags.rawValue)"
            )
        }
        return cleared
    }

    static func postKey(code: CGKeyCode, flags: CGEventFlags = []) {
        _ = clearPhantomHIDModifiersIfNeeded()
        if !flags.isEmpty {
            _ = ShortcutEventSequence.send(keyCode: code, modifiers: flags,
                hardwareFlags: KeyboardHardwareModifierPolicy.currentForMappedAction, eventPoster: ShortcutEventSequence.post)
            return
        }
        guard let down = makeMappedKeyEvent(code: code, isDown: true, flags: flags),
              let up = makeMappedKeyEvent(code: code, isDown: false, flags: flags)
        else { return }
        AppLogger.shared.write(
            "MAPPED KEY EVENT key_code=\(code) edge=down " +
                "modifier_flags=\(down.flags.rawValue) result=submitted target_response=unknown"
        )
        down.post(tap: .cghidEventTap)
        up.flags = KeyboardHardwareModifierPolicy.sanitizedEventFlags(
            flags.union(KeyboardHardwareModifierPolicy.currentForMappedAction())
        )
        AppLogger.shared.write(
            "MAPPED KEY EVENT key_code=\(code) edge=up " +
                "modifier_flags=\(up.flags.rawValue) result=submitted target_response=unknown"
        )
        up.post(tap: .cghidEventTap)
    }

    static func postKeyState(
        code: CGKeyCode,
        isDown: Bool,
        flags: CGEventFlags
    ) -> Bool {
        postOwnedKeyState(code: code, isDown: isDown, flags: flags, excludingOwnedModifiers: [])
    }

    static func postOwnedKeyState(
        code: CGKeyCode,
        isDown: Bool,
        flags: CGEventFlags,
        excludingOwnedModifiers: CGEventFlags
    ) -> Bool {
        guard let event = makeMappedKeyEvent(
            code: code,
            isDown: isDown,
            flags: flags,
            excludingOwnedModifiers: excludingOwnedModifiers
        ) else { return false }
        AppLogger.shared.write(
            "MAPPED KEY EVENT key_code=\(code) edge=\(isDown ? "down" : "up") " +
                "modifier_flags=\(event.flags.rawValue) result=submitted target_response=unknown"
        )
        event.post(tap: .cghidEventTap)
        return true
    }

    static func postVoiceKeyState(code: CGKeyCode, isDown: Bool, flags: CGEventFlags) -> Bool {
        postMarkedKeyState(code: code, isDown: isDown, flags: flags, marker: orderedVoiceEventMarker)
    }

    static func postVoiceShortcutState(code: CGKeyCode, isDown: Bool, flags: CGEventFlags) -> Bool {
        postVoiceShortcutState(code: code, isDown: isDown, flags: flags,
            eventPoster: { location, event in event.post(tap: location) })
    }

    static func postVoiceShortcutState(
        code: CGKeyCode, isDown: Bool, flags: CGEventFlags,
        eventPoster: (CGEventTapLocation, CGEvent) -> Void
    ) -> Bool {
        // HeldVoiceShortcut already composes the complete physical + owned flags.
        // Do not read them again here: HID posting can leave a synthetic modifier
        // in the snapshot, which would reassert it during its release.
        guard let event = makeMarkedKeyEvent(code: code, isDown: isDown, flags: flags,
            marker: orderedVoiceEventMarker, hardwareFlags: { [] })
        else { return false }
        // Match standalone voice keys: an input tool's HID tap runs before the
        // session entry point and cannot observe events posted only at that point.
        eventPoster(.cghidEventTap, event)
        AppLogger.shared.write("VOICE SHORTCUT EVENT key_code=\(code) edge=\(isDown ? "down" : "up") " +
            "modifier_flags=\(event.flags.rawValue) tap=hid result=submitted target_response=unknown")
        return true
    }

    static func makeMappedKeyEvent(
        code: CGKeyCode, isDown: Bool, flags: CGEventFlags,
        excludingOwnedModifiers: CGEventFlags = [],
        hardwareFlags: () -> CGEventFlags = KeyboardHardwareModifierPolicy.current
    ) -> CGEvent? {
        // The remote's native Home carries Fn even without numeric-pad flags.
        // Only the configured shortcut may add Fn to a mapped event.
        makeMarkedKeyEvent(code: code, isDown: isDown, flags: flags,
            marker: syntheticEventMarker,
            excludingOwnedModifiers: excludingOwnedModifiers,
            hardwareFlags: { KeyboardHardwareModifierPolicy.mappedActionFlags(hardwareFlags()) })
    }

    static func keyEventType(code: CGKeyCode, isDown: Bool) -> CGEventType {
        switch code {
        case 54...63: return .flagsChanged
        default: return isDown ? .keyDown : .keyUp
        }
    }

    private nonisolated(unsafe) static let markedKeySource = CGEventSource(stateID: .privateState)

    static func makeMarkedKeyEvent(code: CGKeyCode, isDown: Bool, flags: CGEventFlags, marker: Int64,
                                   excludingOwnedModifiers: CGEventFlags = [],
                                   hardwareFlags: () -> CGEventFlags = KeyboardHardwareModifierPolicy.current) -> CGEvent? {
        guard let source = markedKeySource,
              let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: isDown)
        else { return nil }
        event.type = keyEventType(code: code, isDown: isDown)
        // Voice modifiers and session-owned modifiers must not re-inherit their own HID state on release.
        // Preserve other physical modifiers, including the opposite-side key.
        let observedFlags = KeyboardHardwareModifierPolicy.sanitizedEventFlags(hardwareFlags())
        let ownedModifiers = marker == orderedVoiceEventMarker
            ? ShortcutEventSequence.modifierFlags(for: code)
            : excludingOwnedModifiers
        let inheritedFlags: CGEventFlags
        if !ownedModifiers.isEmpty {
            inheritedFlags = ShortcutEventSequence.hardwareFlags(observedFlags,
                excludingOwned: ownedModifiers)
        } else {
            inheritedFlags = code == VoiceKeyMode.function.keyCode
                ? observedFlags.subtracting(.maskSecondaryFn) : observedFlags
        }
        event.flags = KeyboardHardwareModifierPolicy.sanitizedEventFlags(flags.union(inheritedFlags))
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        return event
    }

    private static func postMarkedKeyState(code: CGKeyCode, isDown: Bool,
                                          flags: CGEventFlags, marker: Int64) -> Bool {
        guard let event = makeMarkedKeyEvent(code: code, isDown: isDown, flags: flags, marker: marker)
        else { return false }
        AppLogger.shared.write(
            "VOICE KEY EVENT key_code=\(code) edge=\(isDown ? "down" : "up") " +
                "modifier_flags=\(event.flags.rawValue) result=submitted target_response=unknown"
        )
        event.post(tap: .cghidEventTap)
        return true
    }

    /// Scroll events are delivered to the window under the event location, not
    /// to the focused application, so a remote press must aim at the frontmost
    /// window instead of wherever the mouse happens to rest.
    static func scrollTargetLocation(
        windowFrame: CGRect?,
        mouseLocation: CGPoint
    ) -> CGPoint {
        guard let windowFrame,
              windowFrame.width > 0,
              windowFrame.height > 0
        else { return mouseLocation }
        return CGPoint(x: windowFrame.midX, y: windowFrame.midY)
    }

    /// Picks the largest ordinary window of the given process from a
    /// `CGWindowListCopyWindowInfo` snapshot.
    static func frontmostWindowFrame(
        windowInfo: [[String: Any]],
        processIdentifier: pid_t
    ) -> CGRect? {
        windowInfo
            .filter { entry in
                guard let owner = entry[kCGWindowOwnerPID as String] as? NSNumber,
                      owner.int32Value == processIdentifier,
                      let layer = entry[kCGWindowLayer as String] as? NSNumber,
                      layer.intValue == 0
                else { return false }
                return true
            }
            .compactMap { entry -> CGRect? in
                guard let bounds = entry[kCGWindowBounds as String] as? NSDictionary else {
                    return nil
                }
                return CGRect(dictionaryRepresentation: bounds as CFDictionary)
            }
            .filter { $0.width > 0 && $0.height > 0 }
            .max { $0.width * $0.height < $1.width * $1.height }
    }



    private static func frontmostWindowFrame() -> CGRect? {
        guard let processIdentifier = NSWorkspace.shared
            .frontmostApplication?
            .processIdentifier
        else { return nil }
        // Scroll delivery runs on the input/main run loop. Query WindowServer,
        // never the target application's AX server, which may be unresponsive.
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        return frontmostWindowFrame(
            windowInfo: windowInfo,
            processIdentifier: processIdentifier
        )
    }

    private static func currentMouseLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    /// Positive `lines` scrolls the content toward the beginning of the
    /// conversation, so the up key shows earlier messages.
    static func postScrollWheel(lines: Int32) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(
                  scrollWheelEvent2Source: source,
                  units: .line,
                  wheelCount: 1,
                  wheel1: lines,
                  wheel2: 0,
                  wheel3: 0
              )
        else { return }
        event.location = scrollTargetLocation(
            windowFrame: frontmostWindowFrame(),
            mouseLocation: currentMouseLocation()
        )
        event.flags = KeyboardHardwareModifierPolicy.currentForMappedAction()
        event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        event.post(tap: .cghidEventTap)
    }

    static func postSystemKey(type: Int32) {
        postSystemKey(type: type, isDown: true)
        postSystemKey(type: type, isDown: false)
    }

    static func postSystemKey(type: Int32, isDown: Bool) {
        let keyState = isDown ? 0xA : 0xB
        let data1 = Int((type << 16) | Int32(keyState << 8))
        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        ) else { return }
        guard let cgEvent = event.cgEvent else { return }
        cgEvent.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        cgEvent.post(tap: CGEventTapLocation.cghidEventTap)
    }
}
