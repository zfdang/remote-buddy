import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Remote device disambiguation")
@MainActor
struct RemoteDeviceDisambiguationTests {
    private static let emptyMappings = RemoteDeviceMappings(
        buttonBindings: [:],
        buttonShortcuts: [:],
        secondaryButtonBindings: [:]
    )

    @Test func singleRemotePerModelKeepsPlainModelNameEvenWithHardwareShortID() {
        let chromecast = RemoteDeviceProfile(
            model: .chromecastVoiceRemote,
            hardwareShortID: "A43B",
            bluetoothIdentifier: UUID(),
            hidFingerprint: "deadbeef1234",
            mappings: Self.emptyMappings
        )
        let xiaomi = RemoteDeviceProfile(
            model: .rc003,
            hardwareShortID: "C812",
            bluetoothIdentifier: UUID(),
            hidFingerprint: "cafebabe5678",
            mappings: Self.emptyMappings
        )
        let profiles = [chromecast, xiaomi]

        #expect(
            RemoteDeviceNamePolicy.disambiguatedModelName(
                for: chromecast,
                among: profiles,
                baseModelName: "G9N9N"
            ) == "G9N9N"
        )
        #expect(
            RemoteDeviceNamePolicy.disambiguatedModelName(
                for: xiaomi,
                among: profiles,
                baseModelName: "Xiaomi Remote 2 Pro"
            ) == "Xiaomi Remote 2 Pro"
        )
    }

    @Test func multipleRemotesOfSameModelDisambiguateByPriorityAndHandleCollisions() {
        let first = RemoteDeviceProfile(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            model: .chromecastVoiceRemote,
            hardwareShortID: "a43b",
            bluetoothIdentifier: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
            hidFingerprint: "99990000aaaa",
            mappings: Self.emptyMappings
        )
        let second = RemoteDeviceProfile(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            model: .chromecastVoiceRemote,
            hardwareShortID: nil,
            bluetoothIdentifier: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!,
            hidFingerprint: "7f2e8c01abcd",
            mappings: Self.emptyMappings
        )
        let third = RemoteDeviceProfile(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            model: .chromecastVoiceRemote,
            hardwareShortID: nil,
            bluetoothIdentifier: UUID(uuidString: "CAFE1234-0000-0000-0000-000000000003")!,
            hidFingerprint: nil,
            mappings: Self.emptyMappings
        )
        let fourth = RemoteDeviceProfile(
            id: UUID(uuidString: "ABCD9999-0000-0000-0000-000000000004")!,
            model: .chromecastVoiceRemote,
            hardwareShortID: nil,
            bluetoothIdentifier: nil,
            hidFingerprint: nil,
            mappings: Self.emptyMappings
        )
        let all = [first, second, third, fourth]

        #expect(
            RemoteDeviceNamePolicy.disambiguatedModelName(
                for: first, among: all, baseModelName: "G9N9N"
            ) == "G9N9N #A43B"
        )
        #expect(
            RemoteDeviceNamePolicy.disambiguatedModelName(
                for: second, among: all, baseModelName: "G9N9N"
            ) == "G9N9N #7F2E"
        )
        #expect(
            RemoteDeviceNamePolicy.disambiguatedModelName(
                for: third, among: all, baseModelName: "G9N9N"
            ) == "G9N9N #CAFE"
        )
        #expect(
            RemoteDeviceNamePolicy.disambiguatedModelName(
                for: fourth, among: all, baseModelName: "G9N9N"
            ) == "G9N9N #ABCD"
        )

        // Two profiles with the same 4-char prefix resolve via 6-char prefix when distinct.
        let collideA = RemoteDeviceProfile(
            model: .rc001,
            hidFingerprint: "A1B2C3000001",
            mappings: Self.emptyMappings
        )
        let collideB = RemoteDeviceProfile(
            model: .rc001,
            hidFingerprint: "A1B2D4000002",
            mappings: Self.emptyMappings
        )
        let prefixCollision = [collideA, collideB]
        #expect(
            RemoteDeviceNamePolicy.disambiguatedModelName(
                for: collideA, among: prefixCollision, baseModelName: "Xiaomi"
            ) == "Xiaomi #A1B2C3"
        )
        #expect(
            RemoteDeviceNamePolicy.disambiguatedModelName(
                for: collideB, among: prefixCollision, baseModelName: "Xiaomi"
            ) == "Xiaomi #A1B2D4"
        )

        // Two profiles with identical hardwareShortID and no longer unique fallback get -1 / -2.
        let sameA = RemoteDeviceProfile(
            id: UUID(uuidString: "DEAD0000-0000-0000-0000-000000000001")!,
            model: .t1Remote,
            hardwareShortID: "00FF",
            mappings: Self.emptyMappings
        )
        let sameB = RemoteDeviceProfile(
            id: UUID(uuidString: "DEAD0000-0000-0000-0000-000000000002")!,
            model: .t1Remote,
            hardwareShortID: "00FF",
            mappings: Self.emptyMappings
        )
        #expect(
            RemoteDeviceNamePolicy.disambiguatedModelName(
                for: sameA, among: [sameA, sameB], baseModelName: "T1"
            ) != RemoteDeviceNamePolicy.disambiguatedModelName(
                for: sameB, among: [sameA, sameB], baseModelName: "T1"
            )
        )

        // Two groups with colliding 4-char hardwareShortIDs sharing a 6-char fallback prefix
        // must retain their MAC suffixes and remain unique across all same-model profiles.
        let macA1 = RemoteDeviceProfile(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            model: .chromecastVoiceRemote,
            hardwareShortID: "AABB",
            bluetoothIdentifier: UUID(uuidString: "12345600-0000-0000-0000-000000000001")!,
            hidFingerprint: "123456aaaaaa",
            mappings: Self.emptyMappings
        )
        let macA2 = RemoteDeviceProfile(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
            model: .chromecastVoiceRemote,
            hardwareShortID: "AABB",
            bluetoothIdentifier: UUID(uuidString: "AAAAAA00-0000-0000-0000-000000000002")!,
            mappings: Self.emptyMappings
        )
        let macC1 = RemoteDeviceProfile(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            model: .chromecastVoiceRemote,
            hardwareShortID: "CCDD",
            bluetoothIdentifier: UUID(uuidString: "12345600-0000-0000-0000-000000000003")!,
            hidFingerprint: "123456cccccc",
            mappings: Self.emptyMappings
        )
        let macC2 = RemoteDeviceProfile(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            model: .chromecastVoiceRemote,
            hardwareShortID: "CCDD",
            bluetoothIdentifier: UUID(uuidString: "CCCCCC00-0000-0000-0000-000000000004")!,
            mappings: Self.emptyMappings
        )
        let crossHardwareGroup = [macA1, macA2, macC1, macC2]
        let hardwareLabels = crossHardwareGroup.map {
            RemoteDeviceNamePolicy.disambiguatedModelName(
                for: $0, among: crossHardwareGroup, baseModelName: "G9N9N"
            )
        }
        #expect(hardwareLabels == [
            "G9N9N #AABB-1",
            "G9N9N #AABB-2",
            "G9N9N #CCDD-1",
            "G9N9N #CCDD-2",
        ])
        #expect(Set(hardwareLabels).count == 4)

        // Two non-hardware colliding groups whose 6-char fallbacks collide across groups
        // must also stay unique across all same-model profiles.
        let fallbackA1 = RemoteDeviceProfile(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
            model: .rc001,
            bluetoothIdentifier: UUID(uuidString: "12345600-0000-0000-0000-000000000001")!,
            hidFingerprint: "A1B2",
            mappings: Self.emptyMappings
        )
        let fallbackA2 = RemoteDeviceProfile(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000002")!,
            model: .rc001,
            bluetoothIdentifier: UUID(uuidString: "AAAAAA00-0000-0000-0000-000000000002")!,
            hidFingerprint: "A1B2",
            mappings: Self.emptyMappings
        )
        let fallbackC1 = RemoteDeviceProfile(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!,
            model: .rc001,
            bluetoothIdentifier: UUID(uuidString: "12345600-0000-0000-0000-000000000003")!,
            hidFingerprint: "C3D4",
            mappings: Self.emptyMappings
        )
        let fallbackC2 = RemoteDeviceProfile(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000002")!,
            model: .rc001,
            bluetoothIdentifier: UUID(uuidString: "CCCCCC00-0000-0000-0000-000000000004")!,
            hidFingerprint: "C3D4",
            mappings: Self.emptyMappings
        )
        let crossFallbackGroup = [fallbackA1, fallbackA2, fallbackC1, fallbackC2]
        let fallbackLabels = crossFallbackGroup.map {
            RemoteDeviceNamePolicy.disambiguatedModelName(
                for: $0, among: crossFallbackGroup, baseModelName: "Xiaomi"
            )
        }
        #expect(fallbackLabels == [
            "Xiaomi #A1B2-1",
            "Xiaomi #A1B2-2",
            "Xiaomi #C3D4-1",
            "Xiaomi #C3D4-2",
        ])
        #expect(Set(fallbackLabels).count == 4)
    }

    @Test func readsShortIDsFromBluetoothAddressesAndIgnoresAmbiguousFingerprints() {
        #expect(RemoteDeviceNameReader.addressShortID(from: "aa:bb:cc:dd:a4:3b") == "A43B")
        #expect(RemoteDeviceNameReader.addressShortID(from: "AA-BB-CC-DD-01-0F") == "010F")
        #expect(RemoteDeviceNameReader.addressShortID(from: "112233445566") == "5566")
        #expect(RemoteDeviceNameReader.addressShortID(from: "invalid") == nil)
        #expect(RemoteDeviceNameReader.addressShortID(from: nil) == nil)

        let mapped = RemoteDeviceNameReader.shortIDsByFingerprint(identities: [
            .init(fingerprint: "fp1", address: "aa:bb:cc:dd:12:34"),
            .init(fingerprint: "fp1", address: "AA-BB-CC-DD-12-34"),
            .init(fingerprint: "fp-conflict", address: "aa:bb:cc:dd:12:34"),
            .init(fingerprint: "fp-conflict", address: "aa:bb:cc:dd:56:78"),
            .init(fingerprint: "fp-missing", address: nil),
        ])
        #expect(mapped == ["fp1": "1234"])
    }

    @Test func hardwareShortIDPersistsAcrossReloadAndDecodesLegacyJSONCleanly() throws {
        let legacyJSON = Data("""
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "model": "chromecast_voice_remote",
          "customName": "",
          "mappings": {
            "buttonBindings": {},
            "buttonShortcuts": {},
            "secondaryButtonBindings": {}
          }
        }
        """.utf8)
        let decodedLegacy = try JSONDecoder().decode(RemoteDeviceProfile.self, from: legacyJSON)
        #expect(decodedLegacy.hardwareShortID == nil)

        let defaults = EphemeralUserDefaults()
        let settings = AppSettings(defaults: defaults)
        let firstID = try #require(
            settings.registerHIDRemote(fingerprint: "fp-first", model: .chromecastVoiceRemote)
        )
        let secondID = try #require(
            settings.registerHIDRemote(fingerprint: "c0ffee02abcd", model: .chromecastVoiceRemote)
        )
        let model = BridgeAppModel(settings: settings, initialAudioDevices: [])

        let updatedCount = model.applyObservedHardwareShortIDs([
            "fp-first": "a43b",
            "c0ffee02abcd": "invalid",
        ])
        #expect(updatedCount == 1)

        // Re-applying nil or invalid must not wipe previously captured hardwareShortID.
        #expect(!settings.updateRemoteProfileHardwareShortID(firstID, shortID: nil))
        #expect(!settings.updateRemoteProfileHardwareShortID(firstID, shortID: "zzzz"))

        let reloaded = AppSettings(defaults: defaults)
        let reloadedFirst = try #require(reloaded.remoteDeviceProfiles.first { $0.id == firstID })
        let reloadedSecond = try #require(reloaded.remoteDeviceProfiles.first { $0.id == secondID })
        #expect(reloadedFirst.hardwareShortID == "A43B")
        #expect(reloadedSecond.hardwareShortID == nil)

        #expect(
            RemoteDeviceNamePolicy.disambiguatedModelName(
                for: reloadedFirst,
                among: reloaded.remoteDeviceProfiles,
                baseModelName: "G9N9N"
            ) == "G9N9N #A43B"
        )
        #expect(
            RemoteDeviceNamePolicy.disambiguatedModelName(
                for: reloadedSecond,
                among: reloaded.remoteDeviceProfiles,
                baseModelName: "G9N9N"
            ) == "G9N9N #C0FF"
        )
    }

    @Test func observedSystemNamePersistsAcrossReloadIncludingFactoryNames() throws {
        let legacyJSON = Data("""
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "model": "chromecast_voice_remote",
          "customName": "",
          "mappings": {
            "buttonBindings": {},
            "buttonShortcuts": {},
            "secondaryButtonBindings": {}
          }
        }
        """.utf8)
        let decodedLegacy = try JSONDecoder().decode(RemoteDeviceProfile.self, from: legacyJSON)
        #expect(decodedLegacy.lastObservedSystemName == nil)

        let defaults = EphemeralUserDefaults()
        let settings = AppSettings(defaults: defaults)
        let profileID = settings.registerBluetoothRemote(
            identifier: UUID(),
            model: .chromecastVoiceRemote
        )

        #expect(settings.updateRemoteProfileSystemName(profileID, name: "Chromecast Remote"))
        let savedFactory = try #require(settings.remoteDeviceProfiles.first { $0.id == profileID })
        #expect(savedFactory.customName == "")
        #expect(savedFactory.lastObservedSystemName == "Chromecast Remote")

        #expect(!settings.updateRemoteProfileSystemName(profileID, name: "Chromecast Remote"))
        #expect(!settings.updateRemoteProfileSystemName(profileID, name: nil))
        #expect(!settings.updateRemoteProfileSystemName(profileID, name: "   "))

        let reloadedFactorySettings = AppSettings(defaults: defaults)
        let offlineModel = BridgeAppModel(settings: reloadedFactorySettings, initialAudioDevices: [])
        let reloadedFactory = try #require(
            reloadedFactorySettings.remoteDeviceProfiles.first { $0.id == profileID }
        )
        #expect(offlineModel.systemDeviceName(for: reloadedFactory) == "Chromecast Remote")

        #expect(settings.updateRemoteProfileSystemName(profileID, name: "Living Room Remote"))
        let savedCustom = try #require(settings.remoteDeviceProfiles.first { $0.id == profileID })
        #expect(savedCustom.customName == "Living Room Remote")
        #expect(savedCustom.lastObservedSystemName == "Living Room Remote")

        let reloadedCustomSettings = AppSettings(defaults: defaults)
        let offlineCustomModel = BridgeAppModel(settings: reloadedCustomSettings, initialAudioDevices: [])
        let reloadedCustom = try #require(
            reloadedCustomSettings.remoteDeviceProfiles.first { $0.id == profileID }
        )
        #expect(offlineCustomModel.systemDeviceName(for: reloadedCustom) == "Living Room Remote")

        #expect(settings.updateRemoteProfileSystemName(profileID, name: "Chromecast Remote"))
        let restoredFactory = try #require(settings.remoteDeviceProfiles.first { $0.id == profileID })
        #expect(restoredFactory.customName == "")
        #expect(restoredFactory.lastObservedSystemName == "Chromecast Remote")

        let reloadedRestoredSettings = AppSettings(defaults: defaults)
        let offlineRestoredModel = BridgeAppModel(settings: reloadedRestoredSettings, initialAudioDevices: [])
        let reloadedRestored = try #require(
            reloadedRestoredSettings.remoteDeviceProfiles.first { $0.id == profileID }
        )
        #expect(offlineRestoredModel.systemDeviceName(for: reloadedRestored) == "Chromecast Remote")
    }
}
