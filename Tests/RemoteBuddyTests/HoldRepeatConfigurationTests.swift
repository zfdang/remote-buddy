import CoreGraphics
import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Configurable hold actions") @MainActor
struct HoldRepeatConfigurationTests {
    private final class Events {
        var triggers: [ButtonTrigger] = []
        var actions: [ButtonAction] = []
    }

    private func withSettings(_ body: (AppSettings) throws -> Void) throws {
        let defaults = EphemeralUserDefaults()
        try body(AppSettings(defaults: defaults))
    }

    private func monitor(_ settings: AppSettings, clock: ControlledTestScheduler, events: Events,
                         seized: Bool = true) -> HIDRemoteMonitor {
        let profile = UUID()
        let monitor = HIDRemoteMonitor(settings: settings, profileID: profile,
            scheduler: clock, runtimePermissions: { true }, nativeSuppressionAvailable: { true },
            actionPerformer: { _, trigger, configured in
                events.triggers.append(trigger)
                events.actions.append(configured.action)
                return true
            }, frontmostBundleIdentifier: { "test.editor" }, diagnosticLogger: { _ in })
        monitor.connectSimulatedDevice(fingerprint: "hold-test", profileID: profile, isSeized: seized)
        return monitor
    }

    private func press(_ button: RemoteButton, on monitor: HIDRemoteMonitor) {
        let usage = button.hidUsage
        monitor.handleSimulatedReport(reportID: 1, data: Data([UInt8(usage & 255), UInt8(usage >> 8)]))
    }

    private func release(_ monitor: HIDRemoteMonitor) {
        monitor.handleSimulatedReport(reportID: 1, data: Data([0, 0]))
    }

    @Test func navigationVolumeAndPowerShowRepeatAsTheirDefaultLongPressValue() throws {
        try withSettings { settings in
            for button in [RemoteButton.up, .down, .left, .right, .volumeUp, .volumeDown, .power] {
                #expect(settings.configuredBaseAction(for: button, trigger: .longPress).action == .repeatSingleClick)
            }
            #expect(settings.configuredAction(for: .back, trigger: .longPress).action == .disabled)
        }
    }

    @Test func defaultPowerRepeatsDeletionWhileBackSendsEscapeOnce() throws {
        try withSettings { settings in
            let clock = ControlledTestScheduler(), events = Events()
            let monitor = monitor(settings, clock: clock, events: events)
            defer { monitor.disconnectSimulatedDevice() }
            press(.power, on: monitor)
            clock.advance(to: 450)
            #expect(events.actions == Array(repeating: .deleteBackward, count: 4))
            release(monitor)
            clock.advance(to: 1_000)
            #expect(events.actions.count == 4)
            press(.back, on: monitor)
            clock.advance(to: 2_000)
            #expect(events.actions == Array(repeating: .deleteBackward, count: 4) + [.escape])
            release(monitor)
            #expect(events.actions.count == 5)
        }
    }

    @Test func openingURLDoesNotInheritDefaultHoldRepeat() throws {
        try withSettings { settings in
            settings.setBaseBinding(.init(action: .openURL, shortcut: nil, urlString: "https://example.com"),
                for: .up, trigger: .singleClick, profileID: nil)
            let clock = ControlledTestScheduler(), events = Events()
            let monitor = monitor(settings, clock: clock, events: events)
            defer { monitor.disconnectSimulatedDevice() }
            press(.up, on: monitor)
            clock.advance(to: 600)
            release(monitor)
            #expect(events.actions == [.openURL])
            #expect(settings.defaultAction(for: .up, trigger: .longPress) == .disabled)
        }
    }

    @Test(arguments: RemoteButton.xiaomiCases)
    func everyPhysicalButtonCanRepeatAndStopsOnRelease(button: RemoteButton) throws {
        try withSettings { settings in
            settings.setAction(.deleteBackward, for: button)
            settings.setAction(.repeatSingleClick, for: button, trigger: .longPress)
            let clock = ControlledTestScheduler(), events = Events()
            let monitor = monitor(settings, clock: clock, events: events)
            defer { monitor.disconnectSimulatedDevice() }
            press(button, on: monitor)
            #expect(events.actions == [.deleteBackward])
            clock.advance(to: 349)
            #expect(events.actions.count == 1)
            clock.advance(to: 450)
            #expect(events.actions == Array(repeating: .deleteBackward, count: 4))
            #expect(events.triggers.allSatisfy { $0 == .singleClick })
            release(monitor)
            clock.advance(to: 1_000)
            #expect(events.actions.count == 4)
        }
    }

    @Test func specialLongPressRunsOnceInsteadOfRepeatingTheSingleAction() throws {
        try withSettings { settings in
            settings.setAction(.escape, for: .up, trigger: .longPress)
            let clock = ControlledTestScheduler(), events = Events()
            let monitor = monitor(settings, clock: clock, events: events)
            defer { monitor.disconnectSimulatedDevice() }
            press(.up, on: monitor)
            clock.advance(to: 549)
            #expect(events.actions.isEmpty)
            clock.advance(to: 1_000)
            #expect(events.actions == [.escape])
            #expect(events.triggers == [.longPress])
            release(monitor)
            clock.advance(to: 2_000)
            #expect(events.actions == [.escape])
        }
    }

    @Test func clearingLongPressDisablesRepeatIncludingNativeArrowPassthrough() throws {
        try withSettings { settings in
            settings.setAction(.disabled, for: .left, trigger: .longPress)
            let clock = ControlledTestScheduler(), events = Events()
            let monitor = monitor(settings, clock: clock, events: events, seized: false)
            defer { monitor.disconnectSimulatedDevice() }
            press(.left, on: monitor)
            clock.advance(to: 1_000)
            #expect(events.actions == [.arrowLeft])
            release(monitor)
            clock.advance(to: 2_000)
            #expect(events.actions == [.arrowLeft])
        }
    }

    @Test func repeatCoexistsWithDoublePressWithoutEmittingExtraSinglesOnRelease() throws {
        try withSettings { settings in
            settings.setAction(.deleteBackward, for: .power)
            settings.setAction(.repeatSingleClick, for: .power, trigger: .longPress)
            settings.setAction(.escape, for: .power, trigger: .doubleClick)
            let clock = ControlledTestScheduler(), events = Events()
            let monitor = monitor(settings, clock: clock, events: events)
            defer { monitor.disconnectSimulatedDevice() }
            press(.power, on: monitor)
            clock.advance(to: 20)
            release(monitor)
            clock.advance(to: 100)
            press(.power, on: monitor)
            clock.advance(to: 120)
            release(monitor)
            clock.advance(to: 1_000)
            #expect(events.actions == [.escape])
            #expect(events.triggers == [.doubleClick])
            press(.power, on: monitor)
            clock.advance(to: 1_450)
            #expect(events.actions == [.escape, .deleteBackward, .deleteBackward, .deleteBackward])
            release(monitor)
            clock.advance(to: 2_000)
            #expect(events.actions.count == 4)
        }
    }

    @Test func changingTheHoldValueStopsAnActiveRepeatAndCanRepeatCustomShortcuts() throws {
        try withSettings { settings in
            settings.setAction(.customShortcut, for: .power)
            settings.setShortcut(.init(keyCode: 8, modifierFlags: .command, keyLabel: "C"), for: .power)
            settings.setAction(.repeatSingleClick, for: .power, trigger: .longPress)
            let clock = ControlledTestScheduler(), events = Events()
            let monitor = monitor(settings, clock: clock, events: events)
            defer { monitor.disconnectSimulatedDevice() }
            press(.power, on: monitor)
            clock.advance(to: 350)
            #expect(events.actions == [.customShortcut, .customShortcut])
            settings.setAction(.escape, for: .power, trigger: .longPress)
            clock.advance(to: 1_000)
            #expect(events.actions.count == 2)
        }
    }

    @Test func cancelledRepeatCannotFireAgainstANewerPressOfTheSameButton() throws {
        try withSettings { settings in
            settings.setAction(.repeatSingleClick, for: .power, trigger: .longPress)
            let clock = ControlledTestScheduler(), events = Events()
            let monitor = monitor(settings, clock: clock, events: events)
            defer { monitor.disconnectSimulatedDevice() }
            press(.power, on: monitor)
            let stale = try #require(clock.tasks.first { $0.delay == HIDRemoteTiming.repeatStartMilliseconds })
            release(monitor)
            press(.power, on: monitor)
            #expect(events.actions.count == 2)
            stale.fire(includingCancelled: true)
            #expect(events.actions.count == 2)
            clock.advance(to: 350)
            #expect(events.actions.count == 3)
            monitor.disconnectSimulatedDevice()
            clock.advance(to: 1_000)
            #expect(events.actions.count == 3)
        }
    }

    @Test func resetRestoresDefaultRepeatingHoldsOverInheritedActions() throws {
        try withSettings { settings in
            settings.setBaseBinding(.init(action: .escape, shortcut: nil),
                for: .volumeUp, trigger: .longPress, profileID: nil)
            let profile = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
            settings.selectRemoteProfile(profile)
            settings.resetBindings()
            #expect(settings.allowsHoldRepeat(for: .volumeUp))
        }
    }

    @Test func holdValuesPersistPerDeviceAndSurviveReset() throws {
        try withSettings { settings in
            let first = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
            let second = settings.registerBluetoothRemote(identifier: UUID(), model: .rc001)
            settings.selectRemoteProfile(first)
            settings.setBaseBinding(.init(action: .repeatSingleClick, shortcut: nil),
                for: .power, trigger: .longPress, profileID: first)
            settings.selectRemoteProfile(second)
            settings.setBaseBinding(.init(action: .escape, shortcut: nil),
                for: .power, trigger: .longPress, profileID: second)
            #expect(settings.allowsHoldRepeat(for: .power, profileID: first))
            #expect(!settings.allowsHoldRepeat(for: .power, profileID: second))
            let restored = AppSettings(defaults: settings.defaults)
            #expect(restored.allowsHoldRepeat(for: .power, profileID: first))
            #expect(restored.configuredAction(for: .power, trigger: .longPress, profileID: second).action == .escape)
            settings.selectRemoteProfile(first)
            settings.resetBindings()
            #expect(settings.allowsHoldRepeat(for: .power, profileID: first))
            #expect(settings.configuredAction(for: .power, trigger: .longPress, profileID: second).action == .escape)
        }
    }

    @Test func arrowsRecoveredFromBTLEServerLogAreInjectedInsteadOfPassedThrough() throws {
        try withSettings { settings in
            let clock = ControlledTestScheduler(), events = Events()
            let monitor = monitor(settings, clock: clock, events: events, seized: false)
            defer { monitor.disconnectSimulatedDevice() }
            // G9N9N Report 2 Consumer Control codes: left = 0x0044, right = 0x0045.
            monitor.handleSimulatedGoogleReport(
                reportID: 2, data: Data([0x44, 0x00]), source: "device", origin: .iohid
            )
            monitor.handleSimulatedGoogleReport(
                reportID: 2, data: Data([0x00, 0x00]), source: "device", origin: .iohid
            )
            clock.advance(to: 1_000)
            // macOS delivers the native arrow itself for IOHID reports.
            #expect(events.actions == [])

            // Reset between origins so the 150ms real-time deduplicator treats this as a distinct session.
            monitor.disconnectSimulatedDevice()
            monitor.connectSimulatedDevice(fingerprint: "hold-test-btle", profileID: monitor.profileID, isSeized: false)
            monitor.handleSimulatedGoogleReport(
                reportID: 2, data: Data([0x44, 0x00]), source: "btle_log", origin: .btleServerLog
            )
            monitor.handleSimulatedGoogleReport(
                reportID: 2, data: Data([0x00, 0x00]), source: "btle_log", origin: .btleServerLog
            )
            monitor.handleSimulatedGoogleReport(
                reportID: 2, data: Data([0x45, 0x00]), source: "btle_log", origin: .btleServerLog
            )
            monitor.handleSimulatedGoogleReport(
                reportID: 2, data: Data([0x00, 0x00]), source: "btle_log", origin: .btleServerLog
            )
            clock.advance(to: 2_000)
            // Log-recovered reports never reached macOS, so Remote Buddy must inject the arrows.
            #expect(events.actions == [.arrowLeft, .arrowRight])
        }
    }

    @Test func btleServerLogReportsNeverArmNativeEventSuppressorOnPressReleaseOrRecovery() throws {
        try withSettings { settings in
            let clock = ControlledTestScheduler(), events = Events()
            let suppressor = KeyboardEventSuppressor()
            let profile = UUID()
            let monitor = HIDRemoteMonitor(
                settings: settings,
                profileID: profile,
                eventSuppressor: suppressor,
                ownsEventSuppressor: false,
                scheduler: clock,
                runtimePermissions: { true },
                nativeSuppressionAvailable: { true },
                actionPerformer: { _, trigger, configured in
                    events.triggers.append(trigger)
                    events.actions.append(configured.action)
                    return true
                },
                frontmostBundleIdentifier: { "test.editor" },
                diagnosticLogger: { _ in }
            )
            monitor.connectSimulatedDevice(fingerprint: "btle-suppressor-test", profileID: profile, isSeized: false)
            defer { monitor.disconnectSimulatedDevice() }

            // G9N9N Report 2 Consumer Control code for OK = 0x0041 (OK defers singleClick until release due to default long-press).
            monitor.handleSimulatedGoogleReport(
                reportID: 2, data: Data([0x41, 0x00]), source: "btle_log", origin: .btleServerLog
            )
            let okKeyDown = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true))
            #expect(!suppressor.handle(type: .keyDown, event: okKeyDown))

            // Normal release from btle_log emits OK and must not arm up-edge suppression.
            monitor.handleSimulatedGoogleReport(
                reportID: 2, data: Data([0x00, 0x00]), source: "btle_log", origin: .btleServerLog
            )
            #expect(events.actions == [.returnKey])
            let okKeyUp = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: false))
            #expect(!suppressor.handle(type: .keyUp, event: okKeyUp))

            // Missing-release timeout recovery for a btle_log hold must also never arm suppression.
            monitor.handleSimulatedGoogleReport(
                reportID: 2, data: Data([0x41, 0x00]), source: "btle_log", origin: .btleServerLog
            )
            clock.advance(to: HIDRemoteTiming.missingReleaseTimeoutMilliseconds + 100)
            #expect(!suppressor.handle(type: .keyDown, event: okKeyDown))
            #expect(!suppressor.handle(type: .keyUp, event: okKeyUp))
        }
    }
}
