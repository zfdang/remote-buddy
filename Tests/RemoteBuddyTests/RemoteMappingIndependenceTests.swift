import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Independent remote defaults")
@MainActor
struct RemoteMappingIndependenceTests {
    @Test func newDevicesUseModelDefaultsAndKeepCustomizationsSeparate() throws {
        let suite = "independent-remote-defaults-" + UUID().uuidString
        let values = try #require(UserDefaults(suiteName: suite))
        defer { values.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: values)
        let xiaomi = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        settings.selectRemoteProfile(xiaomi)
        settings.setBaseBinding(.init(action: .commandCopy, shortcut: nil), for: .ok,
            trigger: .longPress, profileID: xiaomi)
        settings.setAction(.showDesktop, for: .home)
        let google = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        #expect(settings.configuredAction(for: .ok, trigger: .longPress, profileID: google).action == .commandReturn)
        #expect(settings.action(for: .home, profileID: google) == .appSwitcher)
        settings.selectRemoteProfile(google)
        #expect(settings.configuredAction(for: .ok, trigger: .longPress).action == .commandReturn)
        settings.setBaseBinding(.init(action: .escape, shortcut: nil), for: .ok,
            trigger: .longPress, profileID: google)
        #expect(settings.configuredAction(for: .ok, trigger: .longPress, profileID: xiaomi).action == .commandCopy)
        let secondGoogle = settings.registerHIDRemote(fingerprint: "second-google", model: .chromecastVoiceRemote)
        let thirdGoogle = try #require(settings.registerHIDRemote(fingerprint: "third-google", model: .chromecastVoiceRemote))
        #expect(secondGoogle != thirdGoogle)
        #expect(settings.configuredAction(for: .ok, trigger: .longPress, profileID: thirdGoogle).action == .commandReturn)
        let restored = AppSettings(defaults: values)
        #expect(restored.configuredAction(for: .ok, trigger: .longPress, profileID: google).action == .escape)
        #expect(restored.configuredAction(for: .ok, trigger: .longPress, profileID: xiaomi).action == .commandCopy)
        restored.selectRemoteProfile(google)
        restored.resetBindings()
        #expect(restored.configuredAction(for: .ok, trigger: .longPress).action == .commandReturn)
        #expect(restored.configuredAction(for: .ok, trigger: .longPress, profileID: xiaomi).action == .commandCopy)
    }

    @Test func preDeviceBindingsDoNotOverrideNewDeviceDefaults() throws {
        let suite = "independent-unscoped-defaults-" + UUID().uuidString
        let values = try #require(UserDefaults(suiteName: suite))
        defer { values.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: values)
        settings.setBaseBinding(.init(action: .commandCopy, shortcut: nil), for: .ok,
            trigger: .longPress, profileID: nil)
        let device = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        #expect(settings.configuredAction(for: .ok, trigger: .longPress, profileID: device).action == .commandReturn)
        settings.selectRemoteProfile(device)
        #expect(settings.configuredAction(for: .ok, trigger: .longPress).action == .commandReturn)
        #expect(AppSettings.defaultMappings(for: .chromecastVoiceRemote).parsedButtonBindings.count == 14)
        #expect(AppSettings.defaultMappings(for: .t1Remote).parsedButtonBindings.count == 7)
        #expect(AppSettings.defaultMappings(for: .rc003).parsedButtonBindings.count == 12)
    }
}
