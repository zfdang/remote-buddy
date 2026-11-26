import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Native passthrough reset release") @MainActor
struct NativePassthroughResetTests {
    @Test(arguments: ["disconnect", "compatibilityReset", "stop"])
    func nativeArrowMustBeReleasedOnReset(path: String) throws {
        let name = "review-ten-" + UUID().uuidString
        let values = try #require(UserDefaults(suiteName: name))
        defer { values.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: values)
        settings.customMappingEnabled = true
        let profile = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        settings.selectRemoteProfile(profile)
        let clock = ControlledTestScheduler()
        var keyUps = 0
        let monitor = HIDRemoteMonitor(settings: settings, profileID: profile,
            scheduler: clock, runtimePermissions: { true }, nativeSuppressionAvailable: { true },
            actionPerformer: { _, _, _ in Issue.record("Must use native passthrough"); return true },
            frontmostBundleIdentifier: { "test.editor" }, diagnosticLogger: { _ in },
            appSwitcherKeyStatePoster: { code, down, _ in
                if code == 124 && !down { keyUps += 1 }; return true
            }, appSwitcherHardwareFlags: { [] })
        monitor.connectSimulatedDevice(fingerprint: "review-ten", profileID: profile, isSeized: false)
        let usage = RemoteButton.right.hidUsage
        monitor.handleSimulatedReport(reportID: 1, data: Data([UInt8(usage & 255), UInt8(usage >> 8)]))
        #expect(keyUps == 0)
        switch path {
        case "disconnect": monitor.disconnectSimulatedDevice()
        case "compatibilityReset": monitor.clearTransientInputState(emitEmptyActiveButtons: false)
        default: monitor.stop()
        }
        clock.advance(to: HIDRemoteTiming.maximumContinuousHoldMilliseconds + 1000)
        #expect(keyUps == 1, "Reset must release native Right before cancelling its recovery timer")
        monitor.disconnectSimulatedDevice()
    }

}
