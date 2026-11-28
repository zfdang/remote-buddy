import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Remote profile initialization")
@MainActor
struct RemoteProfileInitializationTests {
    @Test func newInstallationHasNoInventedRemoteAndRegistrationPersists() throws {
        let defaults = EphemeralUserDefaults()
        let settings = AppSettings(defaults: defaults)
        #expect(settings.remoteDeviceProfiles.isEmpty)
        #expect(settings.selectedRemoteProfileID == nil)
        settings.setAction(.commandCopy, for: .right)
        let device = UUID()
        let profile = settings.registerBluetoothRemote(identifier: device)
        settings.selectRemoteProfile(profile)
        #expect(settings.remoteDeviceProfiles.count == 1)
        #expect(settings.action(for: .right) == .arrowRight)
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.remoteDeviceProfiles.count == 1)
        #expect(reloaded.selectedRemoteProfileID == profile)
        #expect(reloaded.profileID(forBluetoothIdentifier: device) == profile)
    }

    @Test func freshXiaomiMappingsPersistAcrossRegistrationAndReload() throws {
        let defaults = EphemeralUserDefaults()
        let settings = AppSettings(defaults: defaults)
        #expect(settings.action(for: .home) == .appSwitcher)
        #expect(settings.action(for: .tv) == .playPause)
        #expect(settings.configuredAction(for: .ok, trigger: .longPress).action == .commandReturn)
        settings.setAction(.commandCopy, for: .right)
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.configuredAction(for: .ok, trigger: .longPress).action == .commandReturn)
        let profile = reloaded.registerBluetoothRemote(identifier: UUID(), model: .rc001)
        reloaded.selectRemoteProfile(profile)
        let restored = AppSettings(defaults: defaults)
        #expect(restored.action(for: .home) == .appSwitcher)
        #expect(restored.action(for: .tv) == .playPause)
        #expect(restored.configuredAction(for: .ok, trigger: .longPress).action == .commandReturn)
    }

    @Test(arguments: [false, true])
    func savedXiaomiMappingsArePreserved(withProfile: Bool) throws {
        let defaults = EphemeralUserDefaults()
        var bindings = AppSettings.defaultBindings
        bindings[.home] = .showDesktop
        bindings[.tv] = .appSwitcher
        let mappings = RemoteDeviceMappings(buttonBindings: bindings, buttonShortcuts: [:],
                                             secondaryButtonBindings: [:])
        if withProfile {
            let profile = RemoteDeviceProfile(model: .rc001, bluetoothIdentifier: UUID(), mappings: mappings)
            defaults.set(try JSONEncoder().encode([profile]), forKey: AppSettings.Keys.remoteDeviceProfiles)
            defaults.set(profile.id.uuidString, forKey: AppSettings.Keys.selectedRemoteProfileID)
        } else {
            defaults.set(try JSONEncoder().encode(mappings.buttonBindings), forKey: AppSettings.Keys.buttonBindings)
        }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.action(for: .home) == .showDesktop)
        #expect(settings.action(for: .tv) == .appSwitcher)
        #expect(settings.configuredAction(for: .ok, trigger: .longPress).action == .disabled)
        settings.setAction(.commandCopy, for: .ok, trigger: .longPress)
        let restored = AppSettings(defaults: defaults)
        #expect(restored.action(for: .home) == .showDesktop)
        #expect(restored.action(for: .tv) == .appSwitcher)
        #expect(restored.configuredAction(for: .ok, trigger: .longPress).action == .commandCopy)
        restored.resetBindings()
        #expect(restored.action(for: .home) == .appSwitcher)
        #expect(restored.action(for: .tv) == .playPause)
        #expect(restored.configuredAction(for: .ok, trigger: .longPress).action == .commandReturn)
    }

    @Test func emptyOrCorruptProfileStorageDoesNotInventADevice() throws {
        for data in [Data("[]".utf8), Data("broken".utf8)] {
            let defaults = EphemeralUserDefaults()
            defaults.set(data, forKey: AppSettings.Keys.remoteDeviceProfiles)
            defaults.set(UUID().uuidString, forKey: AppSettings.Keys.selectedRemoteProfileID)
            let settings = AppSettings(defaults: defaults)
            #expect(settings.remoteDeviceProfiles.isEmpty)
            #expect(settings.selectedRemoteProfileID == nil)
        }
    }
}
