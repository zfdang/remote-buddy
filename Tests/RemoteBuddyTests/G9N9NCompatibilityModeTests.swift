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

        // Bound profile routes ONLY to its bound monitor; unbound profiles never fall back to discoveryHIDMonitor.
        #expect(
            BridgeAppModel.resolveBTLEServerLogDispatchTarget(
                peripheral: logBLE,
                profiles: [nativeProfile, logProfile],
                boundMonitorFingerprints: ["fp-log"],
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
                isOnboardingComplete: true,
                onboardingControlSource: .chromecastRemote,
                selectedProfileID: nativeID
            ) == .drop(reason: "native_full_mode")
        )

        // Unbound profile (no hidFingerprint) is excluded from target peripherals and dropped instead of guessing discoveryHIDMonitor.
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
            BridgeAppModel.btleLogRecoveryTargetPeripherals(
                profiles: [unboundA],
                isOnboardingComplete: false,
                onboardingControlSource: .chromecastRemote,
                selectedProfileID: logID
            ).isEmpty
        )
        #expect(
            BridgeAppModel.resolveBTLEServerLogDispatchTarget(
                peripheral: logBLE,
                profiles: [unboundA, unboundB],
                boundMonitorFingerprints: [],
                isOnboardingComplete: false,
                onboardingControlSource: .chromecastRemote,
                selectedProfileID: logID
            ) == .drop(reason: "unbound_hid_profile")
        )
        #expect(
            BridgeAppModel.resolveBTLEServerLogDispatchTarget(
                peripheral: logBLE,
                profiles: [unboundA],
                boundMonitorFingerprints: [],
                isOnboardingComplete: false,
                onboardingControlSource: .chromecastRemote,
                selectedProfileID: logID
            ) == .drop(reason: "unbound_hid_profile")
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

    @Test func legacyTwoKeyProfileJSONUpgradesSingleFieldWithoutCorruptingMultiDeviceConfig() throws {
        let suite = "g9n9n-legacy-upgrade-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let baselineProfiles: [RemoteDeviceProfile] = [
            RemoteDeviceProfile(
                model: .rc003,
                customName: "Living Room Xiaomi",
                bluetoothIdentifier: UUID(),
                hidFingerprint: "fp-xiaomi",
                mappings: {
                    var m = AppSettings.defaultMappings(for: .rc003)
                    m.buttonBindings[RemoteButton.ok.rawValue] = .commandReturn
                    return m
                }()
            ),
            RemoteDeviceProfile(
                model: .chromecastVoiceRemote,
                customName: "Legacy G9N9N",
                bluetoothIdentifier: UUID(),
                hidFingerprint: "fp-g9n9n",
                g9n9nInputMode: .full,
                mappings: {
                    var m = AppSettings.defaultMappings(for: .chromecastVoiceRemote)
                    m.buttonBindings[RemoteButton.youtube.rawValue] = .escape
                    return m
                }()
            ),
            RemoteDeviceProfile(
                model: .appleSiriRemoteA2854,
                customName: "Desk Siri",
                bluetoothIdentifier: UUID(),
                mappings: AppSettings.defaultMappings(for: .appleSiriRemoteA2854)
            ),
        ]
        let encoded = try JSONEncoder().encode(baselineProfiles)
        var jsonArray = try #require(try JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        jsonArray[1]["g9n9nInputMode"] = "two_key_compatibility"
        let legacyData = try JSONSerialization.data(withJSONObject: jsonArray)
        defaults.set(legacyData, forKey: "remoteDeviceProfiles")

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.corruptedSettingKeys.isEmpty)
        #expect(defaults.data(forKey: "remoteDeviceProfiles.corrupt") == nil)
        #expect(reloaded.remoteDeviceProfiles.count == 3)
        #expect(reloaded.remoteDeviceProfiles[0].customName == "Living Room Xiaomi")
        #expect(reloaded.action(for: .ok, profileID: reloaded.remoteDeviceProfiles[0].id) == .commandReturn)
        #expect(reloaded.remoteDeviceProfiles[1].g9n9nInputMode == nil)
        #expect(reloaded.remoteDeviceProfiles[1].effectiveG9N9NInputMode == .full)
        #expect(reloaded.action(for: .youtube, profileID: reloaded.remoteDeviceProfiles[1].id) == .escape)
        #expect(reloaded.remoteDeviceProfiles[2].customName == "Desk Siri")
    }

    @Test func bluetoothLogRecoveryLifecyclePausesOnRedactedAndRejectsStaleQueuedCallbacks() throws {
        let suite = "g9n9n-btle-log-lifecycle-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        #expect(!settings.g9n9nBluetoothLogRecoveryEnabled)

        settings.customMappingEnabled = true
        settings.onboardingPurpose = .initialSetup
        let googleBLE = UUID()
        let googleID = settings.registerBluetoothRemote(identifier: googleBLE, model: .chromecastVoiceRemote)
        settings.bindHIDFingerprint("fp-g9n9n-log", to: googleID)
        settings.completeOnboarding()

        // Cannot record `.bluetoothLogRecovery` while opt-in toggle is off.
        #expect(!settings.recordG9N9NBluetoothLogRecoveryIntegration(for: googleID))
        #expect(settings.g9n9nInputMode(for: googleID) == .full)

        let model = BridgeAppModel(
            settings: settings,
            initialAudioDevices: [],
            permissionSnapshotProvider: {
                HIDPermissionSnapshot(inputMonitoringGranted: true, accessibilityGranted: true)
            }
        )
        defer {
            model.setG9N9NBluetoothLogRecoveryEnabled(false)
            model.stop()
        }
        model.started = true
        model.setG9N9NBluetoothLogRecoveryEnabled(true)
        #expect(settings.g9n9nBluetoothLogRecoveryEnabled)
        #expect(settings.recordG9N9NBluetoothLogRecoveryIntegration(for: googleID))
        #expect(settings.g9n9nInputMode(for: googleID) == .bluetoothLogRecovery)
        model.synchronizeBTLEServerLogSource()
        #expect(model.btleServerReportLogSource != nil)
        let activeGeneration = model.btleServerReportLogGeneration

        // Redacted `<private>` report immediately pauses `btleServerReportLogSource` while keeping UI warning visible.
        model.handleRedactedBTLEServerReport(
            .init(peripheral: googleBLE, reportID: 2),
            sourceGeneration: activeGeneration
        )
        #expect(model.btleServerLogRedactedObserved)
        #expect(model.btleServerReportLogSource == nil)
        model.synchronizeBTLEServerLogSource()
        #expect(model.btleServerReportLogSource == nil)

        // Recheck clears redacted state and allows source to start again; `.notInstalled` blocks startup.
        model.recheckBluetoothLoggingProfile()
        #expect(!model.btleServerLogRedactedObserved)
        #expect(model.btleServerReportLogSource != nil)
        let secondGeneration = model.btleServerReportLogGeneration
        #expect(secondGeneration > activeGeneration)

        model.bluetoothLoggingProfileStatus = .notInstalled
        model.synchronizeBTLEServerLogSource()
        #expect(model.btleServerReportLogSource == nil)

        // Stale already-queued callbacks after toggle-off and rapid toggle off->on cannot run or mutate status.
        model.bluetoothLoggingProfileStatus = .unknown
        model.setG9N9NBluetoothLogRecoveryEnabled(false)
        #expect(!settings.g9n9nBluetoothLogRecoveryEnabled)
        #expect(model.btleServerReportLogSource == nil)
        model.handleAttributedBTLEServerReport(
            .init(peripheral: googleBLE, reportID: 2, data: Data([0x42, 0x00])),
            sourceGeneration: secondGeneration
        )
        #expect(model.bluetoothLoggingProfileStatus == .unknown)

        model.setG9N9NBluetoothLogRecoveryEnabled(true)
        #expect(model.btleServerReportLogSource != nil)
        model.handleAttributedBTLEServerReport(
            .init(peripheral: googleBLE, reportID: 2, data: Data([0x42, 0x00])),
            sourceGeneration: secondGeneration
        )
        #expect(model.bluetoothLoggingProfileStatus != .installed)

        model.setG9N9NBluetoothLogRecoveryEnabled(false)
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
