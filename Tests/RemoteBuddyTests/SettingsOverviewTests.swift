import Carbon
import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Settings overview")
struct SettingsOverviewTests {
    private func state(bluetooth: Bool = true, input: Bool = true, accessibility: Bool = true,
                       driver: Bool = true, profiles: [RemoteDeviceProfile] = [], ids: Set<UUID> = [],
                       tool: OnboardingVoiceTool = .unselected,
                       availability: OnboardingVoiceToolAvailability = .available) -> SettingsOverviewState {
        SettingsOverviewState(bluetoothGranted: bluetooth, inputMonitoringGranted: input,
            accessibilityGranted: accessibility,
            audioDevices: driver ? [AudioDeviceInfo(id: 111, uid: BuddyMicrophoneDevicePolicy.deviceUID,
                name: BuddyMicrophoneDevicePolicy.deviceName)] : [],
            profiles: profiles, connectedIDs: ids,
            integrationTool: tool, integrationAvailability: availability, remoteName: { $0.customName })
    }

    @Test func missingDriverPreventsReadyDespiteAllPermissions() {
        #expect(state().permissionsReady)
        #expect(state(driver: false).missingRequirementKeys == ["settings.driver.title"])
        #expect(!state(driver: false).permissionsReady)
        #expect(state(bluetooth: false, input: false, accessibility: false, driver: false)
            .missingRequirementKeys == ["permission.bluetooth.title", "permission.input_monitoring.title",
                "permission.accessibility.title", "settings.driver.title"])
    }

    @Test func connectedNamesExcludeDisconnectedAndUnregisteredDevices() {
        let first = RemoteDeviceProfile(customName: "Study", mappings: .init(buttonBindings: [:], buttonShortcuts: [:], secondaryButtonBindings: [:]))
        let second = RemoteDeviceProfile(customName: "Living room", mappings: .init(buttonBindings: [:], buttonShortcuts: [:], secondaryButtonBindings: [:]))
        #expect(!state(profiles: [first, second]).remoteReady)
        let snapshot = state(profiles: [first, second], ids: [second.id, UUID()])
        #expect(snapshot.remoteReady)
        #expect(snapshot.connectedRemoteNames == ["Living room"])
    }

    @Test func optionalConfigurationDoesNotBlockPrerequisites() {
        let snapshot = state()
        #expect(snapshot.permissionsReady)
        #expect(!snapshot.integrationReady)
        #expect(state(tool: .voiceBuddy).integrationReady)
    }

    @Test func changedPrerequisitesAreReflectedWithoutRestartingOnboarding() {
        let before = state(input: false, driver: false)
        let after = state()
        #expect(!before.permissionsReady)
        #expect(after.permissionsReady)
        #expect(after.missingRequirementKeys.isEmpty)
        #expect(!state(accessibility: false).permissionsReady)
    }

    @Test @MainActor func summariesNameMissingRequirementsAndReflectRepairs() throws {
        let suite = "overview.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let localization = LocalizationStore(settings: AppSettings(defaults: defaults))
        for language in [AppLanguage.english, .simplifiedChinese] {
            localization.select(language)
            let summary = state(input: false, driver: false).permissionsSummary(using: localization)
            #expect(summary.contains(localization.text("permission.input_monitoring.title")))
            #expect(summary.contains(localization.text("settings.driver.title")))
            #expect(!summary.contains("%@"))
            #expect(state().permissionsSummary(using: localization) == localization.text("settings.overview.ready"))
        }
    }

    @Test func listsUseLocale() {
        let chinese = SettingsOverviewState.localizedList(["蓝牙", "辅助功能"], locale: Locale(identifier: "zh_CN"))
        #expect(!chinese.contains(", "))
        #expect(chinese.contains("蓝牙") && chinese.contains("辅助功能"))
    }

    @Test @MainActor func unavailableIntegrationToolIsFlaggedInOverview() throws {
        let suite = "overview.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let localization = LocalizationStore(settings: AppSettings(defaults: defaults))

        let missing = state(tool: .doubao, availability: .notInstalled)
        #expect(missing.integrationMissing)
        #expect(!missing.integrationReady)
        for language in [AppLanguage.english, .simplifiedChinese] {
            localization.select(language)
            let summary = missing.integrationSummary(using: localization)
            #expect(summary.contains(localization.text(OnboardingVoiceTool.doubao.titleKey)))
            #expect(summary != localization.text(OnboardingVoiceTool.doubao.titleKey))
            #expect(!summary.contains("%@"))
        }

        let unselected = state(tool: .unselected, availability: .notInstalled)
        #expect(!unselected.integrationMissing)
        #expect(!unselected.integrationReady)
        #expect(unselected.integrationSummary(using: localization) == localization.text("settings.overview.not_configured"))
    }

    @Test @MainActor func integrationAvailabilityChecksEnabledInputSourcesAndFlowsIntoOverview() {
        var probed: [(String, Bool)] = []
        let installedButDisabled = OnboardingInputSourceSwitcher.integrationAvailability(
            for: .doubao,
            hasInputSource: { id, includeAllInstalled in
                probed.append((id, includeAllInstalled))
                return includeAllInstalled
            }
        )
        #expect(probed.count == 1 && probed[0].0 == OnboardingVoiceTool.doubao.preferredInputSourceID && !probed[0].1)
        #expect(installedButDisabled == .notInstalled)
        #expect(state(tool: .doubao, availability: installedButDisabled).integrationMissing)

        let enabledAvailability = OnboardingInputSourceSwitcher.integrationAvailability(
            for: .doubao,
            hasInputSource: { id, includeAllInstalled in
                !includeAllInstalled && id == OnboardingVoiceTool.doubao.preferredInputSourceID
            }
        )
        #expect(enabledAvailability == .available)
        #expect(state(tool: .doubao, availability: enabledAvailability).integrationReady)

        // Exercise real TIS list scanning on the host input sources.
        #expect(OnboardingInputSourceSwitcher.inputSource(
            withID: "com.example.nonexistent.inputmethod",
            createList: { TISCreateInputSourceList(nil, false) }
        ) == nil)
        if let activeID = OnboardingInputSourceSwitcher.currentInputSourceID() {
            #expect(OnboardingInputSourceSwitcher.inputSource(
                withID: activeID,
                createList: { TISCreateInputSourceList(nil, false) }
            ) != nil)
        }
    }
}
