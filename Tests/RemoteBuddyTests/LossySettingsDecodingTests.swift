import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Lossy settings decoding")
@MainActor
struct LossySettingsDecodingTests {
    private func values() throws -> (UserDefaults, String) {
        let name = "lossy-settings-" + UUID().uuidString
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    /// Rewrites one stored profile in place, the way a newer build would have saved it.
    private func rewriteStoredProfile(
        at index: Int,
        in values: UserDefaults,
        _ change: (inout [String: Any]) -> Void
    ) throws -> Data {
        let stored = try #require(values.data(forKey: "remoteDeviceProfiles"))
        var profiles = try #require(try JSONSerialization.jsonObject(with: stored) as? [[String: Any]])
        change(&profiles[index])
        let rewritten = try JSONSerialization.data(withJSONObject: profiles)
        values.set(rewritten, forKey: "remoteDeviceProfiles")
        return rewritten
    }

    @Test func mappingsDropOnlyTheUnknownAction() throws {
        let json = """
        {"buttonBindings":{"home":"showDesktop","ok":"future_action"},"buttonShortcuts":{},
        "secondaryButtonBindings":{"ok":{"longPress":{"action":"future_action"},"doubleClick":{"action":"escape"}}}}
        """
        let log = LossyDecodingLog()
        let mappings = try JSONDecoder.lossy(log: log).decode(RemoteDeviceMappings.self, from: Data(json.utf8))
        #expect(mappings.parsedButtonBindings[.home] == .showDesktop)
        #expect(mappings.parsedButtonBindings[.ok] == nil)
        #expect(mappings.parsedSecondaryButtonBindings[.ok]?[.doubleClick]?.action == .escape)
        #expect(mappings.parsedSecondaryButtonBindings[.ok]?[.longPress] == nil)
        #expect(log.droppedPaths.count == 2)
        #expect(log.droppedPaths.contains(["buttonBindings", "ok"]))
        #expect(log.droppedPaths.contains(["secondaryButtonBindings", "ok", "longPress"]))
    }

    @Test func plainDecoderStillDecodesCleanMappings() throws {
        let original = RemoteDeviceMappings(
            buttonBindings: [.home: .showDesktop, .ok: .returnKey],
            buttonShortcuts: [:],
            buttonApplicationProfileIDs: [.menu: UUID()],
            secondaryButtonBindings: [.ok: [.longPress: .init(action: .commandReturn, shortcut: nil)]]
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(RemoteDeviceMappings.self, from: data) == original)
        let withoutApplications = RemoteDeviceMappings(
            buttonBindings: [.home: .showDesktop], buttonShortcuts: [:], secondaryButtonBindings: [:]
        )
        let encoded = try JSONEncoder().encode(withoutApplications)
        #expect(try JSONDecoder().decode(RemoteDeviceMappings.self, from: encoded) == withoutApplications)
    }

    @Test func profilesDropOnlyTheUnknownModelAndKeepRawBytes() throws {
        let (values, name) = try values()
        defer { values.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: values)
        settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        let rewritten = try rewriteStoredProfile(at: 0, in: values) { $0["model"] = "future_remote" }

        let reloaded = AppSettings(defaults: values)
        #expect(reloaded.remoteDeviceProfiles.count == 1)
        #expect(reloaded.remoteDeviceProfiles.first?.model == .chromecastVoiceRemote)
        #expect(reloaded.corruptedSettingKeys.contains("remoteDeviceProfiles"))
        #expect(values.data(forKey: "remoteDeviceProfiles.corrupt") == rewritten)
    }

    @Test func profileWithUnknownActionKeepsItsOtherMappings() throws {
        let (values, name) = try values()
        defer { values.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: values)
        settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        let google = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        settings.setBaseBinding(.init(action: .escape, shortcut: nil), for: .youtube,
            trigger: .singleClick, profileID: google)
        settings.setBaseBinding(.init(action: .showDesktop, shortcut: nil), for: .home,
            trigger: .singleClick, profileID: google)
        let index = try #require(settings.remoteDeviceProfiles.firstIndex { $0.id == google })
        _ = try rewriteStoredProfile(at: index, in: values) { profile in
            var mappings = profile["mappings"] as? [String: Any] ?? [:]
            var bindings = mappings["buttonBindings"] as? [String: Any] ?? [:]
            bindings["home"] = "future_action"
            mappings["buttonBindings"] = bindings
            profile["mappings"] = mappings
        }

        let reloaded = AppSettings(defaults: values)
        #expect(reloaded.remoteDeviceProfiles.contains { $0.id == google })
        #expect(reloaded.action(for: .youtube, profileID: google) == .escape)
        #expect(reloaded.action(for: .home, profileID: google) == .appSwitcher)
        #expect(reloaded.corruptedSettingKeys.contains("remoteDeviceProfiles"))
    }

    @Test func unknownButtonAndGestureKeysAreReportedButKept() throws {
        let json = """
        {"buttonBindings":{"home":"showDesktop","future_button":"escape"},"buttonShortcuts":{},
        "secondaryButtonBindings":{"ok":{"tripleClick":{"action":"escape"}},"future_button":{"longPress":{"action":"escape"}}}}
        """
        let log = LossyDecodingLog()
        let mappings = try JSONDecoder.lossy(log: log).decode(RemoteDeviceMappings.self, from: Data(json.utf8))
        #expect(mappings.buttonBindings["future_button"] == .escape)
        #expect(mappings.parsedButtonBindings[.home] == .showDesktop)
        #expect(log.droppedPaths.contains(["buttonBindings", "future_button"]))
        #expect(log.droppedPaths.contains(["secondaryButtonBindings", "ok", "tripleClick"]))
        #expect(log.droppedPaths.contains(["secondaryButtonBindings", "future_button"]))
        #expect(log.droppedPaths.count == 3)
    }

    @Test func profileWithUnknownButtonKeepsRawBytes() throws {
        let (values, name) = try values()
        defer { values.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: values)
        settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        let rewritten = try rewriteStoredProfile(at: 0, in: values) { profile in
            var mappings = profile["mappings"] as? [String: Any] ?? [:]
            var bindings = mappings["buttonBindings"] as? [String: Any] ?? [:]
            bindings["future_button"] = "escape"
            mappings["buttonBindings"] = bindings
            profile["mappings"] = mappings
        }

        let reloaded = AppSettings(defaults: values)
        #expect(reloaded.remoteDeviceProfiles.count == 1)
        #expect(reloaded.corruptedSettingKeys.contains("remoteDeviceProfiles"))
        #expect(values.data(forKey: "remoteDeviceProfiles.corrupt") == rewritten)
    }

    @Test func nullProfileEntryIsSkipped() throws {
        let (values, name) = try values()
        defer { values.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: values)
        settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        let stored = try #require(values.data(forKey: "remoteDeviceProfiles"))
        var profiles = try #require(try JSONSerialization.jsonObject(with: stored) as? [Any])
        profiles.insert(NSNull(), at: 0)
        values.set(try JSONSerialization.data(withJSONObject: profiles), forKey: "remoteDeviceProfiles")

        let reloaded = AppSettings(defaults: values)
        #expect(reloaded.remoteDeviceProfiles.map(\.model) == [.rc003])
        #expect(reloaded.corruptedSettingKeys.contains("remoteDeviceProfiles"))
    }

    @Test func cleanProfilesReportNothing() throws {
        let (values, name) = try values()
        defer { values.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: values)
        settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)

        let reloaded = AppSettings(defaults: values)
        #expect(reloaded.remoteDeviceProfiles.count == 2)
        #expect(reloaded.corruptedSettingKeys.isEmpty)
        #expect(values.data(forKey: "remoteDeviceProfiles.corrupt") == nil)
    }
}
