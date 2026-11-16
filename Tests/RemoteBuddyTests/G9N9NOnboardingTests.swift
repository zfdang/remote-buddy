import Foundation
import Testing
@testable import RemoteBuddy

@Suite("G9N9N setup button reports")
struct G9N9NOnboardingTests {
    @Test func singleButtonsSatisfySetupChecksWithoutBypassingVoiceOrPermissions() throws {
        var capabilities = OnboardingCapabilities(
            bluetoothGranted: true, inputMonitoringGranted: true,
            accessibilityGranted: true, remoteConnected: true
        )
        func allows(_ step: OnboardingStep, _ state: OnboardingCapabilities) -> Bool {
            OnboardingFlowPolicy.canContinue(from: step, voiceTool: .doubao,
                selectedDevice: .chromecastG9N9N, capabilities: state)
        }
        #expect(!allows(.remote, capabilities))

        // A single OK press satisfies the first button check.
        var observed = try #require(G9N9NProtocol.usages(reportID: 1,
            data: Data([1, 7, 0]), descriptor: G9N9NProtocol.indexedConsumerDescriptor))
        #expect(observed == [RemoteButton.ok.hidUsage])
        capabilities.remoteButtonObserved = !observed.isEmpty
        capabilities.testedRemoteButtonCount = observed.count
        #expect(allows(.remote, capabilities))
        #expect(!allows(.controls, capabilities))

        // Two further individual buttons satisfy the three-distinct-key gate.
        for index: UInt8 in [3, 11] {
            observed.formUnion(try #require(G9N9NProtocol.usages(reportID: 1,
                data: Data([1, index, 0]), descriptor: G9N9NProtocol.indexedConsumerDescriptor)))
        }
        capabilities.testedRemoteButtonCount = observed.count
        #expect(observed.count == 3)
        #expect(allows(.controls, capabilities))
        #expect(!allows(.voiceTest, capabilities))
        capabilities.accessibilityGranted = false
        #expect(!allows(.remote, capabilities))
        #expect(!allows(.controls, capabilities))
    }
}
