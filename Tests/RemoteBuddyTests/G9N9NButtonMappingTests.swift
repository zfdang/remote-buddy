import Foundation
import Testing
@testable import RemoteBuddy

@Suite("G9N9N configurable buttons")
@MainActor
struct G9N9NButtonMappingTests {
    @Test(arguments: [ButtonTrigger.doubleClick, .longPress])
    func configuredGesturesUseTheSharedMappingEngine(trigger: ButtonTrigger) throws {
        let suite = "g9n9n-gestures-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.onboardingStep = .complete
        settings.setAction(.escape, for: .ok, trigger: .doubleClick)
        settings.setAction(.deleteBackward, for: .ok, trigger: .longPress)
        let clock = ControlledTestScheduler()
        let profile = UUID()
        var performed: [ButtonTrigger] = []
        let monitor = HIDRemoteMonitor(settings: settings, profileID: profile, scheduler: clock,
            runtimePermissions: { true }, actionPerformer: { _, kind, _ in
                performed.append(kind); return true
            }, diagnosticLogger: { _ in })
        monitor.connectSimulatedDevice(fingerprint: "google", profileID: profile)
        defer { monitor.disconnectSimulatedDevice() }
        func report(_ pressed: Bool) {
            monitor.handleSimulatedGoogleReport(reportID: 1, data: Data([1,pressed ? 7 : 0,0]),
                descriptor: G9N9NProtocol.indexedConsumerDescriptor)
        }
        report(true)
        if trigger == .doubleClick {
            report(false)
            clock.advance(to: 100)
            report(true)
        } else {
            clock.advance(to: HIDRemoteTiming.longPressMilliseconds)
        }
        report(false)
        #expect(performed == [trigger])
    }

    @Test func allFourteenSingleButtonsHaveIndependentPressAndReleaseEdges() throws {
        let suite = "g9n9n-buttons-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.onboardingStep = .complete
        let profile = UUID()
        var active = Set<RemoteButton>()
        var actions: [RemoteButton] = []
        let monitor = HIDRemoteMonitor(settings: settings, profileID: profile,
            runtimePermissions: { true }, actionPerformer: { button, _, _ in
                actions.append(button); return true
            }, diagnosticLogger: { _ in })
        monitor.connectSimulatedDevice(fingerprint: "google", profileID: profile)
        defer { monitor.disconnectSimulatedDevice() }
        monitor.onActiveButtons = { _, buttons in active = buttons }
        let buttons: [(UInt8, RemoteButton)] = [(3,.up),(4,.down),(5,.left),(6,.right),
            (7,.ok),(11,.back),(10,.home),(8,.mute),(12,.volumeUp),(13,.volumeDown),
            (14,.youtube),(15,.netflix),(17,.input),(1,.power)]
        for (index, button) in buttons {
            settings.setAction(.escape, for: button, trigger: .singleClick)
            settings.setAction(.disabled, for: button, trigger: .doubleClick)
            settings.setAction(.disabled, for: button, trigger: .longPress)
            actions.removeAll()
            monitor.handleSimulatedGoogleReport(reportID: 1, data: Data([1,index,0]),
                descriptor: G9N9NProtocol.indexedConsumerDescriptor)
            #expect(active == [button])
            monitor.handleSimulatedGoogleReport(reportID: 1, data: Data([1,0,0]),
                descriptor: G9N9NProtocol.indexedConsumerDescriptor)
            #expect(active.isEmpty)
            #expect(actions == [button])
        }
    }

    @Test func simultaneousButtonsUseConfiguredActionsInsteadOfAFixedEnter() throws {
        let suite = "g9n9n-independent-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.onboardingStep = .complete
        settings.setAction(.escape, for: .ok)
        settings.setAction(.deleteBackward, for: .up)
        let profile = UUID()
        var actions: [ButtonAction] = []
        let monitor = HIDRemoteMonitor(settings: settings, profileID: profile,
            runtimePermissions: { true }, actionPerformer: { _, _, configured in
                actions.append(configured.action); return true
            }, diagnosticLogger: { _ in })
        monitor.connectSimulatedDevice(fingerprint: "google", profileID: profile)
        defer { monitor.disconnectSimulatedDevice() }
        monitor.handleSimulatedGoogleReport(reportID: 1, data: Data([1,7,3]),
            descriptor: G9N9NProtocol.indexedConsumerDescriptor)
        monitor.handleSimulatedGoogleReport(reportID: 1, data: Data([1,0,0]),
            descriptor: G9N9NProtocol.indexedConsumerDescriptor)
        #expect(Set(actions) == [.escape, .deleteBackward])
    }
}
