import AppKit
import Foundation

extension AppSettings {
    static let maximumSettingsBackupBytes = 4_000_000

    func settingsBackupData(appVersion: String, now: Date = Date()) throws -> Data {
        let general = SettingsBackupDocument.General(
            applicationLanguage: applicationLanguage.rawValue,
            appIconIdentifier: appIconIdentifier.rawValue,
            showDockIcon: showDockIcon,
            showStatusBarIcon: showStatusBarIcon,
            openMainWindowAtLaunch: openMainWindowAtLaunch,
            checksForPreReleaseUpdates: checksForPreReleaseUpdates,
            diagnosticLoggingEnabled: diagnosticLoggingEnabled,
            customMappingEnabled: customMappingEnabled,
            disabledApplicationIntegrations: ApplicationIntegration.allCases.map(\.rawValue)
                .filter { !enabledApplicationIntegrations.contains($0) }
        )
        let remotes = remoteDeviceProfiles.map { profile in
            SettingsBackupDocument.Remote(
                model: profile.model,
                name: profile.customName,
                gainDB: profile.gainDB,
                g9n9nVoiceButtonMode: profile.model.isChromecastRemote
                    ? profile.effectiveG9N9NVoiceButtonMode : nil,
                mappings: profile.mappings
            )
        }
        let document = SettingsBackupDocument(
            exportedAt: now,
            appVersion: appVersion,
            general: general,
            customApplications: customApplicationProfiles,
            remotes: remotes
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(document)
    }

    /// Restores a backup onto this Mac's remotes by model. Only a file that is not a settings
    /// backup is rejected as a whole, and then nothing changes; anything else this build cannot
    /// apply is skipped on its own and listed in the report.
    func importSettingsBackup(
        from data: Data,
        availableAppIcons: Set<AppIconIdentifier> = [.standard],
        isApplicationInstalled: (String) -> Bool = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }
    ) throws -> SettingsBackupImportReport {
        guard data.count <= Self.maximumSettingsBackupBytes else { throw SettingsBackupError.fileTooLarge }
        let log = LossyDecodingLog()
        let decoder = JSONDecoder.lossy(log: log)
        decoder.dateDecodingStrategy = .iso8601
        let document: SettingsBackupDocument
        do {
            document = try decoder.decode(SettingsBackupDocument.self, from: data)
        } catch {
            throw SettingsBackupError.notASettingsFile
        }

        var report = SettingsBackupImportReport()
        let rawRemoteModels = Self.rawRemoteModels(in: data)
        let rawCustomApplicationNames = Self.rawCustomApplicationNames(in: data)
        for path in log.droppedPaths {
            report.skip(
                Self.backupLocation(
                    for: path,
                    rawRemoteModels: rawRemoteModels,
                    rawCustomApplicationNames: rawCustomApplicationNames
                ),
                .unrecognizedValue
            )
        }
        applyBackupGeneral(document.general, availableAppIcons: availableAppIcons, report: &report)
        let applicationIDs = mergeBackupApplications(
            document.customApplications, report: &report, isApplicationInstalled: isApplicationInstalled
        )
        applyBackupRemotes(document.remotes, applicationIDs: applicationIDs, report: &report)
        report.isFromNewerVersion = document.formatVersion > SettingsBackupDocument.currentFormatVersion
        AppLogger.shared.write(
            "SETTINGS BACKUP imported remotes=\(report.importedRemoteCount) " +
                "skipped=\(report.skippedItems.count) missing_apps=\(report.missingApplications.count) " +
                "format_version=\(document.formatVersion)"
        )
        return report
    }

    private func applyBackupGeneral(
        _ general: SettingsBackupDocument.General,
        availableAppIcons: Set<AppIconIdentifier>,
        report: inout SettingsBackupImportReport
    ) {
        if let raw = general.applicationLanguage {
            if let language = AppLanguage(rawValue: raw) {
                applicationLanguage = language
            } else {
                report.skip(["general", "applicationLanguage"], .unrecognizedValue)
            }
        }
        if let raw = general.appIconIdentifier {
            let identifier = AppIconIdentifier(rawValue: raw)
            if !raw.isEmpty, availableAppIcons.contains(identifier) {
                appIconIdentifier = identifier
            } else {
                report.skip(["general", "appIconIdentifier"], .unrecognizedValue)
            }
        }
        if let value = general.showDockIcon { showDockIcon = value }
        if let value = general.showStatusBarIcon { showStatusBarIcon = value }
        if let value = general.openMainWindowAtLaunch { openMainWindowAtLaunch = value }
        if let value = general.checksForPreReleaseUpdates { checksForPreReleaseUpdates = value }
        if let value = general.diagnosticLoggingEnabled { diagnosticLoggingEnabled = value }
        if let value = general.customMappingEnabled { customMappingEnabled = value }
        if let disabled = general.disabledApplicationIntegrations {
            let known = Set(ApplicationIntegration.allCases.map(\.rawValue))
            var knownDisabled: Set<String> = []
            for identifier in disabled {
                if known.contains(identifier) {
                    knownDisabled.insert(identifier)
                } else {
                    report.skip(["general", "disabledApplicationIntegrations", identifier], .unrecognizedValue)
                }
            }
            enabledApplicationIntegrations = known.subtracting(knownDisabled)
        }
    }

    /// Matches applications by bundle identifier and returns file ID → local ID, so mappings
    /// keep pointing at the same app even though each Mac assigned its own IDs.
    private func mergeBackupApplications(
        _ applications: [CustomApplicationProfile],
        report: inout SettingsBackupImportReport,
        isApplicationInstalled: (String) -> Bool
    ) -> [UUID: UUID] {
        var profiles = customApplicationProfiles
        var localIDs: [UUID: UUID] = [:]
        for application in applications {
            let localID: UUID
            if let existing = profiles.first(where: { $0.bundleIdentifier == application.bundleIdentifier }) {
                // Keep the local app's path, focus strategy, and recorded accessibility target intact.
                localID = existing.id
            } else {
                localID = profiles.contains(where: { $0.id == application.id }) ? UUID() : application.id
                profiles.append(application.withID(localID))
            }
            localIDs[application.id] = localID
            if !isApplicationInstalled(application.bundleIdentifier),
               !report.missingApplications.contains(application.displayName) {
                report.missingApplications.append(application.displayName)
            }
        }
        if profiles != customApplicationProfiles { customApplicationProfiles = profiles }
        return localIDs
    }

    private func applyBackupRemotes(
        _ remotes: [SettingsBackupDocument.Remote],
        applicationIDs: [UUID: UUID],
        report: inout SettingsBackupImportReport
    ) {
        var matchedBackupIndex: [Int: Int] = [:]
        var usedBackupIndices: Set<Int> = []
        // Claim exact non-empty name matches first so unnamed local profiles do not take them.
        for index in remoteDeviceProfiles.indices {
            let profile = remoteDeviceProfiles[index]
            guard !profile.customName.isEmpty else { continue }
            let match = remotes.indices.first {
                !usedBackupIndices.contains($0) &&
                    remotes[$0].model == profile.model &&
                    remotes[$0].name == profile.customName
            } ?? remotes.indices.first {
                remotes[$0].model == profile.model && remotes[$0].name == profile.customName
            }
            if let match {
                matchedBackupIndex[index] = match
                usedBackupIndices.insert(match)
            }
        }
        for index in remoteDeviceProfiles.indices where matchedBackupIndex[index] == nil {
            let profile = remoteDeviceProfiles[index]
            let match = remotes.indices.first {
                !usedBackupIndices.contains($0) && remotes[$0].model == profile.model
            } ?? remotes.indices.first {
                remotes[$0].model == profile.model
            }
            if let match {
                matchedBackupIndex[index] = match
                usedBackupIndices.insert(match)
            }
        }

        var reloadsSelectedProfile = false
        var appliedCountByBackupIndex: [Int: Int] = [:]
        for index in remoteDeviceProfiles.indices {
            guard let backupIndex = matchedBackupIndex[index] else { continue }
            appliedCountByBackupIndex[backupIndex, default: 0] += 1
            let source = remotes[backupIndex]
            let profile = remoteDeviceProfiles[index]
            report.importedRemoteCount += 1
            let model = profile.model.rawValue
            if allowsMappingEdits(for: profile.id) {
                for unknownPath in source.mappings.unknownKeyPaths {
                    report.skip([model] + unknownPath, .unrecognizedValue)
                }
                remoteDeviceProfiles[index].mappings = Self.remappingApplications(
                    in: source.mappings.strippingUnknownKeys(),
                    to: applicationIDs,
                    model: model,
                    report: &report
                )
                if profile.id == selectedRemoteProfileID { reloadsSelectedProfile = true }
            } else {
                report.skip([model], .mappingLockedByCompatibilityMode)
            }
            if let gain = source.gainDB {
                if gain.isFinite, (0...24).contains(gain) {
                    setGainDB(gain, for: profile.id)
                } else {
                    report.skip([model, "gainDB"], .unrecognizedValue)
                }
            }
            if let mode = source.g9n9nVoiceButtonMode { setG9N9NVoiceButtonMode(mode, for: profile.id) }
        }
        for (backupIndex, count) in appliedCountByBackupIndex.sorted(by: { $0.key < $1.key }) where count > 1 {
            let model = remotes[backupIndex].model
            if !report.sharedRemoteModels.contains(model) {
                report.sharedRemoteModels.append(model)
            }
        }
        let localModels = Set(remoteDeviceProfiles.map(\.model))
        for remote in remotes where !localModels.contains(remote.model) {
            report.skip([remote.model.rawValue], .remoteModelNotOnThisMac)
        }
        if reloadsSelectedProfile { reloadSelectedRemoteProfileMappings() }
    }

    /// An entry pointing at an application the file does not include is dropped whole, so the
    /// button falls back to its default instead of opening nothing.
    private static func remappingApplications(
        in source: RemoteDeviceMappings,
        to applicationIDs: [UUID: UUID],
        model: String,
        report: inout SettingsBackupImportReport
    ) -> RemoteDeviceMappings {
        var mappings = source
        var remappedIDs: [String: UUID] = [:]
        for (button, fileID) in source.buttonApplicationProfileIDs ?? [:] {
            if let localID = applicationIDs[fileID] {
                remappedIDs[button] = localID
            } else {
                mappings.buttonBindings.removeValue(forKey: button)
                mappings.buttonShortcuts.removeValue(forKey: button)
                report.skip([model, button], .unknownApplicationReference)
            }
        }
        mappings.buttonApplicationProfileIDs = remappedIDs.isEmpty ? nil : remappedIDs
        for (button, bindings) in source.secondaryButtonBindings {
            for (trigger, binding) in bindings {
                guard let fileID = binding.applicationProfileID else { continue }
                if let localID = applicationIDs[fileID] {
                    mappings.secondaryButtonBindings[button]?[trigger]?.applicationProfileID = localID
                } else {
                    mappings.secondaryButtonBindings[button]?.removeValue(forKey: trigger)
                    report.skip([model, button, trigger], .unknownApplicationReference)
                }
            }
        }
        return mappings
    }

    /// Same as the mapping half of `selectRemoteProfile`, for a profile that is already selected.
    private func reloadSelectedRemoteProfileMappings() {
        guard let profile = selectedRemoteProfile else { return }
        withLoadingRemoteProfile {
            buttonBindings = Self.defaultMappings(for: profile.model).parsedButtonBindings.merging(
                profile.mappings.parsedButtonBindings
            ) { _, saved in saved }
            buttonShortcuts = profile.mappings.parsedButtonShortcuts
            buttonApplicationProfileIDs = profile.mappings.parsedButtonApplicationProfileIDs
            secondaryButtonBindings = profile.mappings.parsedSecondaryButtonBindings
        }
    }

    /// Model strings by position in the file, read without decoding, so a remote whose model
    /// this build does not know can still be named in the report.
    private static func rawRemoteModels(in data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let remotes = object["remotes"] as? [Any] else { return [] }
        return remotes.map { (($0 as? [String: Any])?["model"] as? String) ?? "" }
    }

    private static func rawCustomApplicationNames(in data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let applications = object["customApplications"] as? [Any] else { return [] }
        return applications.map { (($0 as? [String: Any])?["displayName"] as? String) ?? "" }
    }

    /// Turns a decoding path inside the file into the remote › button › gesture form shown to people.
    private static func backupLocation(
        for path: [String],
        rawRemoteModels: [String],
        rawCustomApplicationNames: [String]
    ) -> [String] {
        if path.count >= 2, path[0] == "customApplications", let index = Int(path[1]) {
            let name = rawCustomApplicationNames.indices.contains(index) &&
                !rawCustomApplicationNames[index].isEmpty
                ? rawCustomApplicationNames[index] : "#\(index + 1)"
            return ["customApplications", name] + Array(path.dropFirst(2))
        }
        guard path.count >= 2, path[0] == "remotes", let index = Int(path[1]) else { return path }
        let model = rawRemoteModels.indices.contains(index) && !rawRemoteModels[index].isEmpty
            ? rawRemoteModels[index] : path[1]
        var rest = Array(path.dropFirst(2))
        if rest.count >= 3, rest[0] == "mappings" {
            rest.removeFirst(2)
        } else if rest.count == 2, rest[0] == "mappings" {
            rest.removeFirst(1)
        }
        return [model] + rest
    }
}

private extension CustomApplicationProfile {
    func withID(_ id: UUID) -> CustomApplicationProfile {
        CustomApplicationProfile(
            id: id,
            displayName: displayName,
            bundleIdentifier: bundleIdentifier,
            applicationPath: applicationPath,
            focusStrategy: focusStrategy,
            focusShortcut: focusShortcut,
            accessibilityTarget: accessibilityTarget
        )
    }
}
