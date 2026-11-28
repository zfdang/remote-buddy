import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Independent remote defaults")
@MainActor
struct RemoteMappingIndependenceTests {
    @Test func backgroundProfilesResolveMissingMediaDefaultsWithoutReplacingSavedActions() throws {
        let values = EphemeralUserDefaults()
        let settings = AppSettings(defaults: values)
        let xiaomi = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        let google = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        settings.selectRemoteProfile(xiaomi)
        let index = try #require(settings.remoteDeviceProfiles.firstIndex { $0.id == google })
        for button in [RemoteButton.youtube, .netflix, .input] {
            settings.remoteDeviceProfiles[index].mappings.buttonBindings.removeValue(forKey: button.rawValue)
        }
        let restored = AppSettings(defaults: values)
        #expect(restored.selectedRemoteProfileID == xiaomi)
        #expect(restored.action(for: .youtube, profileID: google) == .previousCommandLeft)
        #expect(restored.action(for: .netflix, profileID: google) == .nextCommandRight)
        #expect(restored.action(for: .input, profileID: google) == .playPause)
        restored.setBaseBinding(.init(action: .escape, shortcut: nil), for: .youtube,
            trigger: .singleClick, profileID: google)
        restored.setBaseBinding(.disabled, for: .input, trigger: .singleClick, profileID: google)
        let reloaded = AppSettings(defaults: values)
        #expect(reloaded.action(for: .youtube, profileID: google) == .escape)
        #expect(reloaded.action(for: .input, profileID: google) == .disabled)
        reloaded.selectRemoteProfile(google)
        #expect(reloaded.action(for: .netflix) == .nextCommandRight)
        #expect(reloaded.action(for: .youtube) == .escape)
        #expect(reloaded.action(for: .input) == .disabled)
    }

    @Test(arguments: [true, false])
    func identifyingAnUnknownGoogleRemoteFillsDefaultsAndPreservesEdits(selected: Bool) throws {
        let values = EphemeralUserDefaults()
        let settings = AppSettings(defaults: values)
        let xiaomi = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        let google = settings.registerBluetoothRemote(identifier: UUID(), model: .unknown)
        settings.selectRemoteProfile(google)
        settings.setAction(.disabled, for: .input)
        settings.setAction(.showDesktop, for: .home)
        settings.setAction(.commandCopy, for: .ok, trigger: .longPress)
        if !selected { settings.selectRemoteProfile(xiaomi) }

        settings.updateRemoteProfileModel(google, model: .chromecastVoiceRemote)
        #expect(settings.selectedRemoteProfileID == (selected ? google : xiaomi))
        #expect(settings.action(for: .youtube, profileID: google) == .previousCommandLeft)
        #expect(settings.action(for: .netflix, profileID: google) == .nextCommandRight)
        #expect(settings.action(for: .mute, profileID: google) == .volumeMute)
        #expect(settings.action(for: .input, profileID: google) == .disabled)
        #expect(settings.action(for: .home, profileID: google) == .showDesktop)
        #expect(settings.configuredAction(for: .ok, trigger: .longPress, profileID: google).action == .commandCopy)
        #expect(settings.action(for: .home, profileID: xiaomi) == .appSwitcher)
        if selected {
            #expect(settings.buttonBindings[.youtube] == .previousCommandLeft)
            #expect(settings.buttonBindings[.mute] == .volumeMute)
        }
        let restored = AppSettings(defaults: values)
        #expect(restored.action(for: .youtube, profileID: google) == .previousCommandLeft)
        #expect(restored.action(for: .netflix, profileID: google) == .nextCommandRight)
        #expect(restored.action(for: .input, profileID: google) == .disabled)
        restored.setBaseBinding(.init(action: .escape, shortcut: nil), for: .youtube,
            trigger: .singleClick, profileID: google)
        restored.updateRemoteProfileModel(google, model: .chromecastVoiceRemote)
        #expect(restored.action(for: .youtube, profileID: google) == .escape)
    }

    @Test func googleMediaDefaultsPersistCustomizeAndResetIndependently() throws {
        let values = EphemeralUserDefaults()
        let settings = AppSettings(defaults: values)
        let google = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        settings.selectRemoteProfile(google)
        #expect(settings.action(for: .youtube) == .previousCommandLeft)
        #expect(settings.action(for: .netflix) == .nextCommandRight)
        #expect(settings.action(for: .input) == .playPause)
        settings.setAction(.showDesktop, for: .youtube)
        let restored = AppSettings(defaults: values)
        restored.selectRemoteProfile(google)
        #expect(restored.action(for: .youtube) == .showDesktop)
        let second = restored.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        #expect(restored.action(for: .youtube, profileID: second) == .previousCommandLeft)
        restored.resetBindings()
        #expect(restored.action(for: .youtube) == .previousCommandLeft)
        #expect(restored.action(for: .netflix) == .nextCommandRight)
        #expect(restored.action(for: .input) == .playPause)
        #expect(AppSettings.defaultMappings(for: .rc003).parsedButtonBindings[.youtube] == nil)
    }

    @Test func newDevicesUseModelDefaultsAndKeepCustomizationsSeparate() throws {
        let values = EphemeralUserDefaults()
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
        let values = EphemeralUserDefaults()
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
