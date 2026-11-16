import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Host HID and settings isolation")
@MainActor
struct TestIsolationTests {
    @Test func recognizesSwiftTestingAndXCTestWithoutAProductionOverride() {
        #expect(RuntimeEnvironment.isRunningTests)
        #expect(RuntimeEnvironment.detectsTests(arguments: ["/usr/libexec/swift/pm/swiftpm-testing-helper"],
            environment: [:], processName: ""))
        #expect(RuntimeEnvironment.detectsTests(arguments: [], environment: [:], processName: "swiftpm-testing-helper"))
        #expect(RuntimeEnvironment.detectsTests(arguments: ["Tests.xctest"], environment: [:], processName: ""))
        #expect(RuntimeEnvironment.detectsTests(arguments: [], environment: ["XCTestSessionIdentifier": "test"], processName: ""))
        #expect(!RuntimeEnvironment.detectsTests(arguments: ["RemoteBuddy"], environment: [:], processName: "RemoteBuddy"))
    }

    @Test func defaultModelAndMapperCannotFindHostDevicesOrShareAppDefaults() {
        let model = BridgeAppModel()
        #expect(model.settings.defaults !== UserDefaults.standard)
        #expect(!model.voiceFunctionMapper.apply(suppressPowerKey: true, neutralizeVoiceKey: false))
        #expect(!model.voiceFunctionMapper.hasMatchingServices)
        model.voiceFunctionMapper.restore()
        // A new mapper must not inherit the app's journal or the first model's state.
        let mapper = RemoteHIDKeyMapper(recoveryDefaults: .standard)
        #expect(!mapper.apply(neutralizeVoiceKey: true))
        #expect(!mapper.hasMatchingServices)
    }

    @Test func defaultSettingsWritesAreIsolatedFromOtherInstances() {
        let first = AppSettings(defaults: .standard)
        let second = AppSettings()
        let key = "isolation-probe-" + UUID().uuidString
        first.defaults.set("test", forKey: key)
        #expect(first.defaults.string(forKey: key) == "test")
        #expect(second.defaults.object(forKey: key) == nil)
        #expect(UserDefaults.standard.object(forKey: key) == nil)
    }
}
