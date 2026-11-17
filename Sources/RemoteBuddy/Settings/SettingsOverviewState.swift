import Foundation

/// Current prerequisites, independent of onboarding completion or an idle audio engine.
struct SettingsOverviewState: Equatable {
    let missingRequirementKeys: [String]
    let connectedRemoteNames: [String]
    let integrationTool: OnboardingVoiceTool
    let integrationAvailability: OnboardingVoiceToolAvailability

    var permissionsReady: Bool { missingRequirementKeys.isEmpty }
    var remoteReady: Bool { !connectedRemoteNames.isEmpty }
    var integrationMissing: Bool {
        integrationTool != .unselected && integrationAvailability == .notInstalled
    }
    var integrationReady: Bool {
        integrationTool != .unselected && !integrationMissing
    }

    init(bluetoothGranted: Bool, inputMonitoringGranted: Bool, accessibilityGranted: Bool,
         audioDevices: [AudioDeviceInfo], profiles: [RemoteDeviceProfile], connectedIDs: Set<UUID>,
         integrationTool: OnboardingVoiceTool,
         integrationAvailability: OnboardingVoiceToolAvailability = .available,
         remoteName: (RemoteDeviceProfile) -> String) {
        var missing: [String] = []
        if !bluetoothGranted { missing.append("permission.bluetooth.title") }
        if !inputMonitoringGranted { missing.append("permission.input_monitoring.title") }
        if !accessibilityGranted { missing.append("permission.accessibility.title") }
        if !audioDevices.contains(where: {
            OnboardingAudioSelectionPolicy.isSupportedDevice(uid: $0.uid, name: $0.name)
        }) { missing.append("settings.driver.title") }
        missingRequirementKeys = missing
        connectedRemoteNames = profiles.filter { connectedIDs.contains($0.id) }.map(remoteName)
        self.integrationTool = integrationTool
        self.integrationAvailability = integrationAvailability
    }

    @MainActor func integrationSummary(using localization: LocalizationStore) -> String {
        guard integrationTool != .unselected else {
            return localization.text("settings.overview.not_configured")
        }
        if integrationMissing {
            return LocalizedMessage("settings.overview.integration_unavailable", arguments: [
                localization.text(integrationTool.titleKey)
            ]).text(using: localization)
        }
        return localization.text(integrationTool.titleKey)
    }

    @MainActor func permissionsSummary(using localization: LocalizationStore) -> String {
        guard !permissionsReady else { return localization.text("settings.overview.ready") }
        return LocalizedMessage("settings.overview.missing_requirements", arguments: [
            Self.localizedList(missingRequirementKeys.map { localization.text($0) }, locale: localization.locale)
        ]).text(using: localization)
    }

    static func localizedList(_ values: [String], locale: Locale) -> String {
        let formatter = ListFormatter()
        formatter.locale = locale
        return formatter.string(from: values) ?? values.joined(separator: ", ")
    }

}
