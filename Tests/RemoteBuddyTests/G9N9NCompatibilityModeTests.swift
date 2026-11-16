import Foundation
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
        let googleID = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        let xiaomiID = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)

        #expect(settings.g9n9nInputMode(for: googleID) == .full)
        settings.setG9N9NInputMode(.twoKeyCompatibility, for: googleID)
        settings.setG9N9NInputMode(.twoKeyCompatibility, for: xiaomiID)

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.g9n9nInputMode(for: googleID) == .twoKeyCompatibility)
        #expect(reloaded.g9n9nInputMode(for: xiaomiID) == .full)

        reloaded.setG9N9NInputMode(.full, for: googleID)
        #expect(AppSettings(defaults: defaults).g9n9nInputMode(for: googleID) == .full)
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

    @Test func compatibilityOptInCardRemainsHiddenInitiallyAndAfterSingleKeyConfirmation() {
        #expect(!ChromecastCompatibilityDetection.shouldShowCompatibilityOptInCard(
            step: .remote,
            source: .chromecastRemote,
            remoteConnected: true,
            singleKeyObserved: false,
            twoKeyDetectedWithoutSingleKey: false,
            compatibilityModeEnabled: false,
            remoteButtonObserved: false,
            waitStartedAtUptime: 100,
            nowUptime: 101
        ))
        #expect(ChromecastCompatibilityDetection.shouldShowCompatibilityOptInCard(
            step: .remote,
            source: .chromecastRemote,
            remoteConnected: true,
            singleKeyObserved: false,
            twoKeyDetectedWithoutSingleKey: false,
            compatibilityModeEnabled: false,
            remoteButtonObserved: false,
            waitStartedAtUptime: 100,
            nowUptime: 104.5
        ))
        #expect(ChromecastCompatibilityDetection.shouldShowCompatibilityOptInCard(
            step: .remote,
            source: .chromecastRemote,
            remoteConnected: true,
            singleKeyObserved: false,
            twoKeyDetectedWithoutSingleKey: true,
            compatibilityModeEnabled: false,
            remoteButtonObserved: false,
            waitStartedAtUptime: 100,
            nowUptime: 100.5
        ))
        #expect(!ChromecastCompatibilityDetection.shouldShowCompatibilityOptInCard(
            step: .remote,
            source: .chromecastRemote,
            remoteConnected: true,
            singleKeyObserved: true,
            twoKeyDetectedWithoutSingleKey: false,
            compatibilityModeEnabled: false,
            remoteButtonObserved: true,
            waitStartedAtUptime: 100,
            nowUptime: 120
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
        settings.onboardingStep = .complete
        let profileID = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        settings.selectRemoteProfile(profileID)
        settings.setG9N9NInputMode(.twoKeyCompatibility, for: profileID)

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

        // Switching the same profile back to full mode restores configurable single-button support.
        nativeFilterAvailable = true
        settings.setG9N9NInputMode(.full, for: profileID)
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
}
