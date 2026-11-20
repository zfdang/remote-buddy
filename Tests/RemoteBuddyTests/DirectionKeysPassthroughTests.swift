import CoreGraphics
import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Direction keys direct passthrough") @MainActor
struct DirectionKeysPassthroughTests {
    @Test func directionalButtonIdentificationAndKeyCodes() {
        #expect(RemoteButton.up.isDirectional)
        #expect(RemoteButton.down.isDirectional)
        #expect(RemoteButton.left.isDirectional)
        #expect(RemoteButton.right.isDirectional)
        #expect(!RemoteButton.ok.isDirectional)
        #expect(!RemoteButton.power.isDirectional)
        #expect(!RemoteButton.back.isDirectional)

        #expect(RemoteButton.up.directionKeyCode == 126)
        #expect(RemoteButton.down.directionKeyCode == 125)
        #expect(RemoteButton.left.directionKeyCode == 123)
        #expect(RemoteButton.right.directionKeyCode == 124)
        #expect(RemoteButton.ok.directionKeyCode == nil)
    }

    @Test func pickerActionsRestrictsDirectPassthroughToDirectionKeysSingleClick() {
        // Directional button on singleClick: MUST include directPassthrough
        for button in RemoteButton.directionButtons {
            let actions = ButtonAction.pickerActions(
                installedBundleIdentifiers: [],
                current: .disabled,
                button: button,
                trigger: .singleClick
            )
            #expect(actions.contains(.directPassthrough))

            // On doubleClick or longPress: MUST NOT include directPassthrough
            let doubleClickActions = ButtonAction.pickerActions(
                installedBundleIdentifiers: [],
                current: .disabled,
                button: button,
                trigger: .doubleClick
            )
            #expect(!doubleClickActions.contains(.directPassthrough))

            let longPressActions = ButtonAction.pickerActions(
                installedBundleIdentifiers: [],
                current: .disabled,
                button: button,
                trigger: .longPress
            )
            #expect(!longPressActions.contains(.directPassthrough))
        }

        // Non-directional button on singleClick: MUST NOT include directPassthrough
        let nonDirectionalButtons: [RemoteButton] = [.ok, .back, .power, .volumeUp, .home, .menu, .tv]
        for button in nonDirectionalButtons {
            let actions = ButtonAction.pickerActions(
                installedBundleIdentifiers: [],
                current: .disabled,
                button: button,
                trigger: .singleClick
            )
            #expect(!actions.contains(.directPassthrough))
        }
    }

    @Test func configuredActionDisablesSecondaryTriggersWhenDirectPassthroughIsActive() throws {
        try withSettings { settings in
            let profile = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
            settings.selectRemoteProfile(profile)

            // Configure .right to directPassthrough on singleClick
            settings.setAction(.directPassthrough, for: .right, trigger: .singleClick)
            // Even if doubleClick and longPress had values, configuredAction returns .disabled
            settings.setAction(.escape, for: .right, trigger: .doubleClick)
            settings.setAction(.repeatSingleClick, for: .right, trigger: .longPress)

            #expect(settings.configuredAction(for: .right, trigger: .singleClick).action == .directPassthrough)
            #expect(settings.configuredAction(for: .right, trigger: .doubleClick).action == .disabled)
            #expect(settings.configuredAction(for: .right, trigger: .longPress).action == .disabled)

            // If configured on a non-directional button, configuredAction treats it as disabled
            settings.setAction(.directPassthrough, for: .ok, trigger: .singleClick)
            #expect(settings.configuredAction(for: .ok, trigger: .singleClick).action == .disabled)
        }
    }

    @Test(arguments: [false, true])
    func directPassthroughDispatchesKeyDownAndKeyUpWithoutRepeatPulses(isSeized: Bool) throws {
        try withSettings { settings in
            settings.customMappingEnabled = true
            let profile = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
            settings.selectRemoteProfile(profile)
            settings.setAction(.directPassthrough, for: .right, trigger: .singleClick)

            let clock = ControlledTestScheduler()
            var events: [(code: CGKeyCode, down: Bool)] = []
            var actionPerformerCalled = false

            let monitor = HIDRemoteMonitor(
                settings: settings,
                profileID: profile,
                scheduler: clock,
                runtimePermissions: { true },
                nativeSuppressionAvailable: { true },
                actionPerformer: { _, _, _ in
                    actionPerformerCalled = true
                    return true
                },
                frontmostBundleIdentifier: { "test.player" },
                diagnosticLogger: { _ in },
                appSwitcherKeyStatePoster: { code, down, _ in
                    events.append((code, down))
                    return true
                },
                appSwitcherHardwareFlags: { [] }
            )
            monitor.connectSimulatedDevice(fingerprint: "sim-passthrough", profileID: profile, isSeized: isSeized)

            let usage = RemoteButton.right.hidUsage
            // 1. Press Right
            monitor.handleSimulatedReport(reportID: 1, data: Data([UInt8(usage & 255), UInt8(usage >> 8)]))
            #expect(events.count == 1)
            #expect(events.first?.code == 124)
            #expect(events.first?.down == true)
            #expect(!actionPerformerCalled)

            // 2. Advance clock past repeat interval (350ms + 500ms)
            clock.advance(to: 1000)
            // No repeat single clicks should have been dispatched!
            #expect(events.count == 1, "Direct passthrough must not generate discrete repeat pulses while held")
            #expect(!actionPerformerCalled)

            // 3. Release Right
            monitor.handleSimulatedReport(reportID: 1, data: Data([0, 0]))
            #expect(events.count == 2)
            #expect(events.last?.code == 124)
            #expect(events.last?.down == false)

            monitor.disconnectSimulatedDevice()
        }
    }

    @Test(arguments: ["disconnect", "cancelPending", "reset"])
    func watchdogReleasesHeldDirectPassthroughOnInterrupt(reason: String) throws {
        try withSettings { settings in
            settings.customMappingEnabled = true
            let profile = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
            settings.selectRemoteProfile(profile)
            settings.setAction(.directPassthrough, for: .left, trigger: .singleClick)

            let clock = ControlledTestScheduler()
            var events: [(code: CGKeyCode, down: Bool)] = []

            let monitor = HIDRemoteMonitor(
                settings: settings,
                profileID: profile,
                scheduler: clock,
                runtimePermissions: { true },
                nativeSuppressionAvailable: { true },
                actionPerformer: { _, _, _ in true },
                frontmostBundleIdentifier: { "test.app" },
                diagnosticLogger: { _ in },
                appSwitcherKeyStatePoster: { code, down, _ in
                    events.append((code, down))
                    return true
                },
                appSwitcherHardwareFlags: { [] }
            )
            monitor.connectSimulatedDevice(fingerprint: "sim-left", profileID: profile, isSeized: true)

            let usage = RemoteButton.left.hidUsage
            // Press Left (keyCode 123)
            monitor.handleSimulatedReport(reportID: 1, data: Data([UInt8(usage & 255), UInt8(usage >> 8)]))
            #expect(events.count == 1)
            #expect(events.first?.code == 123 && events.first?.down == true)

            // Interrupt while held
            switch reason {
            case "disconnect":
                monitor.disconnectSimulatedDevice()
            case "cancelPending":
                monitor.cancelPendingButtonActions()
            default:
                monitor.clearTransientInputState(emitEmptyActiveButtons: true)
            }

            #expect(events.count == 2)
            #expect(events.last?.code == 123 && events.last?.down == false, "Interruption must emit KeyUp to prevent stuck key")

            monitor.disconnectSimulatedDevice()
        }
    }

    @Test func commonPhrasesCapturesDirectionKeysInsteadOfDirectPassthrough() throws {
        try withSettings { settings in
            settings.customMappingEnabled = true
            let profile = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
            settings.selectRemoteProfile(profile)
            settings.setAction(.directPassthrough, for: .up, trigger: .singleClick)

            let clock = ControlledTestScheduler()
            var keyStateEvents: [(code: CGKeyCode, down: Bool)] = []
            var commonPhrasesHandled: [(button: RemoteButton, phase: RemoteButtonPhase)] = []

            let monitor = HIDRemoteMonitor(
                settings: settings,
                profileID: profile,
                scheduler: clock,
                runtimePermissions: { true },
                nativeSuppressionAvailable: { true },
                actionPerformer: { _, _, _ in true },
                frontmostBundleIdentifier: { "test.app" },
                diagnosticLogger: { _ in },
                appSwitcherKeyStatePoster: { code, down, _ in
                    keyStateEvents.append((code, down))
                    return true
                },
                appSwitcherHardwareFlags: { [] }
            )
            // Hook runtime button (Common Phrases simulation)
            var commonPhrasesOpen = true
            monitor.claimsRuntimeButton = { _, button in
                commonPhrasesOpen && button.isDirectional
            }
            monitor.onRuntimeButton = { _, button, phase in
                if commonPhrasesOpen && button.isDirectional {
                    commonPhrasesHandled.append((button, phase))
                    return true
                }
                return false
            }

            monitor.connectSimulatedDevice(fingerprint: "sim-common-phrase", profileID: profile, isSeized: true)

            let usage = RemoteButton.up.hidUsage
            // Press Up while Common Phrases is open
            monitor.handleSimulatedReport(reportID: 1, data: Data([UInt8(usage & 255), UInt8(usage >> 8)]))

            // Must NOT emit KeyDown to system
            #expect(keyStateEvents.isEmpty, "Common Phrases must intercept direction keys without emitting direct passthrough KeyDown")
            #expect(commonPhrasesHandled.count == 1)
            #expect(commonPhrasesHandled.first?.button == .up && commonPhrasesHandled.first?.phase == .press)

            // Release Up while Common Phrases is open
            monitor.handleSimulatedReport(reportID: 1, data: Data([0, 0]))
            #expect(keyStateEvents.isEmpty)
            #expect(commonPhrasesHandled.count == 2)
            #expect(commonPhrasesHandled.last?.button == .up && commonPhrasesHandled.last?.phase == .release)

            // Now close Common Phrases and press again
            commonPhrasesOpen = false
            monitor.handleSimulatedReport(reportID: 1, data: Data([UInt8(usage & 255), UInt8(usage >> 8)]))
            #expect(keyStateEvents.count == 1)
            #expect(keyStateEvents.first?.code == 126 && keyStateEvents.first?.down == true)

            monitor.handleSimulatedReport(reportID: 1, data: Data([0, 0]))
            #expect(keyStateEvents.count == 2)
            #expect(keyStateEvents.last?.code == 126 && keyStateEvents.last?.down == false)

            monitor.disconnectSimulatedDevice()
        }
    }

    private func withSettings(_ body: (AppSettings) throws -> Void) throws {
        let name = "direct-passthrough-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(AppSettings(defaults: defaults))
    }
}
