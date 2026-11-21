import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Settings backup")
@MainActor
struct SettingsBackupTests {
    private struct Fixture {
        let settings: AppSettings
        let values: UserDefaults
        let name: String
        let xiaomi: UUID
        let google: UUID

        func tearDown() { values.removePersistentDomain(forName: name) }
    }

    private func fixture() throws -> Fixture {
        let name = "settings-backup-" + UUID().uuidString
        let values = try #require(UserDefaults(suiteName: name))
        let settings = AppSettings(defaults: values)
        let xiaomi = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        let google = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        return Fixture(settings: settings, values: values, name: name, xiaomi: xiaomi, google: google)
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func exportContainsHeaderGeneralAndRemotes() throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        fixture.settings.addCustomApplicationProfile(.init(
            displayName: "Example", bundleIdentifier: "com.example.app", applicationPath: "/Applications/Example.app"))

        let object = try jsonObject(try fixture.settings.settingsBackupData(appVersion: "1.0"))
        #expect(object["format"] as? String == "remote-buddy-settings")
        #expect(object["formatVersion"] as? Int == 1)
        #expect((object["remotes"] as? [Any])?.count == 2)
        #expect((object["customApplications"] as? [Any])?.count == 1)
        let general = try #require(object["general"] as? [String: Any])
        #expect(general["showStatusBarIcon"] != nil)
    }

    @Test func exportLeavesOutPairingAndVoiceSettings() throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        fixture.settings.bindHIDFingerprint("fingerprint", to: fixture.xiaomi)

        let text = String(decoding: try fixture.settings.settingsBackupData(appVersion: "1.0"), as: UTF8.self)
        for key in ["bluetoothIdentifier", "hidFingerprint", "compatibleHIDBinding", "g9n9nInputMode",
                    "voiceKeyMode", "voiceFnTapModeEnabled"] {
            #expect(!text.contains(key), "export must not contain \(key)")
        }
    }

    private func remote(
        _ model: RemoteModel,
        name: String = "",
        gainDB: Double? = nil,
        _ change: (inout RemoteDeviceMappings) -> Void = { _ in }
    ) -> SettingsBackupDocument.Remote {
        var mappings = AppSettings.defaultMappings(for: model)
        change(&mappings)
        return .init(model: model, name: name, gainDB: gainDB, g9n9nVoiceButtonMode: nil, mappings: mappings)
    }

    private func backup(
        _ remotes: [SettingsBackupDocument.Remote],
        applications: [CustomApplicationProfile] = [],
        formatVersion: Int = SettingsBackupDocument.currentFormatVersion
    ) throws -> Data {
        var document = SettingsBackupDocument(
            exportedAt: Date(), appVersion: "test", general: .init(),
            customApplications: applications, remotes: remotes
        )
        document.formatVersion = formatVersion
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(document)
    }

    private func importBackup(
        _ data: Data,
        into settings: AppSettings,
        availableAppIcons: Set<AppIconIdentifier> = [.standard]
    ) throws -> SettingsBackupImportReport {
        try settings.importSettingsBackup(
            from: data,
            availableAppIcons: availableAppIcons,
            isApplicationInstalled: { _ in true }
        )
    }

    @Test func roundTripRestoresMappingsGainAndVoiceButtonMode() throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let settings = fixture.settings
        settings.selectRemoteProfile(fixture.xiaomi)
        settings.setAction(.showDesktop, for: .home)
        settings.setBaseBinding(.init(action: .escape, shortcut: nil), for: .youtube,
            trigger: .singleClick, profileID: fixture.google)
        settings.setGainDB(5, for: fixture.google)
        let exported = try settings.settingsBackupData(appVersion: "1.0")

        settings.setAction(.commandCopy, for: .home)
        settings.setBaseBinding(.init(action: .commandPaste, shortcut: nil), for: .youtube,
            trigger: .singleClick, profileID: fixture.google)
        settings.setGainDB(3, for: fixture.google)
        settings.setG9N9NVoiceButtonMode(.holdToTalk, for: fixture.google)

        let report = try importBackup(exported, into: settings)
        #expect(settings.action(for: .home) == .showDesktop)
        #expect(settings.action(for: .youtube, profileID: fixture.google) == .escape)
        #expect(settings.gainDB(for: fixture.google) == 5)
        #expect(settings.g9n9nVoiceButtonMode(for: fixture.google) == .smartToggle)
        #expect(report.isClean)
        #expect(report.importedRemoteCount == 2)
    }

    /// Edits the first remote of a backup the way a newer build or a person might have.
    private func rewritingFirstRemote(of data: Data, _ change: (inout [String: Any]) -> Void) throws -> Data {
        var object = try jsonObject(data)
        var remotes = try #require(object["remotes"] as? [[String: Any]])
        change(&remotes[0])
        object["remotes"] = remotes
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test func roundTripRestoresGeneralSettings() throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let settings = fixture.settings
        let integration = try #require(ApplicationIntegration.allCases.first)
        settings.applicationLanguage = .english
        settings.showDockIcon = true
        settings.openMainWindowAtLaunch = false
        settings.customMappingEnabled = true
        settings.enabledApplicationIntegrations.remove(integration.rawValue)
        let exported = try settings.settingsBackupData(appVersion: "1.0")

        settings.applicationLanguage = .simplifiedChinese
        settings.showDockIcon = false
        settings.openMainWindowAtLaunch = true
        settings.customMappingEnabled = false
        settings.enabledApplicationIntegrations.insert(integration.rawValue)

        let report = try importBackup(exported, into: settings)
        #expect(settings.applicationLanguage == .english)
        #expect(settings.showDockIcon)
        #expect(!settings.openMainWindowAtLaunch)
        #expect(settings.customMappingEnabled)
        #expect(!settings.enabledApplicationIntegrations.contains(integration.rawValue))
        #expect(report.isClean)
    }

    @Test func unknownGeneralValueIsReported() throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let data = Data(#"{"format":"remote-buddy-settings","formatVersion":1,"general":{"applicationLanguage":"tlh","showDockIcon":"yes"}}"#.utf8)
        let before = fixture.settings.applicationLanguage
        let report = try importBackup(data, into: fixture.settings)
        #expect(fixture.settings.applicationLanguage == before)
        #expect(report.skippedItems.contains(.init(location: ["general", "applicationLanguage"], reason: .unrecognizedValue)))
        #expect(report.skippedItems.contains(.init(location: ["general", "showDockIcon"], reason: .unrecognizedValue)))
    }

    @Test func unknownModelStringIsReportedByName() throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let data = try rewritingFirstRemote(of: try backup([remote(.t1Remote)])) { $0["model"] = "future_remote" }
        let report = try importBackup(data, into: fixture.settings)
        #expect(report.skippedItems == [.init(location: ["future_remote"], reason: .unrecognizedValue)])
    }

    @Test func unknownButtonInFileIsReported() throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let data = try backup([remote(.chromecastVoiceRemote) { $0.buttonBindings["future_button"] = .escape }])
        let report = try importBackup(data, into: fixture.settings)
        #expect(report.skippedItems.contains(
            .init(location: ["chromecast_voice_remote", "future_button"], reason: .unrecognizedValue)))
        #expect(!report.isClean)
    }

    @Test func outOfRangeGainIsReported() throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        fixture.settings.setGainDB(6, for: fixture.google)
        let report = try importBackup(try backup([remote(.chromecastVoiceRemote, gainDB: 99)]), into: fixture.settings)
        #expect(fixture.settings.gainDB(for: fixture.google) == 6)
        #expect(report.skippedItems.contains(
            .init(location: ["chromecast_voice_remote", "gainDB"], reason: .unrecognizedValue)))
    }

    @Test func secondaryGestureApplicationReferenceIsRemapped() throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let settings = fixture.settings
        let localID = settings.addCustomApplicationProfile(.init(
            displayName: "Example", bundleIdentifier: "com.example.app", applicationPath: "/Applications/Example.app"))
        let fileApplication = CustomApplicationProfile(
            displayName: "Example", bundleIdentifier: "com.example.app", applicationPath: "/Applications/Example.app")
        let data = try backup([remote(.chromecastVoiceRemote) {
            $0.secondaryButtonBindings["home"] = ["longPress": .init(
                action: .openCustomApplication, shortcut: nil, applicationProfileID: fileApplication.id)]
        }], applications: [fileApplication])

        let report = try importBackup(data, into: settings)
        let configured = settings.configuredBaseAction(for: .home, trigger: .longPress, profileID: fixture.google)
        #expect(configured.applicationProfileID == localID)
        #expect(report.isClean)
    }

    @Test func remoteModelMissingOnThisMacIsSkipped() throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let report = try importBackup(try backup([remote(.t1Remote)]), into: fixture.settings)
        #expect(report.skippedItems.contains(.init(location: ["t1_remote"], reason: .remoteModelNotOnThisMac)))
        #expect(report.importedRemoteCount == 0)
    }

    @Test func sameModelPicksMatchingNameThenFirst() throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let settings = fixture.settings
        settings.updateRemoteProfile(fixture.xiaomi, model: .rc003, customName: "B")
        let data = try backup([
            remote(.rc003, name: "A") { $0.buttonBindings["home"] = .showDesktop },
            remote(.rc003, name: "B") { $0.buttonBindings["home"] = .escape },
        ])
        _ = try importBackup(data, into: settings)
        #expect(settings.action(for: .home, profileID: fixture.xiaomi) == .escape)

        settings.updateRemoteProfile(fixture.xiaomi, model: .rc003, customName: "C")
        _ = try importBackup(data, into: settings)
        #expect(settings.action(for: .home, profileID: fixture.xiaomi) == .showDesktop)
    }

    @Test func everyLocalRemoteOfTheModelReceivesTheMapping() throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let settings = fixture.settings
        let second = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        #expect(second != fixture.google)
        let report = try importBackup(
            try backup([remote(.chromecastVoiceRemote) { $0.buttonBindings["home"] = .showDesktop }]),
            into: settings
        )
        #expect(settings.action(for: .home, profileID: fixture.google) == .showDesktop)
        #expect(settings.action(for: .home, profileID: second) == .showDesktop)
        #expect(report.importedRemoteCount == 2)
        #expect(report.sharedRemoteModels == [.chromecastVoiceRemote])
        #expect(!report.isClean)

        let localization = LocalizationStore(settings: settings)
        localization.select(.english)
        let summary = SettingsBackupMessage.summary(for: report, using: localization)
        #expect(summary.contains(localization.text(RemoteModel.chromecastVoiceRemote.localizationKey)))
    }

    @Test func unknownActionSkipsOnlyThatEntry() throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let data = try backup([remote(.chromecastVoiceRemote) { $0.buttonBindings["youtube"] = .escape }])
        var object = try jsonObject(data)
        var remotes = try #require(object["remotes"] as? [[String: Any]])
        var mappings = try #require(remotes[0]["mappings"] as? [String: Any])
        var bindings = try #require(mappings["buttonBindings"] as? [String: Any])
        bindings["home"] = "future_action"
        mappings["buttonBindings"] = bindings
        remotes[0]["mappings"] = mappings
        object["remotes"] = remotes

        let report = try importBackup(try JSONSerialization.data(withJSONObject: object), into: fixture.settings)
        #expect(fixture.settings.action(for: .youtube, profileID: fixture.google) == .escape)
        #expect(report.skippedItems.contains(
            .init(location: ["chromecast_voice_remote", "home"], reason: .unrecognizedValue)))
        #expect(report.importedRemoteCount == 1)
    }

    @Test func applicationReferencesAreRemappedToLocalIDsWithoutOverwritingLocalProfiles() throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let settings = fixture.settings
        let localTarget = AccessibilityFocusTarget(
            role: "AXTextArea",
            identifier: "local-composer",
            title: "Message",
            description: "",
            help: "",
            placeholder: "",
            context: "",
            windowTitle: "Main",
            normalizedFrame: nil
        )
        let localID = settings.addCustomApplicationProfile(.init(
            displayName: "Local Example",
            bundleIdentifier: "com.example.app",
            applicationPath: "/Applications/Local.app",
            focusStrategy: .recordedAccessibility,
            accessibilityTarget: localTarget
        ))
        let fileApplication = CustomApplicationProfile(
            displayName: "Backup Example",
            bundleIdentifier: "com.example.app",
            applicationPath: "/Applications/Backup.app",
            focusStrategy: .keyboardShortcut,
            focusShortcut: CustomKeyboardShortcut(keyCode: 49, modifierFlags: [.command], keyLabel: "Space")
        )
        let data = try backup([remote(.chromecastVoiceRemote) {
            $0.buttonBindings["home"] = .openCustomApplication
            $0.buttonApplicationProfileIDs = ["home": fileApplication.id]
        }], applications: [fileApplication])

        let report = try importBackup(data, into: settings)
        #expect(settings.customApplicationProfiles.count == 1)
        let preserved = try #require(settings.customApplicationProfiles.first)
        #expect(preserved.id == localID)
        #expect(preserved.displayName == "Local Example")
        #expect(preserved.applicationPath == "/Applications/Local.app")
        #expect(preserved.focusStrategy == .recordedAccessibility)
        #expect(preserved.accessibilityTarget == localTarget)
        #expect(preserved.focusShortcut == nil)
        #expect(settings.applicationProfileID(for: .home, profileID: fixture.google) == localID)
        #expect(report.isClean)
    }

    @Test func uninstalledApplicationIsImportedAndReported() throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let application = CustomApplicationProfile(
            displayName: "Missing", bundleIdentifier: "com.example.missing", applicationPath: "/Applications/Missing.app")
        let report = try fixture.settings.importSettingsBackup(
            from: try backup([], applications: [application]), isApplicationInstalled: { _ in false })
        #expect(fixture.settings.customApplicationProfiles.contains { $0.bundleIdentifier == "com.example.missing" })
        #expect(report.missingApplications == ["Missing"])
    }

    @Test func unknownApplicationReferenceIsDropped() throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let data = try backup([remote(.chromecastVoiceRemote) {
            $0.buttonBindings["home"] = .openCustomApplication
            $0.buttonApplicationProfileIDs = ["home": UUID()]
        }])
        let report = try importBackup(data, into: fixture.settings)
        #expect(fixture.settings.applicationProfileID(for: .home, profileID: fixture.google) == nil)
        #expect(fixture.settings.action(for: .home, profileID: fixture.google) == .appSwitcher)
        #expect(report.skippedItems.contains(
            .init(location: ["chromecast_voice_remote", "home"], reason: .unknownApplicationReference)))
    }

    @Test func wrongFormatThrowsAndChangesNothing() throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let settings = fixture.settings
        let profiles = settings.remoteDeviceProfiles
        let showDockIcon = settings.showDockIcon
        let data = Data(#"{"format":"other","formatVersion":1,"general":{"showDockIcon":true},"remotes":[]}"#.utf8)
        #expect(throws: SettingsBackupError.notASettingsFile) { try importBackup(data, into: settings) }
        #expect(throws: SettingsBackupError.notASettingsFile) {
            try importBackup(Data("not json".utf8), into: settings)
        }
        #expect(settings.remoteDeviceProfiles == profiles)
        #expect(settings.showDockIcon == showDockIcon)
    }

    @Test func oversizedFileIsRejected() throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let data = Data(count: AppSettings.maximumSettingsBackupBytes + 1)
        #expect(throws: SettingsBackupError.fileTooLarge) { try importBackup(data, into: fixture.settings) }
    }

    @Test func newerFormatVersionStillImports() throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let data = try backup([remote(.chromecastVoiceRemote) { $0.buttonBindings["home"] = .showDesktop }],
            formatVersion: 2)
        let report = try importBackup(data, into: fixture.settings)
        #expect(fixture.settings.action(for: .home, profileID: fixture.google) == .showDesktop)
        #expect(report.isFromNewerVersion)
    }

    @Test func importRefreshesSelectedRemoteLiveMappings() throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let settings = fixture.settings
        settings.selectRemoteProfile(fixture.google)
        _ = try importBackup(
            try backup([remote(.chromecastVoiceRemote) { $0.buttonBindings["home"] = .showDesktop }]),
            into: settings
        )
        #expect(settings.action(for: .home) == .showDesktop)
        #expect(AppSettings(defaults: fixture.values).action(for: .home) == .showDesktop)
    }

    @Test func compatibilityModeRemoteKeepsMappings() throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let settings = fixture.settings
        let index = try #require(settings.remoteDeviceProfiles.firstIndex { $0.id == fixture.google })
        settings.remoteDeviceProfiles[index].g9n9nInputMode = .twoKeyCompatibility
        let data = try backup([remote(.chromecastVoiceRemote, gainDB: 7) { $0.buttonBindings["home"] = .showDesktop }])

        let report = try importBackup(data, into: settings)
        #expect(settings.action(for: .home, profileID: fixture.google) == .appSwitcher)
        #expect(settings.gainDB(for: fixture.google) == 7)
        #expect(report.skippedItems.contains(
            .init(location: ["chromecast_voice_remote"], reason: .mappingLockedByCompatibilityMode)))
    }

    @Test func pairingDataIsUntouched() throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let settings = fixture.settings
        settings.bindHIDFingerprint("fingerprint", to: fixture.xiaomi)
        settings.updateRemoteProfile(fixture.google, model: .chromecastVoiceRemote, customName: "Living room")
        let before = settings.remoteDeviceProfiles.map { [$0.id.uuidString, $0.bluetoothIdentifier?.uuidString ?? "",
                                                          $0.hidFingerprint ?? "", $0.customName] }
        _ = try importBackup(try backup([remote(.rc003, name: "Other"), remote(.chromecastVoiceRemote, name: "Den")]),
            into: settings)
        let after = settings.remoteDeviceProfiles.map { [$0.id.uuidString, $0.bluetoothIdentifier?.uuidString ?? "",
                                                         $0.hidFingerprint ?? "", $0.customName] }
        #expect(after == before)
    }

    private static let backupStringKeys = [
        "settings.general.backup_group",
        "settings.backup.export.title", "settings.backup.export.help", "settings.backup.export.action",
        "settings.backup.export.failed",
        "settings.backup.import.title", "settings.backup.import.help", "settings.backup.import.action",
        "settings.backup.import.confirm_title", "settings.backup.import.confirm_message",
        "settings.backup.import.done", "settings.backup.import.skipped_header", "settings.backup.import.item",
        "settings.backup.import.reason.unrecognized_value", "settings.backup.import.reason.model_not_on_this_mac",
        "settings.backup.import.reason.unknown_application", "settings.backup.import.reason.compatibility_mode",
        "settings.backup.import.location.custom_applications", "settings.backup.import.shared_remotes",
        "settings.backup.import.missing_apps", "settings.backup.import.newer_version", "settings.backup.import.more",
        "settings.backup.import.not_settings_file", "settings.backup.import.too_large",
        "settings.backup.import.read_failed", "settings.backup.import.result_title", "settings.backup.error.title",
        "settings.partially_loaded.title", "settings.partially_loaded.detail",
    ]

    @Test func summaryListsSkippedItemsWithReasons() throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let localization = LocalizationStore(settings: fixture.settings)
        localization.select(.simplifiedChinese)
        var report = SettingsBackupImportReport()
        report.importedRemoteCount = 2
        report.skip(["t1_remote"], .remoteModelNotOnThisMac)
        report.skip(["chromecast_voice_remote", "home"], .unrecognizedValue)

        let text = SettingsBackupMessage.summary(for: report, using: localization)
        #expect(text.contains("2"))
        #expect(text.contains("本机没有这个型号"))
        #expect(text.contains("这个版本不认识"))
        #expect(text.contains(localization.text("remote.button.full.home")))
        #expect(text.contains(localization.text(RemoteModel.t1Remote.localizationKey)))
    }

    @Test func summaryTruncatesAfterTwentyItems() throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let localization = LocalizationStore(settings: fixture.settings)
        localization.select(.simplifiedChinese)
        var report = SettingsBackupImportReport()
        for index in 0..<25 { report.skip(["general", "value\(index)"], .unrecognizedValue) }

        let text = SettingsBackupMessage.summary(for: report, using: localization)
        #expect(text.contains("另有 5 项"))
        #expect(!text.contains("value20"))
    }

    @Test func backupStringsExistInBothLanguages() throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let localization = LocalizationStore(settings: fixture.settings)
        for key in Self.backupStringKeys {
            localization.select(.english)
            let english = localization.text(key)
            localization.select(.simplifiedChinese)
            let chinese = localization.text(key)
            #expect(english != key, "missing English text for \(key)")
            #expect(chinese != key, "missing Chinese text for \(key)")
        }
    }

    @Test func documentWithoutFormatOrVersionIsRejected() {
        for json in [
            #"{"formatVersion":1}"#,
            #"{"format":"remote-buddy-settings"}"#,
            #"{"format":"remote-buddy-settings","formatVersion":"1"}"#,
            #"{"format":"other","formatVersion":1}"#,
            "[]",
        ] {
            #expect(throws: SettingsBackupError.notASettingsFile) {
                try JSONDecoder().decode(SettingsBackupDocument.self, from: Data(json.utf8))
            }
        }
    }

    @Test func nilGainExportsWithoutSolidifyingAndPreservesGlobalFallback() throws {
        let name = "settings-backup-nil-gain-" + UUID().uuidString
        let values = try #require(UserDefaults(suiteName: name))
        defer { values.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: values)
        settings.gainDB = 7
        let xiaomi = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        let google = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        settings.selectRemoteProfile(xiaomi)
        settings.setGainDB(5, for: google)
        #expect(settings.gainDB(for: xiaomi) == 7)
        #expect(settings.remoteDeviceProfiles.first { $0.id == xiaomi }?.gainDB == nil)
        let exported = try settings.settingsBackupData(appVersion: "1.0")

        let object = try jsonObject(exported)
        let remotes = try #require(object["remotes"] as? [[String: Any]])
        let xiaomiRemote = try #require(remotes.first { ($0["model"] as? String) == RemoteModel.rc003.rawValue })
        let googleRemote = try #require(
            remotes.first { ($0["model"] as? String) == RemoteModel.chromecastVoiceRemote.rawValue }
        )
        #expect(xiaomiRemote["gainDB"] == nil)
        #expect(googleRemote["gainDB"] as? Double == 5)

        // Target Mac: xiaomi has no explicit gain (follows global), google has explicit 3 dB.
        let targetName = "settings-backup-target-" + UUID().uuidString
        let targetValues = try #require(UserDefaults(suiteName: targetName))
        defer { targetValues.removePersistentDomain(forName: targetName) }
        let target = AppSettings(defaults: targetValues)
        target.gainDB = 14
        let targetXiaomi = target.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        let targetGoogle = target.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        target.setGainDB(3, for: targetGoogle)

        _ = try importBackup(try backup([remote(.rc003, gainDB: nil)]), into: target)
        #expect(target.remoteDeviceProfiles.first { $0.id == targetXiaomi }?.gainDB == nil)
        target.selectRemoteProfile(targetXiaomi)
        #expect(target.gainDB(for: targetXiaomi) == 14)

        // Importing nil gain into a profile that already has an explicit gain keeps its explicit value.
        _ = try importBackup(try backup([remote(.chromecastVoiceRemote, gainDB: nil)]), into: target)
        #expect(target.gainDB(for: targetGoogle) == 3)
    }

    @Test func unnamedRemotesOfSameModelMatchOneToOneWithoutSharing() throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let settings = fixture.settings
        let secondGoogle = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        let data = try backup([
            remote(.chromecastVoiceRemote) { $0.buttonBindings["home"] = .showDesktop },
            remote(.chromecastVoiceRemote) { $0.buttonBindings["home"] = .escape },
        ])

        let report = try importBackup(data, into: settings)
        #expect(settings.action(for: .home, profileID: fixture.google) == .showDesktop)
        #expect(settings.action(for: .home, profileID: secondGoogle) == .escape)
        #expect(report.sharedRemoteModels.isEmpty)
        #expect(report.isClean)
    }

    @Test func namedMatchBeatsUnnamedProfileForSameModel() throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let settings = fixture.settings
        let named = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        settings.updateRemoteProfile(named, model: .chromecastVoiceRemote, customName: "Living room")
        let data = try backup([
            remote(.chromecastVoiceRemote, name: "Living room") { $0.buttonBindings["home"] = .escape },
            remote(.chromecastVoiceRemote, name: "") { $0.buttonBindings["home"] = .showDesktop },
        ])

        let report = try importBackup(data, into: settings)
        #expect(settings.action(for: .home, profileID: fixture.google) == .showDesktop)
        #expect(settings.action(for: .home, profileID: named) == .escape)
        #expect(report.sharedRemoteModels.isEmpty)
        #expect(report.isClean)
    }

    @Test func unknownAppIconIdentifierIsSkippedWithoutChangingSetting() throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let data = Data(#"{"format":"remote-buddy-settings","formatVersion":1,"general":{"appIconIdentifier":"future_icon"}}"#.utf8)
        let report = try importBackup(data, into: fixture.settings, availableAppIcons: [.standard])
        #expect(fixture.settings.appIconIdentifier == .standard)
        #expect(report.skippedItems.contains(.init(location: ["general", "appIconIdentifier"], reason: .unrecognizedValue)))
    }

    @Test func unknownDisabledIntegrationIsSkippedWhileKnownApplies() throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let known = try #require(ApplicationIntegration.allCases.first).rawValue
        let json = """
        {"format":"remote-buddy-settings","formatVersion":1,
        "general":{"disabledApplicationIntegrations":["future_integration","\(known)"]}}
        """
        let report = try importBackup(Data(json.utf8), into: fixture.settings)
        #expect(!fixture.settings.enabledApplicationIntegrations.contains(known))
        #expect(report.skippedItems.contains(
            .init(location: ["general", "disabledApplicationIntegrations", "future_integration"],
                  reason: .unrecognizedValue)))
    }

    @Test func mixedValidAndInvalidApplicationReferencesKeepValidAndDropInvalid() throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let fileApplication = CustomApplicationProfile(
            displayName: "Example", bundleIdentifier: "com.example.app", applicationPath: "/Applications/Example.app")
        let missingID = UUID()
        let data = try backup([remote(.chromecastVoiceRemote) {
            $0.buttonBindings["home"] = .openCustomApplication
            $0.buttonBindings["youtube"] = .openCustomApplication
            $0.buttonApplicationProfileIDs = ["home": fileApplication.id, "youtube": missingID]
        }], applications: [fileApplication])

        let report = try importBackup(data, into: fixture.settings)
        let localID = try #require(fixture.settings.customApplicationProfiles.first?.id)
        #expect(fixture.settings.applicationProfileID(for: .home, profileID: fixture.google) == localID)
        #expect(fixture.settings.applicationProfileID(for: .youtube, profileID: fixture.google) == nil)
        #expect(fixture.settings.action(for: .youtube, profileID: fixture.google) == .previousCommandLeft)
        #expect(report.skippedItems.contains(
            .init(location: ["chromecast_voice_remote", "youtube"], reason: .unknownApplicationReference)))
    }

    @Test func malformedCustomApplicationIsSkippedAndLocalizedInSummary() throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let json = """
        {"format":"remote-buddy-settings","formatVersion":1,"customApplications":[
          {"id":"\(UUID().uuidString)","displayName":"Valid App","bundleIdentifier":"com.example.valid","applicationPath":"/Applications/Valid.app","focusStrategy":"none"},
          {"displayName":"Broken App","bundleIdentifier":"com.example.broken"},
          {"bundleIdentifier":"com.example.nameless"}
        ],"remotes":[]}
        """
        let report = try importBackup(Data(json.utf8), into: fixture.settings)
        #expect(fixture.settings.customApplicationProfiles.map(\.displayName) == ["Valid App"])
        #expect(report.skippedItems.contains(
            .init(location: ["customApplications", "Broken App"], reason: .unrecognizedValue)))
        #expect(report.skippedItems.contains(
            .init(location: ["customApplications", "#3"], reason: .unrecognizedValue)))

        let localization = LocalizationStore(settings: fixture.settings)
        localization.select(.english)
        let english = SettingsBackupMessage.summary(for: report, using: localization)
        #expect(english.contains("Custom Applications › Broken App"))
        #expect(english.contains("Custom Applications › #3"))

        localization.select(.simplifiedChinese)
        let chinese = SettingsBackupMessage.summary(for: report, using: localization)
        #expect(chinese.contains("自定义应用 › Broken App"))
        #expect(chinese.contains("自定义应用 › #3"))
    }

    @Test func tableLevelTypeErrorInBackupMappingsKeepsValidBindingsAndReportsTable() throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let data = try rewritingFirstRemote(of: try backup([remote(.chromecastVoiceRemote) {
            $0.buttonBindings["home"] = .showDesktop
        }])) { remote in
            var mappings = remote["mappings"] as? [String: Any] ?? [:]
            mappings["buttonShortcuts"] = "oops"
            remote["mappings"] = mappings
        }

        let report = try importBackup(data, into: fixture.settings)
        #expect(fixture.settings.action(for: .home, profileID: fixture.google) == .showDesktop)
        #expect(report.skippedItems.contains(
            .init(location: ["chromecast_voice_remote", "buttonShortcuts"], reason: .unrecognizedValue)))
    }

    @Test func repeatedImportIsIdempotent() throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let settings = fixture.settings
        settings.setAction(.showDesktop, for: .home)
        settings.addCustomApplicationProfile(.init(
            displayName: "Example", bundleIdentifier: "com.example.app", applicationPath: "/Applications/Example.app"))
        let exported = try settings.settingsBackupData(appVersion: "1.0")

        let first = try importBackup(exported, into: settings)
        let second = try importBackup(exported, into: settings)
        #expect(first.isClean)
        #expect(second.isClean)
        #expect(first.importedRemoteCount == 2)
        #expect(second.importedRemoteCount == 2)
        #expect(settings.customApplicationProfiles.count == 1)
    }

    @Test func freshInstallWithoutRemotesImportsGeneralAndSkipsRemotes() throws {
        let name = "settings-backup-fresh-" + UUID().uuidString
        let values = try #require(UserDefaults(suiteName: name))
        defer { values.removePersistentDomain(forName: name) }
        let fresh = AppSettings(defaults: values)
        let fileApplication = CustomApplicationProfile(
            displayName: "Example", bundleIdentifier: "com.example.app", applicationPath: "/Applications/Example.app")
        var document = SettingsBackupDocument(
            exportedAt: Date(),
            appVersion: "1.0",
            general: .init(showDockIcon: true, customMappingEnabled: true),
            customApplications: [fileApplication],
            remotes: [remote(.rc003), remote(.chromecastVoiceRemote)]
        )
        document.formatVersion = SettingsBackupDocument.currentFormatVersion
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)

        let report = try importBackup(data, into: fresh)
        #expect(fresh.showDockIcon)
        #expect(fresh.customMappingEnabled)
        #expect(fresh.customApplicationProfiles.count == 1)
        #expect(report.importedRemoteCount == 0)
        #expect(report.skippedItems.contains(.init(location: ["rc003"], reason: .remoteModelNotOnThisMac)))
        #expect(report.skippedItems.contains(
            .init(location: ["chromecast_voice_remote"], reason: .remoteModelNotOnThisMac)))
    }
}
