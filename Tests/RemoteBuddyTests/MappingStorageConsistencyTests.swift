import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Mapping storage consistency") @MainActor
struct MappingStorageConsistencyTests {
    @Test func uiEditsAcrossProfilesAndReloadKeepEffectiveMappings() throws {
        let name = "review-thirteen-ui-" + UUID().uuidString
        let values = try #require(UserDefaults(suiteName: name))
        defer { values.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: values)
        let first = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        let second = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        settings.selectRemoteProfile(first)
        for trigger in ButtonTrigger.allCases {
            settings.setBaseBinding(.init(action: .commandCopy, shortcut: nil), for: .right, trigger: trigger, profileID: first)
            settings.setBaseBinding(.init(action: .escape, shortcut: nil), for: .left, trigger: trigger, profileID: first)
        }
        #expect(settings.buttonBindings[.right] == .commandCopy)
        settings.selectRemoteProfile(second)
        settings.setBaseBinding(.init(action: .commandPaste, shortcut: nil), for: .right, trigger: .singleClick, profileID: second)
        let restored = AppSettings(defaults: values)
        for trigger in ButtonTrigger.allCases {
            #expect(restored.configuredAction(for: .right, trigger: trigger, profileID: first).action == .commandCopy)
            #expect(restored.configuredAction(for: .left, trigger: trigger, profileID: first).action == .escape)
        }
        restored.selectRemoteProfile(first)
        restored.resetBindings()
        #expect(restored.action(for: .right, profileID: second) == .commandPaste)
        #expect(restored.action(for: .right) == .arrowRight)
        let final = AppSettings(defaults: values)
        #expect(final.action(for: .right) == .arrowRight)
        #expect(final.action(for: .right, profileID: second) == .commandPaste)
    }

    @Test func mixedSetterPathsReadTheLatestSavedValue() throws {
        let name = "review-thirteen-mixed-" + UUID().uuidString
        let values = try #require(UserDefaults(suiteName: name))
        defer { values.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: values)
        let profile = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        settings.selectRemoteProfile(profile)
        settings.setBaseBinding(.init(action: .commandCopy, shortcut: nil), for: .right, trigger: .singleClick, profileID: profile)
        settings.setAction(.commandPaste, for: .right)
        #expect(settings.buttonBindings[.right] == .commandPaste)
        #expect(settings.action(for: .right) == .commandPaste)
        #expect(AppSettings(defaults: values).action(for: .right) == .commandPaste)
    }
}
