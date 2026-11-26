import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import RemoteBuddy

@Suite("G9N9N partial-support compatibility mode")
@MainActor
struct G9N9NCompatibilityModeTests {
    @Test func enterChordRecognizesOkWithAnyDirectionOnly() {
        let ok = RemoteButton.ok.hidUsage
        for arrow in [RemoteButton.up, .down, .left, .right] {
            #expect(G9N9NProtocol.isEnterChord([ok, arrow.hidUsage]))
        }
        #expect(!G9N9NProtocol.isEnterChord([ok]))
        #expect(!G9N9NProtocol.isEnterChord([ok, RemoteButton.back.hidUsage]))
        #expect(!G9N9NProtocol.isEnterChord([RemoteButton.up.hidUsage, RemoteButton.down.hidUsage]))
        #expect(!G9N9NProtocol.isEnterChord([ok, RemoteButton.up.hidUsage, RemoteButton.down.hidUsage]))
    }

    @Test func settingsPersistCompatibilityModePerChromecastProfileOnly() throws {
        let suite = "g9n9n-mode-persist-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.onboardingPurpose = .addDevice
        let googleID = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        let xiaomiID = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)

        #expect(settings.g9n9nInputMode(for: googleID) == .full)
        settings.setG9N9NInputMode(.twoKeyCompatibility, for: googleID)
        settings.setG9N9NInputMode(.twoKeyCompatibility, for: xiaomiID)

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.g9n9nInputMode(for: googleID) == .twoKeyCompatibility)
        #expect(reloaded.g9n9nInputMode(for: xiaomiID) == .full)

        // Completed setup or integration-only flow cannot mutate compatibility mode arbitrarily.
        reloaded.completeOnboarding()
        reloaded.setG9N9NInputMode(.full, for: googleID)
        #expect(reloaded.g9n9nInputMode(for: googleID) == .twoKeyCompatibility)

        SettingsPageBehavior.beginIntegrationSetup(tool: .doubao, settings: reloaded)
        reloaded.setG9N9NInputMode(.full, for: googleID)
        #expect(reloaded.g9n9nInputMode(for: googleID) == .twoKeyCompatibility)

        SettingsPageBehavior.beginDeviceSetup(settings: reloaded)
        reloaded.setG9N9NInputMode(.full, for: googleID)
        #expect(AppSettings(defaults: defaults).g9n9nInputMode(for: googleID) == .full)
    }

    @Test func partialSupportModeBlocksAllMappingEditsAndResetsUntilRestoredToFull() throws {
        let suite = "g9n9n-mode-lock-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.onboardingPurpose = .initialSetup
        let googleID = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        settings.selectRemoteProfile(googleID)
        settings.setAction(.escape, for: .ok, trigger: .singleClick)
        settings.setG9N9NInputMode(.twoKeyCompatibility, for: googleID)
        settings.completeOnboarding()

        #expect(!settings.allowsMappingEdits(for: googleID))
        let shortcut = CustomKeyboardShortcut(keyCode: 9, modifierFlags: [.command], keyLabel: "V")
        settings.setAction(.deleteBackward, for: .ok, trigger: .singleClick)
        settings.setAction(.volumeUp, for: .ok, trigger: .doubleClick)
        settings.setShortcut(shortcut, for: .ok, trigger: .singleClick)
        settings.setBaseBinding(
            ConfiguredButtonAction(action: .returnKey, shortcut: nil),
            for: .up,
            trigger: .singleClick,
            profileID: googleID
        )
        settings.resetBindings()

        #expect(settings.action(for: .ok, profileID: googleID) == .escape)
        #expect(settings.configuredAction(for: .ok, trigger: .doubleClick, profileID: googleID).action == .disabled)
        #expect(settings.shortcut(for: .ok, profileID: googleID) == nil)
        #expect(settings.action(for: .up, profileID: googleID) == .arrowUp)

        SettingsPageBehavior.beginDeviceSetup(settings: settings)
        settings.setG9N9NInputMode(.full, for: googleID)
        settings.completeOnboarding()
        #expect(settings.allowsMappingEdits(for: googleID))
        settings.setAction(.deleteBackward, for: .ok, trigger: .singleClick)
        #expect(settings.action(for: .ok, profileID: googleID) == .deleteBackward)
    }

    @Test func onboardingDetectionRequiresExplicitOptInBeforeAcceptingTwoKeyCombos() {
        let combo: Set<RemoteButton> = [.up, .ok]
        #expect(
            ChromecastCompatibilityDetection.evaluate(
                step: .remote,
                buttons: combo,
                singleKeyObserved: false,
                compatibilityModeEnabled: false
            ) == .awaitCompatibilityOptIn(buttons: combo)
        )
        #expect(
            ChromecastCompatibilityDetection.evaluate(
                step: .remote,
                buttons: combo,
                singleKeyObserved: false,
                compatibilityModeEnabled: true
            ) == .recordCompatibilityMode(buttons: combo)
        )
        #expect(
            ChromecastCompatibilityDetection.evaluate(
                step: .remote,
                buttons: [.ok],
                singleKeyObserved: false,
                compatibilityModeEnabled: true
            ) == .recordFullMode(buttons: [.ok])
        )
        #expect(
            ChromecastCompatibilityDetection.evaluate(
                step: .controls,
                buttons: [.ok, .back],
                singleKeyObserved: false,
                compatibilityModeEnabled: true
            ) == .controlsNonChordObserved(buttons: [.ok, .back])
        )
        #expect(
            ChromecastCompatibilityDetection.evaluate(
                step: .controls,
                buttons: [.up, .ok],
                singleKeyObserved: false,
                compatibilityModeEnabled: true
            ) == .controlsChordConfirmed(buttons: [.up, .ok])
        )
    }

    @Test func compatibilityOptInCardShowsOnRemoteUntilSingleKeyConfirmation() {
        #expect(ChromecastCompatibilityDetection.shouldShowCompatibilityOptInCard(
            step: .remote,
            source: .chromecastRemote,
            singleKeyObserved: false
        ))
        #expect(!ChromecastCompatibilityDetection.shouldShowCompatibilityOptInCard(
            step: .remote,
            source: .chromecastRemote,
            singleKeyObserved: true
        ))
        #expect(!ChromecastCompatibilityDetection.shouldShowCompatibilityOptInCard(
            step: .controls,
            source: .chromecastRemote,
            singleKeyObserved: false
        ))
        #expect(!ChromecastCompatibilityDetection.shouldShowCompatibilityOptInCard(
            step: .remote,
            source: .xiaomiRemote,
            singleKeyObserved: false
        ))
    }

    @Test func compatibilityControlsGatePassesWithOneEnterChordWithoutBypassingPermissions() {
        var capabilities = OnboardingCapabilities(
            bluetoothGranted: true,
            inputMonitoringGranted: true,
            accessibilityGranted: true,
            remoteConnected: true,
            remoteButtonObserved: true,
            isTwoKeyCompatibleMode: true,
            compatibleChordConfirmed: false
        )
        let context = FirstUseDiagnosticContext(
            step: .controls,
            remoteAvailability: .hasRemote,
            controlMethod: .physicalRemote,
            capabilities: capabilities,
            hasSelectedAudioUID: true
        )
        #expect(context.failureReason == .controlsNotConfirmed)
        #expect(!OnboardingFlowPolicy.canContinue(
            from: .controls,
            voiceTool: .doubao,
            selectedDevice: .chromecastG9N9N,
            capabilities: capabilities
        ))

        capabilities.compatibleChordConfirmed = true
        #expect(OnboardingFlowPolicy.canContinue(
            from: .controls,
            voiceTool: .doubao,
            selectedDevice: .chromecastG9N9N,
            capabilities: capabilities
        ))

        let summary = OnboardingCompletionSummary(
            purpose: .initialSetup,
            remoteName: "Chromecast Remote",
            buttonsVerified: true,
            microphoneReady: true,
            voiceKeyMode: .function,
            tapModeEnabled: false,
            voiceTool: .doubao,
            binding: nil,
            isPartialSupportG9N9N: true
        )
        #expect(summary.isPartialSupportG9N9N)
        #expect(summary.buttonsVerified == true)
    }

    @Test func compatibilityModeRuntimeEmitsEnterForDirectionPlusOkEvenWithoutReleasesOrSeize() throws {
        let suite = "g9n9n-compat-runtime-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        let profileID = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        settings.selectRemoteProfile(profileID)
        settings.setG9N9NInputMode(.twoKeyCompatibility, for: profileID)
        settings.completeOnboarding()

        let clock = ControlledTestScheduler()
        var actions: [ButtonAction] = []
        var nativeFilterAvailable = true
        let monitor = HIDRemoteMonitor(
            settings: settings,
            profileID: profileID,
            scheduler: clock,
            runtimePermissions: { true },
            nativeSuppressionAvailable: { nativeFilterAvailable },
            actionPerformer: { _, _, configured in
                actions.append(configured.action)
                return true
            },
            diagnosticLogger: { _ in }
        )
        let descriptor = G9N9NProtocol.indexedConsumerDescriptor
        monitor.connectSimulatedDevice(fingerprint: "google", profileID: profileID, isSeized: false)
        defer { monitor.disconnectSimulatedDevice() }

        // Repeated direction+OK presses emit single Returns with no release reports and no held repeat.
        monitor.handleSimulatedGoogleReport(reportID: 1, data: Data([1, 3, 7]), descriptor: descriptor)
        monitor.handleSimulatedGoogleReport(reportID: 1, data: Data([1, 7, 3]), descriptor: descriptor)
        monitor.handleSimulatedGoogleReport(reportID: 1, data: Data([1, 7, 4]), descriptor: descriptor)
        clock.advance(to: 5_000)
        #expect(actions == [.returnKey, .returnKey, .returnKey])

        // Single keys and non-arrow combos are ignored safely in partial-support mode.
        monitor.handleSimulatedGoogleReport(reportID: 1, data: Data([1, 7, 0]), descriptor: descriptor)
        monitor.handleSimulatedGoogleReport(reportID: 1, data: Data([1, 3, 0]), descriptor: descriptor)
        monitor.handleSimulatedGoogleReport(reportID: 1, data: Data([1, 7, 11]), descriptor: descriptor)
        #expect(actions.count == 3)

        // Unseized fallback without an active native suppression tap pauses safely instead of double-firing.
        nativeFilterAvailable = false
        monitor.handleSimulatedGoogleReport(reportID: 1, data: Data([1, 7, 3]), descriptor: descriptor)
        #expect(actions.count == 3)

        // Re-running Add Device setup to restore full mode unlocks single-button mapping.
        nativeFilterAvailable = true
        SettingsPageBehavior.beginDeviceSetup(settings: settings)
        settings.setG9N9NInputMode(.full, for: profileID)
        settings.completeOnboarding()
        settings.setAction(.escape, for: .ok, trigger: .singleClick)
        settings.setAction(.disabled, for: .ok, trigger: .doubleClick)
        settings.setAction(.disabled, for: .ok, trigger: .longPress)
        monitor.handleSimulatedGoogleReport(reportID: 1, data: Data([1, 7, 0]), descriptor: descriptor)
        monitor.handleSimulatedGoogleReport(reportID: 1, data: Data([1, 0, 0]), descriptor: descriptor)
        #expect(actions.last == .escape)
    }

    @Test func compatibilityModeSuppressesEnterDuringOnboardingAndAllowsRepeatedCombos() throws {
        let suite = "g9n9n-compat-onboarding-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        settings.onboardingStep = .controls
        settings.onboardingControlSource = .chromecastRemote
        let profileID = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        settings.selectRemoteProfile(profileID)
        settings.setG9N9NInputMode(.twoKeyCompatibility, for: profileID)

        var actions: [ButtonAction] = []
        var observedCombos: [Set<RemoteButton>] = []
        let monitor = HIDRemoteMonitor(
            settings: settings,
            profileID: profileID,
            runtimePermissions: { true },
            actionPerformer: { _, _, configured in
                actions.append(configured.action)
                return true
            },
            diagnosticLogger: { _ in }
        )
        monitor.onboardingWindowIsActive = { true }
        monitor.onActiveButtons = { _, buttons in
            if !buttons.isEmpty { observedCombos.append(buttons) }
        }
        monitor.connectSimulatedDevice(fingerprint: "google", profileID: profileID)
        defer { monitor.disconnectSimulatedDevice() }

        let descriptor = G9N9NProtocol.indexedConsumerDescriptor
        monitor.handleSimulatedGoogleReport(reportID: 1, data: Data([1, 7, 3]), descriptor: descriptor)
        monitor.handleSimulatedGoogleReport(reportID: 1, data: Data([1, 7, 3]), descriptor: descriptor)
        #expect(actions.isEmpty)
        #expect(observedCombos == [[.ok, .up], [.ok, .up]])
    }

    @Test func unseizedCompatibilityModeSuppressesNativeEventsOnSetupAndUnsupportedReports() throws {
        let suite = "g9n9n-compat-suppress-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        settings.onboardingControlSource = .chromecastRemote
        let profileID = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        settings.selectRemoteProfile(profileID)
        settings.setG9N9NInputMode(.twoKeyCompatibility, for: profileID)

        var now: TimeInterval = 0
        let suppressor = KeyboardEventSuppressor(uptime: { now })
        var actions: [ButtonAction] = []
        let monitor = HIDRemoteMonitor(
            settings: settings,
            profileID: profileID,
            eventSuppressor: suppressor,
            runtimePermissions: { true },
            nativeSuppressionAvailable: { true },
            actionPerformer: { _, _, configured in
                actions.append(configured.action)
                return true
            },
            diagnosticLogger: { _ in }
        )
        monitor.onboardingWindowIsActive = { true }
        monitor.connectSimulatedDevice(fingerprint: "google", profileID: profileID, isSeized: false)
        defer { monitor.disconnectSimulatedDevice() }

        func keyEvent(_ keyCode: CGKeyCode, keyDown: Bool) throws -> CGEvent {
            try #require(CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: keyDown))
        }

        let descriptor = G9N9NProtocol.indexedConsumerDescriptor
        for step in [OnboardingStep.remote, .controls] {
            settings.onboardingStep = step
            monitor.handleSimulatedGoogleReport(reportID: 1, data: Data([1, 7, 3]), descriptor: descriptor)
            #expect(suppressor.handle(type: .keyDown, event: try keyEvent(126, keyDown: true)))
            #expect(suppressor.handle(type: .keyDown, event: try keyEvent(36, keyDown: true)))
            #expect(suppressor.handle(type: .keyUp, event: try keyEvent(126, keyDown: false)))
            #expect(suppressor.handle(type: .keyUp, event: try keyEvent(36, keyDown: false)))
            #expect(!suppressor.handle(type: .keyUp, event: try keyEvent(126, keyDown: false)))
        }
        #expect(actions.isEmpty)

        settings.completeOnboarding()
        monitor.handleSimulatedGoogleReport(reportID: 1, data: Data([1, 7, 11]), descriptor: descriptor)
        #expect(actions.isEmpty)
        #expect(suppressor.handle(type: .keyDown, event: try keyEvent(36, keyDown: true)))

        // Stale pending/suppressed tokens expire after 30 seconds without waiting on wall clock time.
        now = 31
        #expect(!suppressor.handle(type: .keyUp, event: try keyEvent(36, keyDown: false)))
        #expect(!suppressor.handle(type: .keyDown, event: try keyEvent(36, keyDown: true)))
    }

    @Test func backgroundGoogleTwoKeyComboPreservesFullComboAcrossSelectionSwitch() throws {
        let suite = "g9n9n-background-switch-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        settings.onboardingPurpose = .initialSetup
        settings.onboardingStep = .remote
        settings.setOnboardingControlSource(.chromecastRemote)

        let xiaomiID = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        let googleID = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        settings.selectRemoteProfile(xiaomiID)

        let model = BridgeAppModel(settings: settings, initialAudioDevices: [])
        let monitor = model.makeHIDMonitor(profileID: googleID, targetFingerprint: nil, runtimePermissions: { true })
        monitor.connectSimulatedDevice(fingerprint: "google", profileID: googleID)
        defer { monitor.disconnectSimulatedDevice() }

        // Background G9N9N sends Direction + OK while Xiaomi is still selected:
        // onButtonPressed switches selectedRemoteProfileID to googleID and updates lastRemoteButtonPress
        // with one representative button, while onObservedButtonReport still delivers the full 2-key combo.
        monitor.handleSimulatedGoogleReport(
            reportID: 1,
            data: Data([1, 7, 3]),
            descriptor: G9N9NProtocol.indexedConsumerDescriptor
        )

        #expect(settings.selectedRemoteProfileID == googleID)
        let observation = try #require(model.lastObservedRemoteButtonReport)
        #expect(observation == RemoteButtonObservation(profileID: googleID, buttons: [.up, .ok]))
        #expect(model.activeRemoteButtons.isEmpty)

        // When onboarding evaluates that full report, it detects a 2-key combo awaiting opt-in rather than 1-key proof.
        #expect(
            ChromecastCompatibilityDetection.evaluate(
                step: .remote,
                buttons: observation.buttons,
                singleKeyObserved: false,
                compatibilityModeEnabled: false
            ) == .awaitCompatibilityOptIn(buttons: [.up, .ok])
        )
    }

    @Test func dismissingAddDeviceOnboardingRestoresExistingChromecastCompatibilityMode() throws {
        let suite = "g9n9n-dismiss-restore-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        settings.onboardingPurpose = .initialSetup
        let googleID = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        settings.selectRemoteProfile(googleID)
        settings.setG9N9NInputMode(.full, for: googleID)
        settings.completeOnboarding()
        #expect(settings.allowsMappingEdits(for: googleID))

        SettingsPageBehavior.beginDeviceSetup(settings: settings)
        settings.setG9N9NInputMode(.twoKeyCompatibility, for: googleID)
        #expect(settings.g9n9nInputMode(for: googleID) == .twoKeyCompatibility)

        // Simulate relaunch/reload before cancelling Add Device onboarding.
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.g9n9nInputMode(for: googleID) == .twoKeyCompatibility)
        reloaded.dismissOnboarding()

        #expect(reloaded.g9n9nInputMode(for: googleID) == .full)
        #expect(reloaded.allowsMappingEdits(for: googleID))
        #expect(AppSettings(defaults: defaults).g9n9nInputMode(for: googleID) == .full)
    }

    @Test func g9n9nCompatibilityGuideLinkTargetsLocalizedWebsitePages() {
        #expect(
            AppLinks.g9n9nCompatibilityGuide(for: Locale(identifier: "zh_CN")).absoluteString
                == "https://remote.zfdang.com/g9n9n-compatibility.html"
        )
        #expect(
            AppLinks.g9n9nCompatibilityGuide(for: Locale(identifier: "en_US")).absoluteString
                == "https://remote.zfdang.com/g9n9n-compatibility_en.html"
        )
    }

    @Test func cancellingAddDeviceDoesNotUpgradeNewlyAddedPartialSupportProfile() throws {
        let suite = "g9n9n-dismiss-fresh-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        let xiaomiID = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        settings.selectRemoteProfile(xiaomiID)
        settings.completeOnboarding()

        SettingsPageBehavior.beginDeviceSetup(settings: settings)
        let freshGoogleID = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        settings.selectRemoteProfile(freshGoogleID)
        settings.setG9N9NInputMode(.twoKeyCompatibility, for: freshGoogleID)

        settings.dismissOnboarding()
        #expect(
            !settings.remoteDeviceProfiles.contains { $0.id == freshGoogleID } ||
                settings.g9n9nInputMode(for: freshGoogleID) == .twoKeyCompatibility
        )
    }

    @Test func switchingChromecastProfilesClearsPriorSingleKeyProofInOnboarding() async throws {
        let suite = "g9n9n-profile-proof-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        let first = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        let second = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        settings.selectRemoteProfile(first)
        settings.setOnboardingControlSource(.chromecastRemote)
        settings.onboardingStep = .remote
        settings.onboardingPurpose = .addDevice

        let mapper = RemoteHIDKeyMapper(serviceProvider: { [] }, recoveryDefaults: defaults)
        let model = BridgeAppModel(settings: settings, initialAudioDevices: [], voiceFunctionMapper: mapper)
        model.isConnected = true
        model.connectedRemoteProfileIDs = [first, second]
        let probe = OnboardingInteractionProbe(openURL: { _ in })
        let view = OnboardingView(
            model: model,
            allowsInputSourceSwitching: false,
            allowsHardwareMonitoring: false,
            interactionProbe: probe,
            permissionOverrides: .allGranted
        )
        .environmentObject(LocalizationStore(settings: settings))
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 850),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        try await waitForTestCondition("onboarding registers Continue action") { probe.actions["continue"] != nil }
        _ = try #require(probe.actions["continue"])

        // Confirm single-key proof on first unit, then switch to second unit and send a 2-key combo.
        model.lastObservedRemoteButtonReport = RemoteButtonObservation(profileID: first, buttons: [.ok])
        try await waitForTestCondition("onboarding handles first device single-key proof") {
            probe.lastHandledRemoteReport == RemoteButtonObservation(profileID: first, buttons: [.ok])
        }
        settings.selectRemoteProfile(second)
        model.lastObservedRemoteButtonReport = RemoteButtonObservation(profileID: second, buttons: [.ok, .up])
        try await waitForTestCondition("onboarding handles second device chord") {
            probe.lastHandledRemoteReport == RemoteButtonObservation(profileID: second, buttons: [.ok, .up])
        }

        probe.invoke("continue")
        #expect(settings.onboardingStep == .remote)
    }

    @Test func bluetoothLogRecoveryDefaultsOffPersistsAndRecordsIntegrationMode() throws {
        let suite = "g9n9n-btle-log-opt-in-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        #expect(!settings.g9n9nBluetoothLogRecoveryEnabled)

        settings.onboardingPurpose = .initialSetup
        let googleID = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        settings.setG9N9NInputMode(.twoKeyCompatibility, for: googleID)
        settings.completeOnboarding()

        // Cannot upgrade while opt-in toggle is off.
        #expect(!settings.recordG9N9NBluetoothLogRecoveryIntegration(for: googleID))
        #expect(settings.g9n9nInputMode(for: googleID) == .twoKeyCompatibility)

        settings.g9n9nBluetoothLogRecoveryEnabled = true
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.g9n9nBluetoothLogRecoveryEnabled)
        #expect(reloaded.recordG9N9NBluetoothLogRecoveryIntegration(for: googleID))
        #expect(reloaded.g9n9nInputMode(for: googleID) == .bluetoothLogRecovery)
        #expect(reloaded.allowsMappingEdits(for: googleID))
        #expect(AppSettings(defaults: defaults).g9n9nInputMode(for: googleID) == .bluetoothLogRecovery)

        let summary = OnboardingCompletionSummary(
            purpose: .initialSetup,
            remoteName: "Chromecast Remote",
            buttonsVerified: true,
            microphoneReady: true,
            voiceKeyMode: .suggestedShortcut,
            tapModeEnabled: true,
            voiceTool: .voiceBuddy,
            binding: nil,
            isPartialSupportG9N9N: false,
            g9n9nInputMode: .bluetoothLogRecovery
        )
        #expect(summary.g9n9nInputMode == .bluetoothLogRecovery)
        #expect(!summary.isPartialSupportG9N9N)

        // Native IOHID single-key recovery resets the profile back to standard full mode.
        #expect(reloaded.recordG9N9NNativeIOHIDIntegration(for: googleID))
        #expect(reloaded.g9n9nInputMode(for: googleID) == .full)
    }
}
