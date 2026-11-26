import Combine
import Foundation

/// Safety cap options (in minutes) for continuous or hands-free voice sessions across
/// supported remotes (such as G9N9N and T1), stopping forgotten sessions automatically.
enum VoiceAutoStopDuration: Int, CaseIterable, Codable, Identifiable {
    case threeMinutes = 3
    case fiveMinutes = 5
    case tenMinutes = 10

    static let keepaliveIntervalSeconds = 10

    var id: Int { rawValue }
    var minutes: Int { rawValue }
    var timeInterval: TimeInterval { TimeInterval(rawValue * 60) }

    var maxKeepaliveExtensions: Int {
        (rawValue * 60) / Self.keepaliveIntervalSeconds
    }

    var titleKey: String {
        switch self {
        case .threeMinutes:
            return "about.preferences.voice_auto_stop_duration.3m"
        case .fiveMinutes:
            return "about.preferences.voice_auto_stop_duration.5m"
        case .tenMinutes:
            return "about.preferences.voice_auto_stop_duration.10m"
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let currentOnboardingVersion = 1

    enum Keys {
        static let disabledApplicationIntegrations = "disabledApplicationIntegrations"
        static let gainDB = "gainDB"
        static let customMappingEnabled = "customMappingEnabled"
        static let buttonBindings = "buttonBindings"
        static let buttonShortcuts = "buttonShortcuts"
        static let buttonApplicationProfileIDs = "buttonApplicationProfileIDs"
        static let buttonURLs = "buttonURLs"
        static let secondaryButtonBindings = "secondaryButtonBindings"
        static let customApplicationProfiles = "customApplicationProfiles"
        static let remoteDeviceProfiles = "remoteDeviceProfiles"
        static let selectedRemoteProfileID = "selectedRemoteProfileID"
        static let applicationLanguage = "applicationLanguage"
        static let appIconIdentifier = "appIconIdentifier"
        static let showDockIcon = "showDockIcon"
        static let showStatusBarIcon = "showStatusBarIcon"
        static let openMainWindowAtLaunch = "openMainWindowAtLaunch"
        static let receiveUpdateNotifications = "receiveUpdateNotifications"
        static let diagnosticLoggingEnabled = AppLogger.diagnosticLoggingEnabledKey
        static let g9n9nBluetoothLogRecoveryEnabled = "g9n9nBluetoothLogRecoveryEnabled"
        static let voiceFnTapModeEnabled = "voiceFnTapModeEnabled"
        static let voiceKeyMode = "voiceKeyMode"
        static let voiceAutoStopMinutes = "voiceAutoStopMinutes"
        static let lastLaunchedBuild = "launch.lastLaunchedBuild"
        static let onboardingPurpose = "onboarding.purpose"
        static let onboardingCompletedVersion = "onboarding.completedVersion"
        static let onboardingStep = "onboarding.step"
        static let onboardingControlSource = "onboarding.controlSource"
        static let onboardingDevice = "onboarding.device"
        static let onboardingVoiceTool = "onboarding.voiceTool"
        static let bypassInputSourceSwitching = "voiceTool.bypassInputSourceSwitching"
        static let onboardingPreferredGesture = "onboarding.preferredGesture"
        static let onboardingVerifiedVoiceBinding = "onboarding.verifiedVoiceBinding"
        static let onboardingStagedVoiceBinding = "onboarding.stagedVoiceBinding"
        static let onboardingVoiceTrigger = "onboarding.voiceTrigger"
        static let firstUseEvents = "onboarding.diagnostics.events"
        static let firstUseStepStartedAt = "onboarding.diagnostics.stepStartedAt"
        static let firstUseLastSignature = "onboarding.diagnostics.lastSignature"
    }

    private static var allApplicationIntegrationIdentifiers: Set<String> {
        Set(ApplicationIntegration.allCases.map(\.rawValue))
    }

    @Published var enabledApplicationIntegrations: Set<String> {
        didSet {
            let disabled = Self.allApplicationIntegrationIdentifiers.subtracting(enabledApplicationIntegrations)
            defaults.set(disabled.sorted(), forKey: Keys.disabledApplicationIntegrations)
        }
    }

    let defaults: UserDefaults

    @Published private var storedGainDB: Double
    var gainDB: Double {
        get { storedGainDB }
        set {
            let normalized = Self.normalizedGain(newValue)
            let changed = storedGainDB != normalized
            if changed { storedGainDB = normalized }
            defaults.set(normalized, forKey: Keys.gainDB)
            if changed { saveSelectedRemoteGain() }
        }
    }

    var selectedAudioDeviceUID: String { BuddyMicrophoneDevicePolicy.deviceUID }

    @Published var customMappingEnabled: Bool {
        didSet { defaults.set(customMappingEnabled, forKey: Keys.customMappingEnabled) }
    }

    func setBaseBinding(_ configured: ConfiguredButtonAction, for button: RemoteButton,
                        trigger: ButtonTrigger, profileID: UUID?) {
        AppLogger.shared.write(
            "SETTINGS MAPPING updated button=\(button.rawValue) trigger=\(trigger.rawValue) " +
                "action=\(configured.action.rawValue) profile_scoped=\(profileID != nil)"
        )

        if let profileID, profileID != selectedRemoteProfileID {
            if let index = remoteDeviceProfiles.firstIndex(where: { $0.id == profileID }) {
                let mappings = remoteDeviceProfiles[index].mappings
                var parsedBindings = mappings.parsedButtonBindings
                var parsedShortcuts = mappings.parsedButtonShortcuts
                var parsedAppIDs = mappings.parsedButtonApplicationProfileIDs
                var parsedURLs = mappings.parsedButtonURLs
                var parsedSecondary = mappings.parsedSecondaryButtonBindings
                if trigger == .singleClick {
                    parsedBindings[button] = configured.action
                    if let shortcut = configured.shortcut {
                        parsedShortcuts[button] = shortcut
                    } else {
                        parsedShortcuts.removeValue(forKey: button)
                    }
                    if let appID = configured.applicationProfileID {
                        parsedAppIDs[button] = appID
                    } else {
                        parsedAppIDs.removeValue(forKey: button)
                    }
                    if let url = CustomActionURLPolicy.normalizedInput(configured.urlString) {
                        parsedURLs[button] = url
                    } else {
                        parsedURLs.removeValue(forKey: button)
                    }
                } else {
                    var secondary = parsedSecondary[button] ?? [:]
                    secondary[trigger] = configured
                    parsedSecondary[button] = secondary
                }
                remoteDeviceProfiles[index].mappings = RemoteDeviceMappings(
                    buttonBindings: parsedBindings,
                    buttonShortcuts: parsedShortcuts,
                    buttonApplicationProfileIDs: parsedAppIDs,
                    buttonURLs: parsedURLs,
                    secondaryButtonBindings: parsedSecondary
                )
                saveRemoteDeviceProfiles()
            }
        } else {
            if trigger == .singleClick {
                buttonBindings[button] = configured.action
                if let shortcut = configured.shortcut {
                    buttonShortcuts[button] = shortcut
                } else {
                    buttonShortcuts.removeValue(forKey: button)
                }
                if let appID = configured.applicationProfileID {
                    buttonApplicationProfileIDs[button] = appID
                } else {
                    buttonApplicationProfileIDs.removeValue(forKey: button)
                }
                if let url = CustomActionURLPolicy.normalizedInput(configured.urlString) {
                    buttonURLs[button] = url
                } else {
                    buttonURLs.removeValue(forKey: button)
                }
            } else {
                var secondary = secondaryButtonBindings[button] ?? [:]
                secondary[trigger] = configured
                secondaryButtonBindings[button] = secondary
            }
        }
    }

    @Published var buttonBindings: [RemoteButton: ButtonAction] {
        didSet {
            saveBindings()
            saveSelectedRemoteProfileMappings()
        }
    }

    @Published var buttonShortcuts: [RemoteButton: CustomKeyboardShortcut] {
        didSet {
            saveShortcuts()
            saveSelectedRemoteProfileMappings()
        }
    }

    @Published var buttonApplicationProfileIDs: [RemoteButton: UUID] {
        didSet {
            saveButtonApplicationProfileIDs()
            saveSelectedRemoteProfileMappings()
        }
    }

    @Published var buttonURLs: [RemoteButton: String] {
        didSet {
            saveButtonURLs()
            saveSelectedRemoteProfileMappings()
        }
    }

    @Published var secondaryButtonBindings: [RemoteButton: [ButtonTrigger: ConfiguredButtonAction]] {
        didSet {
            saveSecondaryBindings()
            saveSelectedRemoteProfileMappings()
        }
    }

    @Published var customApplicationProfiles: [CustomApplicationProfile] {
        didSet { saveCustomApplicationProfiles() }
    }

    @Published var remoteDeviceProfiles: [RemoteDeviceProfile] {
        didSet { saveRemoteDeviceProfiles() }
    }

    @Published var selectedRemoteProfileID: UUID? {
        didSet { defaults.set(selectedRemoteProfileID?.uuidString, forKey: Keys.selectedRemoteProfileID) }
    }

    @Published var applicationLanguage: AppLanguage {
        didSet { defaults.set(applicationLanguage.rawValue, forKey: Keys.applicationLanguage) }
    }

    @Published var appIconIdentifier: AppIconIdentifier {
        didSet {
            defaults.set(appIconIdentifier.rawValue, forKey: Keys.appIconIdentifier)
        }
    }

    @Published var showDockIcon: Bool {
        didSet { defaults.set(showDockIcon, forKey: Keys.showDockIcon) }
    }

    @Published var showStatusBarIcon: Bool {
        didSet { defaults.set(showStatusBarIcon, forKey: Keys.showStatusBarIcon) }
    }

    @Published var openMainWindowAtLaunch: Bool {
        didSet { defaults.set(openMainWindowAtLaunch, forKey: Keys.openMainWindowAtLaunch) }
    }

    @Published var receiveUpdateNotifications: Bool {
        didSet {
            defaults.set(receiveUpdateNotifications, forKey: Keys.receiveUpdateNotifications)
        }
    }

    @Published var diagnosticLoggingEnabled: Bool {
        didSet {
            defaults.set(diagnosticLoggingEnabled, forKey: Keys.diagnosticLoggingEnabled)
            if defaults === UserDefaults.standard, !AppLogger.isTestProcess() {
                AppLogger.shared.setEnabled(diagnosticLoggingEnabled)
            }
        }
    }

    @Published var g9n9nBluetoothLogRecoveryEnabled: Bool {
        didSet {
            defaults.set(
                g9n9nBluetoothLogRecoveryEnabled,
                forKey: Keys.g9n9nBluetoothLogRecoveryEnabled
            )
        }
    }

    @Published var voiceFnTapModeEnabled: Bool {
        didSet {
            defaults.set(
                voiceFnTapModeEnabled,
                forKey: Keys.voiceFnTapModeEnabled
            )
        }
    }

    /// 语音键触发语音输入工具时发送的按键，例如 Fn/Globe、Command 或 Option。
    @Published var voiceKeyMode: VoiceKeyMode {
        didSet {
            defaults.set(voiceKeyMode.rawValue, forKey: Keys.voiceKeyMode)
        }
    }

    /// 自动停麦安全上限（分钟），适用于 G9N9N、T1 等点按免提或硬件保活收音模式。
    @Published var voiceAutoStopDuration: VoiceAutoStopDuration {
        didSet {
            defaults.set(voiceAutoStopDuration.rawValue, forKey: Keys.voiceAutoStopMinutes)
        }
    }

    private(set) var isLoadingRemoteProfile = false
    private(set) var isResettingBindings = false

    func withLoadingRemoteProfile<T>(_ block: () throws -> T) rethrows -> T {
        isLoadingRemoteProfile = true
        defer { isLoadingRemoteProfile = false }
        return try block()
    }

    func withResettingBindings<T>(_ block: () throws -> T) rethrows -> T {
        isResettingBindings = true
        defer { isResettingBindings = false }
        return try block()
    }

    // Session-only routing: a fresh launch still opens the General page.
    var completedOnboardingDestination: SettingsSection = .general

    @Published var onboardingPurpose: OnboardingPurpose {
        didSet { defaults.set(onboardingPurpose.rawValue, forKey: Keys.onboardingPurpose) }
    }

    @Published var onboardingCompletedVersion: Int {
        didSet {
            defaults.set(onboardingCompletedVersion, forKey: Keys.onboardingCompletedVersion)
        }
    }

    @Published var onboardingStep: OnboardingStep {
        didSet { defaults.set(onboardingStep.rawValue, forKey: Keys.onboardingStep) }
    }

    @Published var onboardingRemoteAvailability: OnboardingRemoteAvailability

    var onboardingControlMethod: OnboardingControlMethod {
        onboardingControlSource.controlMethod
    }

    @Published var onboardingDevice: RemoteSetupDevice? {
        didSet { defaults.set(onboardingDevice?.rawValue, forKey: Keys.onboardingDevice) }
    }

    @Published var onboardingControlSource: OnboardingControlSource {
        didSet {
            defaults.set(onboardingControlSource.rawValue, forKey: Keys.onboardingControlSource)
        }
    }

    @Published var onboardingVoiceTool: OnboardingVoiceTool {
        didSet { defaults.set(onboardingVoiceTool.rawValue, forKey: Keys.onboardingVoiceTool) }
    }

    @Published var bypassInputSourceSwitching: Bool {
        didSet { defaults.set(bypassInputSourceSwitching, forKey: Keys.bypassInputSourceSwitching) }
    }

    @Published var onboardingPreferredGesture: VoiceGestureMode? {
        didSet {
            defaults.set(onboardingPreferredGesture?.rawValue, forKey: Keys.onboardingPreferredGesture)
        }
    }

    @Published var verifiedVoiceToolBinding: VoiceToolUserBinding? {
        didSet {
            if let verifiedVoiceToolBinding,
               let data = try? JSONEncoder().encode(verifiedVoiceToolBinding) {
                defaults.set(data, forKey: Keys.onboardingVerifiedVoiceBinding)
            } else {
                defaults.removeObject(forKey: Keys.onboardingVerifiedVoiceBinding)
            }
        }
    }

    @Published var onboardingVoiceTrigger: VoiceTriggerConfiguration? {
        didSet {
            if let onboardingVoiceTrigger, let data = try? JSONEncoder().encode(onboardingVoiceTrigger) {
                defaults.set(data, forKey: Keys.onboardingVoiceTrigger)
            } else { defaults.removeObject(forKey: Keys.onboardingVoiceTrigger) }
        }
    }

    var selectedVoiceTrigger: VoiceTriggerConfiguration {
        onboardingVoiceTrigger ?? VoiceTriggerConfiguration(
            voiceKeyMode: voiceKeyMode, voiceFnTapModeEnabled: voiceFnTapModeEnabled)
    }

    var isTestingVoiceTrigger: Bool {
        guard !isOnboardingComplete, onboardingStep == .voiceTest,
              let binding = stagedVoiceToolBinding else { return false }
        return binding.tool == onboardingVoiceTool && binding.validationState == .staged
    }

    var effectiveVoiceKeyMode: VoiceKeyMode {
        isTestingVoiceTrigger ? (stagedVoiceToolBinding?.shortcut ?? voiceKeyMode) : voiceKeyMode
    }

    var effectiveVoiceFnTapModeEnabled: Bool {
        guard isTestingVoiceTrigger, let binding = stagedVoiceToolBinding else { return voiceFnTapModeEnabled }
        return binding.gestureMode == .toggle
    }

    @Published var stagedVoiceToolBinding: VoiceToolUserBinding?

    var isOnboardingComplete: Bool {
        onboardingCompletedVersion >= Self.currentOnboardingVersion
    }

    /// Keys whose stored data existed but could not be decoded on the last load. The raw
    /// bytes are preserved under "<key>.corrupt" so a reset is recoverable and visible
    /// instead of looking like a first run.
    @Published private(set) var corruptedSettingKeys: [String] = []

    /// Splits "never saved" from "saved but unreadable". Only the latter is a fault, and
    /// silently treating it as a first run is what let user configuration disappear.
    /// Static because callers run inside `init` before the instance is fully formed.
    private static func decodeSetting<T: Decodable>(
        _ type: T.Type,
        forKey key: String,
        from defaults: UserDefaults,
        corrupted: inout [String]
    ) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            defaults.set(data, forKey: "\(key).corrupt")
            defaults.removeObject(forKey: key)
            corrupted.append(key)
            AppLogger.shared.write(
                "SETTINGS decode_failed category=\(diagnosticSettingCategory(key)) " +
                "bytes=\(data.count) reason=\(diagnosticDecodeReason(error))"
            )
            if let event = PublicDiagnosticEvent(
                component: "settings", action: "load", phase: "failed", result: "defaults_applied",
                reason: "\(diagnosticSettingCategory(key))_\(diagnosticDecodeReason(error))", source: "app"
            ) { AppLogger.shared.record(event) }
            return nil
        }
    }

    static func diagnosticSettingCategory(_ key: String) -> String {
        switch key {
        case "remoteDeviceProfiles": "remote_profiles"
        case "buttonBindings", "buttonShortcuts", "buttonApplicationProfileIDs",
             "buttonURLs", "secondaryButtonBindings":
            "button_mapping"
        case "customApplicationProfiles": "custom_apps"
        case "onboarding.stagedVoiceBinding": "onboarding"
        default: "other"
        }
    }

    static func diagnosticDecodeReason(_ error: Error) -> String {
        switch error {
        case DecodingError.dataCorrupted: "data_corrupted"
        case DecodingError.keyNotFound: "key_missing"
        case DecodingError.typeMismatch: "type_mismatch"
        case DecodingError.valueNotFound: "value_missing"
        default: "unknown"
        }
    }

    static func normalizedGain(_ value: Double) -> Double {
        value.isFinite ? min(24, max(0, value)) : 10
    }

    init(defaults: UserDefaults = .standard) {
        let disabled = Set(defaults.stringArray(forKey: Keys.disabledApplicationIntegrations) ?? [])
            .intersection(Self.allApplicationIntegrationIdentifiers)
        enabledApplicationIntegrations = Self.allApplicationIntegrationIdentifiers.subtracting(disabled)
        var corruptedKeys: [String] = []
        self.defaults = defaults
        Self.discardInterruptedOnboardingTrial(in: defaults)
        remoteDeviceProfiles = []
        selectedRemoteProfileID = nil
        storedGainDB = defaults.object(forKey: Keys.gainDB) == nil
            ? 10.0
            : Self.normalizedGain(defaults.double(forKey: Keys.gainDB))
        customMappingEnabled = defaults.bool(forKey: Keys.customMappingEnabled)

        if let decoded = Self.decodeSetting(
            [String: ButtonAction].self,
            forKey: Keys.buttonBindings,
            from: defaults,
            corrupted: &corruptedKeys
        ) {
            buttonBindings = Self.defaultBindings.merging(
                Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in
                    RemoteButton(rawValue: key).map { ($0, value) }
                })
            ) { _, saved in saved }
        } else {
            buttonBindings = Self.defaultBindings
        }

        if let decoded = Self.decodeSetting(
            [String: CustomKeyboardShortcut].self,
            forKey: Keys.buttonShortcuts,
            from: defaults,
            corrupted: &corruptedKeys
        ) {
            buttonShortcuts = Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in
                RemoteButton(rawValue: key).map { ($0, value) }
            })
        } else {
            buttonShortcuts = [:]
        }

        if let decoded = Self.decodeSetting(
            [String: UUID].self,
            forKey: Keys.buttonApplicationProfileIDs,
            from: defaults,
            corrupted: &corruptedKeys
        ) {
            buttonApplicationProfileIDs = Dictionary(
                uniqueKeysWithValues: decoded.compactMap { key, value in
                    RemoteButton(rawValue: key).map { ($0, value) }
                }
            )
        } else {
            buttonApplicationProfileIDs = [:]
        }

        if let decoded = Self.decodeSetting(
            [String: String].self,
            forKey: Keys.buttonURLs,
            from: defaults,
            corrupted: &corruptedKeys
        ) {
            buttonURLs = Dictionary(
                uniqueKeysWithValues: decoded.compactMap { key, value in
                    RemoteButton(rawValue: key).map { ($0, value) }
                }
            )
        } else {
            buttonURLs = [:]
        }

        let shouldSeedSecondaryBindings = defaults.object(forKey: Keys.secondaryButtonBindings) == nil &&
            defaults.object(forKey: Keys.buttonBindings) == nil &&
            defaults.object(forKey: Keys.remoteDeviceProfiles) == nil
        if let decoded = Self.decodeSetting(
            [String: [String: ConfiguredButtonAction]].self,
            forKey: Keys.secondaryButtonBindings,
            from: defaults,
            corrupted: &corruptedKeys
        ) {
            secondaryButtonBindings = Dictionary(uniqueKeysWithValues: decoded.compactMap { buttonKey, bindings in
                guard let button = RemoteButton(rawValue: buttonKey) else { return nil }
                let parsed = Dictionary(uniqueKeysWithValues: bindings.compactMap { triggerKey, binding in
                    ButtonTrigger(rawValue: triggerKey).map { ($0, binding) }
                })
                return parsed.isEmpty ? nil : (button, parsed)
            })
        } else {
            // Seed the new long-press default only when no mappings have been saved.
            // An absent OK binding in an existing configuration must stay disabled.
            secondaryButtonBindings = shouldSeedSecondaryBindings ? Self.defaultSecondaryBindings : [:]
        }

        customApplicationProfiles = Self.decodeSetting(
            [CustomApplicationProfile].self,
            forKey: Keys.customApplicationProfiles,
            from: defaults,
            corrupted: &corruptedKeys
        ) ?? []

        applicationLanguage = AppLanguage(
            rawValue: defaults.string(forKey: Keys.applicationLanguage) ?? ""
        ) ?? .system
        let storedAppIcon = AppIconIdentifier(
            rawValue: defaults.string(forKey: Keys.appIconIdentifier)
                ?? AppIconIdentifier.standard.rawValue
        )
        appIconIdentifier = storedAppIcon
        showDockIcon = defaults.bool(forKey: Keys.showDockIcon)
        showStatusBarIcon = defaults.object(forKey: Keys.showStatusBarIcon) == nil
            ? true
            : defaults.bool(forKey: Keys.showStatusBarIcon)
        openMainWindowAtLaunch = defaults.object(forKey: Keys.openMainWindowAtLaunch) == nil
            ? true
            : defaults.bool(forKey: Keys.openMainWindowAtLaunch)
        receiveUpdateNotifications = defaults.object(forKey: Keys.receiveUpdateNotifications) == nil
            ? true
            : defaults.bool(forKey: Keys.receiveUpdateNotifications)
        diagnosticLoggingEnabled = defaults.object(forKey: Keys.diagnosticLoggingEnabled) == nil
            ? true
            : defaults.bool(forKey: Keys.diagnosticLoggingEnabled)
        g9n9nBluetoothLogRecoveryEnabled = defaults.bool(forKey: Keys.g9n9nBluetoothLogRecoveryEnabled)
        voiceFnTapModeEnabled = defaults.bool(forKey: Keys.voiceFnTapModeEnabled)
        voiceKeyMode = VoiceKeyMode(
            rawValue: defaults.string(forKey: Keys.voiceKeyMode) ?? ""
        ) ?? .suggestedShortcut
        let storedVoiceAutoStopMinutes = (defaults.object(forKey: Keys.voiceAutoStopMinutes) as? NSNumber)?.intValue
        voiceAutoStopDuration = storedVoiceAutoStopMinutes
            .flatMap(VoiceAutoStopDuration.init(rawValue:)) ?? .fiveMinutes
        onboardingPurpose = defaults.string(forKey: Keys.onboardingPurpose)
            .flatMap(OnboardingPurpose.init(rawValue:)) ?? .initialSetup
        onboardingCompletedVersion = defaults.integer(forKey: Keys.onboardingCompletedVersion)
        onboardingStep = defaults.string(forKey: Keys.onboardingStep)
            .flatMap(OnboardingStep.init(rawValue:)) ?? .permissions
        let persistedControlSource = defaults.string(forKey: Keys.onboardingControlSource)
            .flatMap(OnboardingControlSource.init(rawValue:))
            .flatMap { OnboardingBuildCapabilities.availableControlSources.contains($0) ? $0 : nil }
            ?? .unselected
        onboardingControlSource = persistedControlSource
        onboardingDevice = defaults.string(forKey: Keys.onboardingDevice)
            .flatMap(RemoteSetupDevice.init(rawValue:))
            ?? RemoteSetupDevice.device(for: persistedControlSource)
        onboardingRemoteAvailability = persistedControlSource == .unselected ? .unselected : .hasRemote
        onboardingVoiceTool = defaults.string(forKey: Keys.onboardingVoiceTool)
            .flatMap(OnboardingVoiceTool.init(rawValue:)) ?? .unselected
        bypassInputSourceSwitching = defaults.bool(forKey: Keys.bypassInputSourceSwitching)
        onboardingPreferredGesture = defaults.string(forKey: Keys.onboardingPreferredGesture)
            .flatMap(VoiceGestureMode.init(rawValue:))
        verifiedVoiceToolBinding = Self.decodeSetting(
            VoiceToolUserBinding.self,
            forKey: Keys.onboardingVerifiedVoiceBinding,
            from: defaults,
            corrupted: &corruptedKeys
        )
        onboardingVoiceTrigger = Self.decodeSetting(
            VoiceTriggerConfiguration.self, forKey: Keys.onboardingVoiceTrigger,
            from: defaults, corrupted: &corruptedKeys)
        stagedVoiceToolBinding = Self.decodeSetting(
            VoiceToolUserBinding.self,
            forKey: Keys.onboardingStagedVoiceBinding,
            from: defaults,
            corrupted: &corruptedKeys
        )
        if
            let decoded = Self.decodeSetting(
                [RemoteDeviceProfile].self,
                forKey: Keys.remoteDeviceProfiles,
                from: defaults,
                corrupted: &corruptedKeys
            ),
            !decoded.isEmpty
        {
            remoteDeviceProfiles = decoded
            if let event = PublicDiagnosticEvent(
                component: "settings", action: "load", phase: "completed", result: "loaded",
                reason: "remote_profiles", source: "app"
            ) { AppLogger.shared.record(event) }
            let savedID = defaults.string(forKey: Keys.selectedRemoteProfileID).flatMap(UUID.init(uuidString:))
            selectedRemoteProfileID = decoded.contains(where: { $0.id == savedID })
                ? savedID
                : decoded.first?.id
            if let selectedRemoteProfileID,
               let selected = decoded.first(where: { $0.id == selectedRemoteProfileID }) {
                if let storedGain = selected.gainDB, storedGain.isFinite, (0...24).contains(storedGain) { gainDB = storedGain }
                buttonBindings = Self.defaultMappings(for: selected.model).parsedButtonBindings.merging(selected.mappings.parsedButtonBindings) {
                    _, saved in saved
                }
                buttonShortcuts = selected.mappings.parsedButtonShortcuts
                buttonApplicationProfileIDs = selected.mappings.parsedButtonApplicationProfileIDs
                buttonURLs = selected.mappings.parsedButtonURLs
                secondaryButtonBindings = selected.mappings.parsedSecondaryButtonBindings
            }
        }
        corruptedSettingKeys = corruptedKeys
        if shouldSeedSecondaryBindings { saveSecondaryBindings() }
    }
}
