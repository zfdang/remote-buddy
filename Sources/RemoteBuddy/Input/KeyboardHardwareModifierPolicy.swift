import CoreGraphics

/// Navigation-key decoration is not evidence of an independently held Fn key.
enum KeyboardHardwareModifierPolicy {
    private static let commandSideBits = CGEventFlags(rawValue: 0x0008 | 0x0010)
    private static let deviceModifierBits: UInt64 = 0x207F
    private static let userModifierMask = CGEventFlags(rawValue:
        CGEventFlags.maskAlphaShift.rawValue |
        CGEventFlags.maskShift.rawValue |
        CGEventFlags.maskControl.rawValue |
        CGEventFlags.maskAlternate.rawValue |
        CGEventFlags.maskCommand.rawValue |
        CGEventFlags.maskHelp.rawValue |
        CGEventFlags.maskSecondaryFn.rawValue |
        deviceModifierBits
    )

    struct HardwareModifierFamily {
        let flag: CGEventFlags
        let leftKey: CGKeyCode
        let leftBit: CGEventFlags
        let rightKey: CGKeyCode
        let rightBit: CGEventFlags
    }

    static let modifierFamilies: [HardwareModifierFamily] = [
        HardwareModifierFamily(flag: .maskControl, leftKey: 59, leftBit: CGEventFlags(rawValue: 0x0001),
            rightKey: 62, rightBit: CGEventFlags(rawValue: 0x2000)),
        HardwareModifierFamily(flag: .maskAlternate, leftKey: 58, leftBit: CGEventFlags(rawValue: 0x0020),
            rightKey: 61, rightBit: CGEventFlags(rawValue: 0x0040)),
        HardwareModifierFamily(flag: .maskShift, leftKey: 56, leftBit: CGEventFlags(rawValue: 0x0002),
            rightKey: 60, rightBit: CGEventFlags(rawValue: 0x0004)),
        HardwareModifierFamily(flag: .maskCommand, leftKey: 55, leftBit: CGEventFlags(rawValue: 0x0008),
            rightKey: 54, rightBit: CGEventFlags(rawValue: 0x0010)),
    ]

    /// Retains only genuine keyboard modifier bits and side bits, stripping
    /// non-modifier internal bits like NX_NONCOALESCEDMASK (0x100) and 0x20000000.
    static func sanitizedEventFlags(_ flags: CGEventFlags) -> CGEventFlags {
        flags.intersection(userModifierMask)
    }

    /// Mapped actions inherit physical shortcut modifiers, but never implicit
    /// navigation decoration or internal non-modifier event flags. An explicitly configured Fn is added separately.
    static func mappedActionFlags(_ flags: CGEventFlags) -> CGEventFlags {
        sanitizedEventFlags(flags).subtracting([.maskSecondaryFn, .maskNumericPad])
    }

    /// Reconciles `.hidSystemState` modifier flags (`Control`, `Option`, `Shift`, `Command`)
    /// against physical key states while preserving `normalized` Fn and Caps Lock flags, so
    /// synthetic modifiers lingering after `cghidEventTap` shortcuts or third-party paste
    /// events (such as bare `.maskCommand` with stuck virtual key 55 and no device-side bit)
    /// never appear physically held.
    static func reconcilingPhysicalModifiers(
        _ flags: CGEventFlags,
        heldKeys: Set<CGKeyCode>,
        requireDeviceSideBits: Bool = false
    ) -> CGEventFlags {
        var result = sanitizedEventFlags(flags)
        for family in modifierFamilies {
            let leftHeld = heldKeys.contains(family.leftKey) &&
                (!requireDeviceSideBits || (result.contains(family.flag) && result.contains(family.leftBit)))
            let rightHeld = heldKeys.contains(family.rightKey) &&
                (!requireDeviceSideBits || (result.contains(family.flag) && result.contains(family.rightBit)))
            if !leftHeld { result.remove(family.leftBit) }
            if !rightHeld { result.remove(family.rightBit) }
            if !leftHeld && !rightHeld {
                result.remove(family.flag)
            } else {
                result.formUnion(family.flag)
            }
        }
        return result
    }

    /// Identifies virtual modifier keys left stuck in `.hidSystemState` by synthetic `CGEvent`
    /// callers (e.g. third-party `Cmd+V` paste leaving `keyState(55)=true` and bare `.maskCommand`
    /// without `0x0008`/`0x0010` hardware device-side bits).
    static func phantomStuckModifierKeys(
        rawFlags: CGEventFlags,
        heldKeys: Set<CGKeyCode>,
        ownedModifiers: CGEventFlags = []
    ) -> [CGKeyCode] {
        let sanitized = sanitizedEventFlags(rawFlags)
        var stuck: [CGKeyCode] = []
        for family in modifierFamilies {
            let familyMask = family.flag.union(family.leftBit).union(family.rightBit)
            if !ownedModifiers.intersection(familyMask).isEmpty {
                continue
            }
            let leftPhantom = heldKeys.contains(family.leftKey) && !sanitized.contains(family.leftBit)
            let rightPhantom = heldKeys.contains(family.rightKey) && !sanitized.contains(family.rightBit)
            if leftPhantom { stuck.append(family.leftKey) }
            if rightPhantom { stuck.append(family.rightKey) }
            if !leftPhantom && !rightPhantom,
               sanitized.contains(family.flag),
               sanitized.intersection([family.leftBit, family.rightBit]).isEmpty {
                stuck.append(family.leftKey)
            }
        }
        return stuck
    }

    static func currentHeldModifierKeys() -> Set<CGKeyCode> {
        var heldKeys: Set<CGKeyCode> = []
        for family in modifierFamilies {
            if CGEventSource.keyState(.hidSystemState, key: family.leftKey) { heldKeys.insert(family.leftKey) }
            if CGEventSource.keyState(.hidSystemState, key: family.rightKey) { heldKeys.insert(family.rightKey) }
        }
        return heldKeys
    }

    static func currentForMappedAction() -> CGEventFlags {
        mappedActionFlags(current())
    }

    /// Reconciles `.hidSystemState` modifier flags against physical key states so
    /// synthetic modifiers lingering after `cghidEventTap` voice shortcuts never look held.
    static func voiceShortcutNormalized(_ flags: CGEventFlags, heldKeys: Set<CGKeyCode>) -> CGEventFlags {
        mappedActionFlags(reconcilingPhysicalModifiers(flags, heldKeys: heldKeys))
    }

    static func currentForVoiceShortcut() -> CGEventFlags {
        mappedActionFlags(current())
    }

    static func normalized(_ flags: CGEventFlags, fnKeyDown: Bool,
                           combinedFlags: CGEventFlags, combinedFnKeyDown: Bool) -> CGEventFlags {
        if flags.contains(.maskNumericPad) {
            // Suppressed native navigation can leave both HID Fn flags and key 63
            // stale after key-up. Require session evidence before inheriting Fn.
            // Only reconcile navigation decoration; ordinary hardware modifiers
            // and Fn without that decoration remain authoritative.
            let sessionHasFn = combinedFlags.contains(.maskSecondaryFn) || combinedFnKeyDown
            return sessionHasFn ? flags.union(.maskSecondaryFn) : flags.subtracting(.maskSecondaryFn)
        }
        if flags.contains(.maskSecondaryFn),
           !fnKeyDown,
           !combinedFnKeyDown,
           !combinedFlags.contains(.maskSecondaryFn) {
            // Suppressed Home/End/PageUp/PageDown (keys 115/116/119/121) set HID
            // maskSecondaryFn without maskNumericPad and leave it stale after key-up.
            return flags.subtracting(.maskSecondaryFn)
        }
        return fnKeyDown ? flags.union(.maskSecondaryFn) : flags
    }

    /// Synthetic Command+Tab injection at `cghidEventTap` can leave bare `.maskCommand`
    /// in `.hidSystemState` on seized devices without device-side bits or held keys.
    static func appSwitcherNormalized(
        _ flags: CGEventFlags,
        leftCommandKeyDown: Bool,
        rightCommandKeyDown: Bool,
        fnKeyDown: Bool,
        combinedFlags: CGEventFlags,
        combinedFnKeyDown: Bool
    ) -> CGEventFlags {
        let base = mappedActionFlags(
            normalized(
                flags,
                fnKeyDown: fnKeyDown,
                combinedFlags: combinedFlags,
                combinedFnKeyDown: combinedFnKeyDown
            )
        )
        guard base.contains(.maskCommand) else { return base }
        let hasHardwareCommandEvidence = !base.intersection(commandSideBits).isEmpty ||
            leftCommandKeyDown || rightCommandKeyDown
        return hasHardwareCommandEvidence ? base : base.subtracting(.maskCommand)
    }

    static func current() -> CGEventFlags {
        let base = normalized(
            CGEventSource.flagsState(.hidSystemState),
            fnKeyDown: CGEventSource.keyState(.hidSystemState, key: 63),
            combinedFlags: CGEventSource.flagsState(.combinedSessionState),
            combinedFnKeyDown: CGEventSource.keyState(.combinedSessionState, key: 63)
        )
        return reconcilingPhysicalModifiers(
            base,
            heldKeys: currentHeldModifierKeys(),
            requireDeviceSideBits: true
        )
    }

    static func currentForAppSwitcher() -> CGEventFlags {
        appSwitcherNormalized(
            CGEventSource.flagsState(.hidSystemState),
            leftCommandKeyDown: CGEventSource.keyState(.hidSystemState, key: 55),
            rightCommandKeyDown: CGEventSource.keyState(.hidSystemState, key: 54),
            fnKeyDown: CGEventSource.keyState(.hidSystemState, key: 63),
            combinedFlags: CGEventSource.flagsState(.combinedSessionState),
            combinedFnKeyDown: CGEventSource.keyState(.combinedSessionState, key: 63)
        )
    }

    /// A fresh, read-only observation for intermittent paste failures. Queries
    /// are sequential, so these fields may differ from the flags that blocked paste.
    static func diagnosticSnapshot() -> String {
        let raw = CGEventSource.flagsState(.hidSystemState)
        let combined = CGEventSource.flagsState(.combinedSessionState)
        let fnDown = CGEventSource.keyState(.hidSystemState, key: 63)
        let combinedFnDown = CGEventSource.keyState(.combinedSessionState, key: 63)
        let heldModifierKeys = currentHeldModifierKeys()
        let effective = reconcilingPhysicalModifiers(
            normalized(raw, fnKeyDown: fnDown, combinedFlags: combined, combinedFnKeyDown: combinedFnDown),
            heldKeys: heldModifierKeys,
            requireDeviceSideBits: true
        )
        let modifierKeyList = heldModifierKeys.sorted().map(String.init).joined(separator: ",")
        let navigationKeys: [CGKeyCode] = [115, 116, 117, 119, 121, 123, 124, 125, 126]
        let held = navigationKeys.filter {
            CGEventSource.keyState(.hidSystemState, key: $0)
        }.map(String.init).joined(separator: ",")
        return "observed_raw_flags=\(raw.rawValue) observed_combined_flags=\(combined.rawValue) " +
            "observed_fn_key_down=\(fnDown) observed_combined_fn_key_down=\(combinedFnDown) " +
            "observed_modifier_keys=\(modifierKeyList.isEmpty ? "none" : modifierKeyList) " +
            "observed_effective_flags=\(effective.rawValue) " +
            "observed_navigation_keys=\(held.isEmpty ? "none" : held)"
    }
}
