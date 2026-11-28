import CoreGraphics
import Testing
@testable import RemoteBuddy

@Suite("App switcher navigation modifiers")
struct AppSwitcherModifierTests {
    @Test(arguments: [UInt64(0x800100), 0xA00100])
    func nativeHomeFnDoesNotContaminateSwitcherOrCleanup(rawFlags: UInt64) throws {
        var events: [CGEvent] = []
        let session = KeyboardInjector.AppSwitcherSession(
            hardwareFlags: { CGEventFlags(rawValue: rawFlags) },
            keyStatePoster: { code, down, flags, excludingOwned in
                guard let event = KeyboardInjector.makeMappedKeyEvent(
                    code: code, isDown: down, flags: flags,
                    excludingOwnedModifiers: excludingOwned,
                    hardwareFlags: { CGEventFlags(rawValue: rawFlags) }
                ) else { return false }
                events.append(event)
                return true
            }
        )
        #expect(session.trigger())
        #expect(session.trigger())
        #expect(session.moveSelection(left: true))
        #expect(session.cancel())
        #expect(events.map { $0.getIntegerValueField(.keyboardEventKeycode) } ==
            [55, 48, 48, 48, 48, 123, 123, 53, 53, 55])
        for event in events {
            #expect(!event.flags.contains(.maskSecondaryFn))
            #expect(!event.flags.contains(.maskNumericPad))
            #expect(KeyboardInjector.isSyntheticEvent(event))
        }
        #expect(events.dropLast().allSatisfy { $0.flags.contains(.maskCommand) })
        #expect(events.last?.flags.contains(.maskCommand) == false)
    }

    @Test(arguments: [CGEventFlags.maskShift, .maskControl, .maskAlternate, .maskCommand])
    func physicalModifiersRemainHeldOnCommandRelease(modifier: CGEventFlags) throws {
        let event = try #require(KeyboardInjector.makeMappedKeyEvent(
            code: 55, isDown: false, flags: [],
            hardwareFlags: { CGEventFlags(rawValue: 0x800100).union(modifier) }
        ))
        #expect(event.flags.contains(modifier))
        #expect(!event.flags.contains(.maskSecondaryFn))
    }

    @Test(arguments: [
        UInt64(0x20100100), // Seized HID snapshot carrying bare synthetic Command
        0x100008            // Left Command flag without opposite-side Command
    ])
    func sessionOwnedCommandReleaseDropsSyntheticResidueAndPreservesOppositeCommand(staleRawFlags: UInt64) throws {
        var currentHardware = CGEventFlags(rawValue: 0x800100)
        var events: [CGEvent] = []
        let session = KeyboardInjector.AppSwitcherSession(
            hardwareFlags: { currentHardware },
            keyStatePoster: { code, down, flags, excludingOwned in
                guard let event = KeyboardInjector.makeMappedKeyEvent(
                    code: code, isDown: down, flags: flags,
                    excludingOwnedModifiers: excludingOwned,
                    hardwareFlags: { currentHardware }
                ) else { return false }
                events.append(event)
                return true
            }
        )
        #expect(session.trigger())
        currentHardware = CGEventFlags(rawValue: staleRawFlags)
        #expect(session.confirm(restoreMinimizedWindows: false))
        let release = try #require(events.last)
        #expect(release.getIntegerValueField(.keyboardEventKeycode) == 55)
        #expect(release.type == .flagsChanged)
        #expect(!release.flags.contains(.maskCommand))

        // Opposite-side physical Right Command remains held across session-owned Left Command release.
        currentHardware = CGEventFlags(rawValue: 0x800100)
        events.removeAll()
        #expect(session.trigger())
        currentHardware = [.maskCommand, CGEventFlags(rawValue: 0x0010)]
        #expect(session.confirm(restoreMinimizedWindows: false))
        let releaseWithRightCommand = try #require(events.last)
        #expect(releaseWithRightCommand.getIntegerValueField(.keyboardEventKeycode) == 55)
        #expect(releaseWithRightCommand.flags.contains(.maskCommand))
        #expect(releaseWithRightCommand.flags.contains(CGEventFlags(rawValue: 0x0010)))
    }

    @Test(arguments: [
        CGEventFlags.maskCommand,
        [.maskCommand, CGEventFlags(rawValue: 0x0008)],
        [.maskCommand, CGEventFlags(rawValue: 0x0010)]
    ])
    func sessionDoesNotOwnOrClearPhysicallyHeldCommand(heldCommand: CGEventFlags) throws {
        var events: [CGEvent] = []
        let session = KeyboardInjector.AppSwitcherSession(
            hardwareFlags: { heldCommand },
            keyStatePoster: { code, down, flags, excludingOwned in
                guard let event = KeyboardInjector.makeMappedKeyEvent(
                    code: code, isDown: down, flags: flags,
                    excludingOwnedModifiers: excludingOwned,
                    hardwareFlags: { heldCommand }
                ) else { return false }
                events.append(event)
                return true
            }
        )
        #expect(session.trigger())
        #expect(session.moveSelection(left: false))
        #expect(session.confirm())
        #expect(!session.isActive)
        #expect(events.map { $0.getIntegerValueField(.keyboardEventKeycode) } == [48, 48, 124, 124])
        #expect(events.allSatisfy { $0.flags.contains(.maskCommand) })
    }

    @Test func earlyReleaseOfBorrowedPhysicalCommandEndsSessionAndAvoidsStaleSyntheticCommand() throws {
        // 1. Releasing borrowed Command then calling cancel() ends cleanly with no Escape+Command post.
        var currentHardware: CGEventFlags = [.maskCommand, CGEventFlags(rawValue: 0x0008)]
        var events: [CGEvent] = []
        let cancelSession = KeyboardInjector.AppSwitcherSession(
            hardwareFlags: { currentHardware },
            keyStatePoster: { code, down, flags, excludingOwned in
                guard let event = KeyboardInjector.makeMappedKeyEvent(
                    code: code, isDown: down, flags: flags,
                    excludingOwnedModifiers: excludingOwned,
                    hardwareFlags: { currentHardware }
                ) else { return false }
                events.append(event)
                return true
            }
        )
        #expect(cancelSession.trigger())
        events.removeAll()
        currentHardware = []
        #expect(!cancelSession.moveSelection(left: false))
        #expect(events.isEmpty)
        #expect(!cancelSession.isActive)

        // Reset: release borrowed Command then immediately call cancel().
        currentHardware = [.maskCommand, CGEventFlags(rawValue: 0x0008)]
        #expect(cancelSession.trigger())
        events.removeAll()
        currentHardware = []
        #expect(cancelSession.cancel())
        #expect(events.isEmpty)
        #expect(!cancelSession.isActive)

        // 2. Releasing borrowed Command then calling trigger() acquires paired synthetic ownership.
        currentHardware = [.maskCommand, CGEventFlags(rawValue: 0x0008)]
        #expect(cancelSession.trigger())
        events.removeAll()
        currentHardware = []
        #expect(cancelSession.trigger())
        #expect(events.map { $0.getIntegerValueField(.keyboardEventKeycode) } == [55, 48, 48])
        currentHardware = CGEventFlags(rawValue: 0x20100100)
        #expect(cancelSession.confirm(restoreMinimizedWindows: false))
        let release = try #require(events.last)
        #expect(release.getIntegerValueField(.keyboardEventKeycode) == 55)
        #expect(!release.flags.contains(.maskCommand))
        #expect(!cancelSession.isActive)
    }

    @Test func appSwitcherPolicyIgnoresPollutedBareCommandWithoutHardwareEvidence() {
        let polluted = KeyboardHardwareModifierPolicy.appSwitcherNormalized(
            CGEventFlags(rawValue: 0x20100100),
            leftCommandKeyDown: false,
            rightCommandKeyDown: false,
            fnKeyDown: false,
            combinedFlags: [],
            combinedFnKeyDown: false
        )
        #expect(!polluted.contains(.maskCommand))

        let realLeftBit = KeyboardHardwareModifierPolicy.appSwitcherNormalized(
            [.maskCommand, CGEventFlags(rawValue: 0x0008)],
            leftCommandKeyDown: false,
            rightCommandKeyDown: false,
            fnKeyDown: false,
            combinedFlags: [],
            combinedFnKeyDown: false
        )
        #expect(realLeftBit.contains(.maskCommand))

        let realRightBit = KeyboardHardwareModifierPolicy.appSwitcherNormalized(
            [.maskCommand, CGEventFlags(rawValue: 0x0010)],
            leftCommandKeyDown: false,
            rightCommandKeyDown: false,
            fnKeyDown: false,
            combinedFlags: [],
            combinedFnKeyDown: false
        )
        #expect(realRightBit.contains(.maskCommand))

        let realKeyState = KeyboardHardwareModifierPolicy.appSwitcherNormalized(
            CGEventFlags(rawValue: 0x20100100),
            leftCommandKeyDown: true,
            rightCommandKeyDown: false,
            fnKeyDown: false,
            combinedFlags: [],
            combinedFnKeyDown: false
        )
        #expect(realKeyState.contains(.maskCommand))
    }

    @Test func voiceKeyPathStillPreservesFn() throws {
        let event = try #require(KeyboardInjector.makeMarkedKeyEvent(
            code: 63, isDown: true, flags: .maskSecondaryFn,
            marker: KeyboardInjector.orderedVoiceEventMarker,
            hardwareFlags: { [] }
        ))
        #expect(event.flags.contains(.maskSecondaryFn))
    }

    @Test(arguments: [CGKeyCode(36), 48, 51, 53, 55, 123, 124, 125, 126])
    func remappedPlainAndModifierKeysKeepTheirConfiguredCodes(code: CGKeyCode) throws {
        for down in [true, false] {
            let event = try #require(KeyboardInjector.makeMappedKeyEvent(
                code: code, isDown: down, flags: [],
                hardwareFlags: { CGEventFlags(rawValue: 0x800100) }
            ))
            #expect(event.getIntegerValueField(.keyboardEventKeycode) == Int64(code))
            #expect(!event.flags.contains(.maskSecondaryFn))
            #expect(!event.flags.contains(.maskNumericPad))
        }
    }

    @Test(arguments: [UInt64(0x800100), 0xA00100])
    func shortcutTransactionAddsFnOnlyWhenExplicitlyConfigured(rawFlags: UInt64) {
        for configuredFn in [false, true] {
            var events: [CGEvent] = []
            let requested: CGEventFlags = configuredFn ? [.maskCommand, .maskSecondaryFn] : .maskCommand
            #expect(ShortcutEventSequence.send(keyCode: 36, modifiers: requested,
                hardwareFlags: { CGEventFlags(rawValue: rawFlags) },
                eventPoster: { events.append($0); return true }, logger: { _ in }))
            let keyEvents = events.filter { $0.type == .keyDown || $0.type == .keyUp }
            #expect(keyEvents.count == 2)
            #expect(keyEvents.allSatisfy {
                $0.getIntegerValueField(.keyboardEventKeycode) == 36 &&
                    $0.flags.contains(.maskCommand) &&
                    $0.flags.contains(.maskSecondaryFn) == configuredFn &&
                    !$0.flags.contains(.maskNumericPad)
            })
            #expect(events.last?.flags.contains(.maskSecondaryFn) == false)
        }
    }

    @Test func standaloneConfiguredFnRemainsPresentAndIsReleased() throws {
        let down = try #require(KeyboardInjector.makeMappedKeyEvent(
            code: 63, isDown: true, flags: .maskSecondaryFn,
            hardwareFlags: { CGEventFlags(rawValue: 0x800100) }
        ))
        let up = try #require(KeyboardInjector.makeMappedKeyEvent(
            code: 63, isDown: false, flags: [],
            hardwareFlags: { CGEventFlags(rawValue: 0x800100) }
        ))
        #expect(down.flags.contains(.maskSecondaryFn))
        #expect(!up.flags.contains(.maskSecondaryFn))
    }

    @Test func mappedReturnAndShortcutsIgnoreStaleHIDModifiersWithoutPhysicalKeys() throws {
        // Exact polluted HID snapshots observed after third-party Cmd+V paste (0x2010_0000)
        // and synthetic Ctrl+Shift voice shortcuts (0x2006_0003) when no physical keys are held.
        for pollutedRaw in [UInt64(0x2010_0000), 0x2010_0108, 0x2006_0003, 0x2016_010B] {
            let reconciled = KeyboardHardwareModifierPolicy.reconcilingPhysicalModifiers(
                CGEventFlags(rawValue: pollutedRaw),
                heldKeys: []
            )
            #expect(reconciled == [])

            let returnDown = try #require(KeyboardInjector.makeMappedKeyEvent(
                code: 36,
                isDown: true,
                flags: [],
                hardwareFlags: { reconciled }
            ))
            let returnUp = try #require(KeyboardInjector.makeMappedKeyEvent(
                code: 36,
                isDown: false,
                flags: [],
                hardwareFlags: { reconciled }
            ))
            #expect(returnDown.flags == [])
            #expect(returnUp.flags == [])

            var shiftReturnEvents: [CGEvent] = []
            #expect(ShortcutEventSequence.send(
                keyCode: 36,
                modifiers: .maskShift,
                hardwareFlags: { reconciled },
                eventPoster: { shiftReturnEvents.append($0); return true },
                logger: { _ in }
            ))
            #expect(shiftReturnEvents.map { $0.getIntegerValueField(.keyboardEventKeycode) } == [56, 36, 36, 56])
            #expect(shiftReturnEvents.allSatisfy { !$0.flags.contains(.maskCommand) })
            #expect(shiftReturnEvents.allSatisfy { !$0.flags.contains(.maskControl) })

            var commandReturnEvents: [CGEvent] = []
            #expect(ShortcutEventSequence.send(
                keyCode: 36,
                modifiers: .maskCommand,
                hardwareFlags: { reconciled },
                eventPoster: { commandReturnEvents.append($0); return true },
                logger: { _ in }
            ))
            #expect(commandReturnEvents.map { $0.getIntegerValueField(.keyboardEventKeycode) } == [55, 36, 36, 55])
            #expect(commandReturnEvents.last?.flags.contains(.maskCommand) == false)
        }

        // Genuine Fn, Caps Lock, and physically held modifiers remain intact.
        let preserved = KeyboardHardwareModifierPolicy.reconcilingPhysicalModifiers(
            [.maskAlphaShift, .maskSecondaryFn, .maskCommand, .maskShift, CGEventFlags(rawValue: 0x0002)],
            heldKeys: [56],
            requireDeviceSideBits: true
        )
        #expect(preserved.contains(.maskAlphaShift))
        #expect(preserved.contains(.maskSecondaryFn))
        #expect(preserved.contains(.maskShift))
        #expect(!preserved.contains(.maskCommand))
    }

    @Test func phantomModifierWithoutDeviceSideBitIsRejectedAndDetectedEvenWhenKeyStateIsStuck() {
        // Exact state left by third-party synthetic Cmd+V paste (e.g. bageshuo/enigo):
        // hidFlags = 0x2010_0000 (bare .maskCommand without 0x0008/0x0010 side bits) AND keyState(55) = true.
        let phantomPasteFlags = CGEventFlags(rawValue: 0x2010_0000)
        let reconciled = KeyboardHardwareModifierPolicy.reconcilingPhysicalModifiers(
            phantomPasteFlags,
            heldKeys: [55],
            requireDeviceSideBits: true
        )
        #expect(reconciled == [])

        let stuckKeys = KeyboardHardwareModifierPolicy.phantomStuckModifierKeys(
            rawFlags: phantomPasteFlags,
            heldKeys: [55],
            ownedModifiers: []
        )
        #expect(stuckKeys == [55])

        // Owned synthetic sessions (AppSwitcher / HeldVoiceShortcut) are never treated as external phantoms.
        #expect(KeyboardHardwareModifierPolicy.phantomStuckModifierKeys(
            rawFlags: phantomPasteFlags,
            heldKeys: [55],
            ownedModifiers: .maskCommand
        ).isEmpty)

        // Genuine physical Left Command (0x0008 side bit + .maskCommand + key 55) is preserved and not flagged.
        let genuineLeftCommand = CGEventFlags(rawValue: 0x2010_0008)
        let genuineReconciled = KeyboardHardwareModifierPolicy.reconcilingPhysicalModifiers(
            genuineLeftCommand,
            heldKeys: [55],
            requireDeviceSideBits: true
        )
        #expect(genuineReconciled == [.maskCommand, CGEventFlags(rawValue: 0x0008)])
        #expect(KeyboardHardwareModifierPolicy.phantomStuckModifierKeys(
            rawFlags: genuineLeftCommand,
            heldKeys: [55],
            ownedModifiers: []
        ).isEmpty)

        // Post-voice sweep requires two consecutive observations to avoid racing mid-Cmd+V paste.
        var sweep = KeyboardInjector.PostVoicePhantomSweepState()
        #expect(sweep.advance(currentCandidates: [55]).isEmpty)
        #expect(sweep.advance(currentCandidates: [55]) == [55])
        #expect(sweep.advance(currentCandidates: []).isEmpty)
        #expect(sweep.advance(currentCandidates: [55]).isEmpty)
    }
}
