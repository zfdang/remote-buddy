import Foundation
import Testing
@testable import RemoteBuddy

@Suite("HID mapping readback and mismatch diagnostics")
struct HIDMappingVerificationTests {
    @Test(arguments: [RemoteHIDMappingFamily.xiaomi, .t1Remote])
    func acceptedButIgnoredWriteDoesNotClaimReadiness(family: RemoteHIDMappingFamily) {
        var logs: [String] = []
        let mapper = RemoteHIDKeyMapper(serviceProvider: {
            [.init(registryID: 123, locationID: 4, family: family,
                readMappings: { [] }, setMappings: { _ in true })]
        }, bootID: "test", logger: { logs.append($0) })
        #expect(!mapper.apply(suppressPowerKey: true, neutralizeVoiceKey: true))
        #expect(!mapper.isApplied)
        #expect(!mapper.isPowerKeySuppressed)
        #expect(!mapper.isVoiceKeyNeutralized)
        #expect(logs.contains { $0.contains("reason=readback_mismatch registry_id=123") })
    }

    @Test func aLaterServiceVerificationFailureRollsBackEarlierServices() {
        var first: [HIDUsageMapping] = []
        let mapper = RemoteHIDKeyMapper(serviceProvider: {
            [.init(registryID: 1, readMappings: { first }, setMappings: { first = $0; return true }),
             .init(registryID: 2, readMappings: { [] }, setMappings: { _ in true })]
        }, bootID: "test")
        #expect(!mapper.apply(suppressPowerKey: true, neutralizeVoiceKey: true))
        #expect(first.isEmpty)
        #expect(!mapper.isApplied)
    }

    @Test func failedRollbackKeepsTheOriginalMappingForRecovery() throws {
        let suite = "mapping-readback-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var mappings: [HIDUsageMapping] = []
        var writes = 0
        var allowRecovery = false
        let provider: RemoteHIDKeyMapper.ServiceProvider = {
            [.init(registryID: 7, readMappings: { mappings }, setMappings: { desired in
                writes += 1
                if allowRecovery { mappings = desired }
                else if writes == 1 { mappings = [RemoteHIDKeyMappingPolicy.remoteVoiceKey] }
                return true
            })]
        }
        let mapper = RemoteHIDKeyMapper(serviceProvider: provider, recoveryDefaults: defaults, bootID: "test")
        #expect(!mapper.apply(neutralizeVoiceKey: true))
        #expect(mappings == [RemoteHIDKeyMappingPolicy.remoteVoiceKey])
        allowRecovery = true
        let restarted = RemoteHIDKeyMapper(serviceProvider: provider, recoveryDefaults: defaults, bootID: "test")
        restarted.restore()
        #expect(mappings.isEmpty)
    }

    @Test func distinguishesOverwrittenMappingFromAReplacedService() {
        var mappings: [HIDUsageMapping] = []
        var registryID: UInt64 = 1
        var logs: [String] = []
        let mapper = RemoteHIDKeyMapper(serviceProvider: {
            [.init(registryID: registryID, readMappings: { Array(mappings.reversed()) },
                setMappings: { mappings = $0; return true })]
        }, bootID: "test", logger: { logs.append($0) })
        #expect(mapper.apply(suppressPowerKey: true, neutralizeVoiceKey: true))
        #expect(mapper.refreshAppliedMappingsValidity(expectedPowerKeySuppression: true, expectedVoiceKeyNeutralization: true))
        mappings = RemoteHIDKeyMappingPolicy.applying(to: mappings)
        #expect(!mapper.refreshAppliedMappingsValidity(expectedPowerKeySuppression: true, expectedVoiceKeyNeutralization: true))
        #expect(logs.contains { $0.contains("reason=voice_mapping_mismatch") && $0.contains("observed_destination=1095216660483") })
        #expect(mapper.apply(suppressPowerKey: true, neutralizeVoiceKey: true))
        registryID = 2
        #expect(!mapper.refreshAppliedMappingsValidity(expectedPowerKeySuppression: true, expectedVoiceKeyNeutralization: true))
        #expect(logs.contains { $0.contains("reason=service_added_or_replaced") && $0.contains("registry_id=2") })
    }
}
