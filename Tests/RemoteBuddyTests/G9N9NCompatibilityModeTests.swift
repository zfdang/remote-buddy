import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import RemoteBuddy

@Suite("G9N9N support modes and Bluetooth log recovery")
@MainActor
struct G9N9NCompatibilityModeTests {
    @Test func settingsPersistTwoSupportModesPerChromecastProfileOnly() throws {
        let suite = "g9n9n-mode-persist-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.onboardingPurpose = .addDevice
        let googleID = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        let xiaomiID = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)

        #expect(settings.g9n9nInputMode(for: googleID) == .full)
        settings.setG9N9NInputMode(.bluetoothLogRecovery, for: googleID)
        settings.setG9N9NInputMode(.bluetoothLogRecovery, for: xiaomiID)

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.g9n9nInputMode(for: googleID) == .bluetoothLogRecovery)
        #expect(reloaded.g9n9nInputMode(for: xiaomiID) == .full)

        // Completed setup or integration-only flow cannot mutate mode via onboarding helper.
        reloaded.completeOnboarding()
        reloaded.setG9N9NInputMode(.full, for: googleID)
        #expect(reloaded.g9n9nInputMode(for: googleID) == .bluetoothLogRecovery)

        SettingsPageBehavior.beginIntegrationSetup(tool: .doubao, settings: reloaded)
        reloaded.setG9N9NInputMode(.full, for: googleID)
        #expect(reloaded.g9n9nInputMode(for: googleID) == .bluetoothLogRecovery)

        SettingsPageBehavior.beginDeviceSetup(settings: reloaded)
        reloaded.setG9N9NInputMode(.full, for: googleID)
        #expect(AppSettings(defaults: defaults).g9n9nInputMode(for: googleID) == .full)
    }

    @Test func onboardingDetectionRequiresSingleKeyProofBeforePassingRemoteStep() {
        let combo: Set<RemoteButton> = [.up, .ok]
        #expect(
            ChromecastOnboardingDetection.evaluate(
                step: .remote,
                buttons: combo,
                singleKeyObserved: false
            ) == .awaitSingleKey(buttons: combo)
        )
        #expect(
            ChromecastOnboardingDetection.evaluate(
                step: .remote,
                buttons: [.ok],
                singleKeyObserved: false
            ) == .recordSingleKey(buttons: [.ok])
        )
        #expect(
            ChromecastOnboardingDetection.evaluate(
                step: .remote,
                buttons: combo,
                singleKeyObserved: true
            ) == .recordSingleKey(buttons: combo)
        )
        #expect(
            ChromecastOnboardingDetection.evaluate(
                step: .controls,
                buttons: [.ok, .back],
                singleKeyObserved: true
            ) == .controlsObserved(buttons: [.ok, .back])
        )

        #expect(ChromecastOnboardingDetection.shouldShowBluetoothLogRecoveryCard(
            step: .remote,
            source: .chromecastRemote,
            singleKeyObserved: false
        ))
        #expect(!ChromecastOnboardingDetection.shouldShowBluetoothLogRecoveryCard(
            step: .remote,
            source: .chromecastRemote,
            singleKeyObserved: true
        ))
        #expect(!ChromecastOnboardingDetection.shouldShowBluetoothLogRecoveryCard(
            step: .controls,
            source: .chromecastRemote,
            singleKeyObserved: false
        ))
        #expect(!ChromecastOnboardingDetection.shouldShowBluetoothLogRecoveryCard(
            step: .remote,
            source: .xiaomiRemote,
            singleKeyObserved: false
        ))
    }

    @Test func btleLogPathDoesNotLogRawPayloadBytes() throws {
        let suite = "g9n9n-no-raw-bytes-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        let googleID = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        settings.selectRemoteProfile(googleID)
        settings.setG9N9NInputMode(.bluetoothLogRecovery, for: googleID)
        settings.completeOnboarding()

        var logs: [String] = []
        let monitor = HIDRemoteMonitor(
            settings: settings,
            profileID: googleID,
            runtimePermissions: { true },
            actionPerformer: { _, _, _ in true },
            diagnosticLogger: { logs.append($0) }
        )
        monitor.connectSimulatedDevice(fingerprint: "google-no-raw", profileID: googleID)
        defer { monitor.disconnectSimulatedDevice() }

        monitor.handleSimulatedGoogleReport(
            reportID: 2,
            data: Data([0x42, 0x00]),
            source: "btle_log",
            origin: .btleServerLog
        )
        monitor.handleSimulatedGoogleReport(
            reportID: 2,
            data: Data([0x00, 0x00]),
            source: "btle_log",
            origin: .btleServerLog
        )

        #expect(!logs.isEmpty)
        #expect(logs.allSatisfy { !$0.contains("payload=") && !$0.contains("42 00") })
    }

    @Test func nativeFullVerifiedDeviceRejectsBTLEServerLogAcrossBothArrivalOrders() throws {
        let suite = "g9n9n-native-order-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // Arrival Order A: completed `.full` device receives `btle_log` BEFORE `iohid` -> no double fire!
        do {
            let settings = AppSettings(defaults: defaults)
            settings.customMappingEnabled = true
            let googleID = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
            settings.selectRemoteProfile(googleID)
            settings.setG9N9NInputMode(.full, for: googleID)
            settings.completeOnboarding()

            var actions: [ButtonAction] = []
            var logs: [String] = []
            let monitor = HIDRemoteMonitor(
                settings: settings,
                profileID: googleID,
                runtimePermissions: { true },
                actionPerformer: { _, _, configured in
                    actions.append(configured.action)
                    return true
                },
                diagnosticLogger: { logs.append($0) }
            )
            let descriptor = G9N9NProtocol.indexedConsumerDescriptor
            monitor.connectSimulatedDevice(fingerprint: "google-native-first", profileID: googleID, isSeized: false)
            defer { monitor.disconnectSimulatedDevice() }

            // btle_log arrives first on a native `.full` profile: must be rejected upfront without touching IOHID passthrough.
            monitor.handleSimulatedGoogleReport(
                reportID: 1,
                data: Data([5, 0]),
                descriptor: descriptor,
                source: "btle_log",
                origin: .btleServerLog
            )
            monitor.handleSimulatedGoogleReport(
                reportID: 1,
                data: Data([0, 0]),
                descriptor: descriptor,
                source: "btle_log",
                origin: .btleServerLog
            )
            // Native IOHID then delivers Left press + release: uses native passthrough cleanly once.
            monitor.handleSimulatedGoogleReport(
                reportID: 1,
                data: Data([1, 5, 0]),
                descriptor: descriptor,
                source: "device",
                origin: .iohid
            )
            monitor.handleSimulatedGoogleReport(
                reportID: 1,
                data: Data([1, 0, 0]),
                descriptor: descriptor,
                source: "device",
                origin: .iohid
            )

            #expect(actions.isEmpty) // Native arrowLeft passthrough never injects synthetic arrowLeft!
            #expect(logs.contains { $0.contains("reason=native_full_mode") })
        }

        // Arrival Order B: during onboarding, `iohid` arrives -> marks nativeGoogleIOHIDObserved so later `btle_log` is rejected.
        do {
            let settings = AppSettings(defaults: defaults)
            settings.customMappingEnabled = true
            settings.onboardingPurpose = .initialSetup
            let googleID = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
            settings.selectRemoteProfile(googleID)

            var verifiedCallbackIDs: [UUID?] = []
            var logs: [String] = []
            let monitor = HIDRemoteMonitor(
                settings: settings,
                profileID: googleID,
                runtimePermissions: { true },
                actionPerformer: { _, _, _ in true },
                diagnosticLogger: { logs.append($0) }
            )
            monitor.onNativeGoogleIOHIDVerified = { verifiedCallbackIDs.append($0) }
            let descriptor = G9N9NProtocol.indexedConsumerDescriptor
            monitor.connectSimulatedDevice(fingerprint: "google-onboarding-iohid", profileID: googleID)
            defer { monitor.disconnectSimulatedDevice() }

            // Simulate btle_log arriving just before IOHID during onboarding; IOHID single-key still verifies native support!
            monitor.handleSimulatedGoogleReport(
                reportID: 1,
                data: Data([3, 0]),
                descriptor: descriptor,
                source: "btle_log",
                origin: .btleServerLog
            )
            monitor.handleSimulatedGoogleReport(
                reportID: 1,
                data: Data([1, 3, 0]),
                descriptor: descriptor,
                source: "device",
                origin: .iohid
            )
            #expect(verifiedCallbackIDs == [googleID])
            #expect(monitor.nativeGoogleIOHIDObserved)

            // Subsequent btle_log press is now dropped immediately.
            monitor.handleSimulatedGoogleReport(
                reportID: 1,
                data: Data([4, 0]),
                descriptor: descriptor,
                source: "btle_log",
                origin: .btleServerLog
            )
            #expect(logs.contains { $0.contains("reason=native_iohid_verified") })
        }
    }

    @Test func btleTargetFilterAndDispatchEnforceStrictDeviceBindingAndExcludeNativeFull() throws {
        let nativeID = UUID()
        let logID = UUID()
        let secondUnboundID = UUID()
        let nativeBLE = UUID()
        let logBLE = UUID()
        let secondBLE = UUID()

        let nativeProfile = RemoteDeviceProfile(
            id: nativeID,
            model: .chromecastVoiceRemote,
            bluetoothIdentifier: nativeBLE,
            hidFingerprint: "fp-native",
            g9n9nInputMode: nil,
            mappings: AppSettings.defaultMappings(for: .chromecastVoiceRemote)
        )
        let logProfile = RemoteDeviceProfile(
            id: logID,
            model: .chromecastVoiceRemote,
            bluetoothIdentifier: logBLE,
            hidFingerprint: "fp-log",
            g9n9nInputMode: .bluetoothLogRecovery,
            mappings: AppSettings.defaultMappings(for: .chromecastVoiceRemote)
        )

        // Completed state: targetPeripherals excludes native `.full`, includes only `.bluetoothLogRecovery`.
        #expect(
            BridgeAppModel.btleLogRecoveryTargetPeripherals(
                profiles: [nativeProfile, logProfile],
                isOnboardingComplete: true,
                onboardingControlSource: .chromecastRemote,
                selectedProfileID: nativeID
            ) == [logBLE]
        )

        // Onboarding state: includes the selected G9N9N remote alongside any existing log-recovery remote.
        #expect(
            BridgeAppModel.btleLogRecoveryTargetPeripherals(
                profiles: [nativeProfile, logProfile],
                isOnboardingComplete: false,
                onboardingControlSource: .chromecastRemote,
                selectedProfileID: nativeID
            ) == [logBLE, nativeBLE]
        )

        // Bound profile routes ONLY to its bound monitor, never falling back to discoveryHIDMonitor.
        #expect(
            BridgeAppModel.resolveBTLEServerLogDispatchTarget(
                peripheral: logBLE,
                profiles: [nativeProfile, logProfile],
                boundMonitorFingerprints: ["fp-log"],
                hasDiscoveryMonitor: true,
                isOnboardingComplete: true,
                onboardingControlSource: .chromecastRemote,
                selectedProfileID: logID
            ) == .boundMonitor(fingerprint: "fp-log", profileID: logID)
        )
        #expect(
            BridgeAppModel.resolveBTLEServerLogDispatchTarget(
                peripheral: logBLE,
                profiles: [nativeProfile, logProfile],
                boundMonitorFingerprints: [],
                hasDiscoveryMonitor: true,
                isOnboardingComplete: true,
                onboardingControlSource: .chromecastRemote,
                selectedProfileID: logID
            ) == .drop(reason: "bound_monitor_unavailable")
        )
        #expect(
            BridgeAppModel.resolveBTLEServerLogDispatchTarget(
                peripheral: nativeBLE,
                profiles: [nativeProfile, logProfile],
                boundMonitorFingerprints: ["fp-native"],
                hasDiscoveryMonitor: true,
                isOnboardingComplete: true,
                onboardingControlSource: .chromecastRemote,
                selectedProfileID: nativeID
            ) == .drop(reason: "native_full_mode")
        )

        // Unbound profile with two unbound Chromecast remotes is ambiguous and must drop.
        let unboundA = RemoteDeviceProfile(
            id: logID,
            model: .chromecastVoiceRemote,
            bluetoothIdentifier: logBLE,
            hidFingerprint: nil,
            g9n9nInputMode: .bluetoothLogRecovery,
            mappings: AppSettings.defaultMappings(for: .chromecastVoiceRemote)
        )
        let unboundB = RemoteDeviceProfile(
            id: secondUnboundID,
            model: .chromecastVoiceRemote,
            bluetoothIdentifier: secondBLE,
            hidFingerprint: nil,
            g9n9nInputMode: nil,
            mappings: AppSettings.defaultMappings(for: .chromecastVoiceRemote)
        )
        #expect(
            BridgeAppModel.resolveBTLEServerLogDispatchTarget(
                peripheral: logBLE,
                profiles: [unboundA, unboundB],
                boundMonitorFingerprints: [],
                hasDiscoveryMonitor: true,
                isOnboardingComplete: false,
                onboardingControlSource: .chromecastRemote,
                selectedProfileID: logID
            ) == .drop(reason: "ambiguous_unbound_profile")
        )
        #expect(
            BridgeAppModel.resolveBTLEServerLogDispatchTarget(
                peripheral: logBLE,
                profiles: [unboundA],
                boundMonitorFingerprints: [],
                hasDiscoveryMonitor: true,
                isOnboardingComplete: false,
                onboardingControlSource: .chromecastRemote,
                selectedProfileID: logID
            ) == .discoveryMonitor(profileID: logID)
        )

        // HIDRemoteMonitor candidate resolution: unambiguous vs multi-device ambiguity vs deduplicating same fingerprint.
        #expect(
            HIDRemoteMonitor.resolveBTLEServerLogCandidate(
                candidates: [("dev1", "fp-1"), ("dev2", "fp-2")],
                activeFingerprint: nil,
                targetFingerprint: nil,
                excludedFingerprints: []
            ) == .rejected("ambiguous_google_device")
        )
        #expect(
            HIDRemoteMonitor.resolveBTLEServerLogCandidate(
                candidates: [("dev1", "fp-1"), ("dev1-dup", "fp-1")],
                activeFingerprint: nil,
                targetFingerprint: nil,
                excludedFingerprints: []
            ) == .selected("dev1")
        )
        #expect(
            HIDRemoteMonitor.resolveBTLEServerLogCandidate(
                candidates: [("dev1", "fp-1"), ("dev2", "fp-2")],
                activeFingerprint: nil,
                targetFingerprint: nil,
                excludedFingerprints: ["fp-1"]
            ) == .selected("dev2")
        )
        #expect(
            HIDRemoteMonitor.resolveBTLEServerLogCandidate(
                candidates: [(String, String?)]([]),
                activeFingerprint: nil,
                targetFingerprint: nil,
                excludedFingerprints: []
            ) == .rejected("no_google_device")
        )
    }

    @Test func dismissingAddDeviceOnboardingRestoresExistingChromecastMode() throws {
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

        SettingsPageBehavior.beginDeviceSetup(settings: settings)
        settings.setG9N9NInputMode(.bluetoothLogRecovery, for: googleID)
        #expect(settings.g9n9nInputMode(for: googleID) == .bluetoothLogRecovery)

        // Simulate relaunch/reload before cancelling Add Device onboarding.
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.g9n9nInputMode(for: googleID) == .bluetoothLogRecovery)
        reloaded.dismissOnboarding()

        #expect(reloaded.g9n9nInputMode(for: googleID) == .full)
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

    @Test func bluetoothLogRecoveryToggleOffAndRestartPreserveModeWithoutLeakingLogSource() throws {
        let suite = "g9n9n-btle-log-opt-in-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        #expect(!settings.g9n9nBluetoothLogRecoveryEnabled)

        settings.onboardingPurpose = .initialSetup
        let googleID = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        settings.completeOnboarding()

        // Cannot record `.bluetoothLogRecovery` while opt-in toggle is off.
        #expect(!settings.recordG9N9NBluetoothLogRecoveryIntegration(for: googleID))
        #expect(settings.g9n9nInputMode(for: googleID) == .full)

        // Enabling persists and records `.bluetoothLogRecovery` when a log-recovered button arrives.
        let model = BridgeAppModel(settings: settings, initialAudioDevices: [])
        model.setG9N9NBluetoothLogRecoveryEnabled(true)
        #expect(settings.g9n9nBluetoothLogRecoveryEnabled)
        #expect(settings.recordG9N9NBluetoothLogRecoveryIntegration(for: googleID))
        #expect(settings.g9n9nInputMode(for: googleID) == .bluetoothLogRecovery)

        // Observing redacted `<private>` after profile removal flips `btleServerLogRedactedObserved`.
        model.handleRedactedBTLEServerReport(.init(peripheral: nil, reportID: 2))
        #expect(model.btleServerLogRedactedObserved)

        // Toggling off clears active redacted state and stops log stream while keeping profile metadata across restart.
        model.setG9N9NBluetoothLogRecoveryEnabled(false)
        #expect(!settings.g9n9nBluetoothLogRecoveryEnabled)
        #expect(!model.btleServerLogRedactedObserved)
        #expect(model.btleServerReportLogSource == nil)

        let restarted = AppSettings(defaults: defaults)
        #expect(!restarted.g9n9nBluetoothLogRecoveryEnabled)
        #expect(restarted.g9n9nInputMode(for: googleID) == .bluetoothLogRecovery)

        let summary = OnboardingCompletionSummary(
            purpose: .initialSetup,
            remoteName: "Chromecast Remote",
            buttonsVerified: true,
            microphoneReady: true,
            voiceKeyMode: .suggestedShortcut,
            tapModeEnabled: true,
            voiceTool: .voiceBuddy,
            binding: nil,
            g9n9nInputMode: .bluetoothLogRecovery
        )
        #expect(summary.g9n9nInputMode == .bluetoothLogRecovery)

        // Native IOHID single-key recovery resets the profile back to standard `.full` mode.
        #expect(restarted.recordG9N9NNativeIOHIDIntegration(for: googleID))
        #expect(restarted.g9n9nInputMode(for: googleID) == .full)
    }
}
