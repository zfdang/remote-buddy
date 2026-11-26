import AppKit
import CoreGraphics
import Foundation
import os
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

    @Test func bluetoothLogRecoveryLifecycleRequiresConfirmedProfileAndPreservesRedactedPause() async throws {
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

        let simulatedStatus = OSAllocatedUnfairLock(initialState: BluetoothLoggingProfileStatus.unknown)
        let model = BridgeAppModel(
            settings: settings,
            initialAudioDevices: [],
            permissionSnapshotProvider: {
                HIDPermissionSnapshot(inputMonitoringGranted: true, accessibilityGranted: true)
            }
        )
        model.bluetoothLoggingProfileStatusProvider = {
            simulatedStatus.withLock { $0 }
        }
        defer {
            model.setG9N9NBluetoothLogRecoveryEnabled(false)
            model.stop()
        }
        model.started = true
        model.setG9N9NBluetoothLogRecoveryEnabled(true)
        #expect(settings.g9n9nBluetoothLogRecoveryEnabled)
        #expect(settings.recordG9N9NBluetoothLogRecoveryIntegration(for: googleID))
        #expect(settings.g9n9nInputMode(for: googleID) == .bluetoothLogRecovery)
        await model.bluetoothLoggingProfileRefreshTask?.value

        // With `.unknown` (before confirmation or under restricted query permissions), reader never starts.
        model.synchronizeBTLEServerLogSource()
        #expect(model.bluetoothLoggingProfileStatus == .unknown)
        #expect(model.btleServerReportLogSource == nil)

        // `.notInstalled` also blocks startup.
        model.applyBluetoothLoggingProfileStatus(.notInstalled)
        #expect(model.btleServerReportLogSource == nil)

        // Only `.installed` starts `btleServerReportLogSource`.
        simulatedStatus.withLock { $0 = .installed }
        model.recheckBluetoothLoggingProfile()
        #expect(model.btleServerReportLogSource == nil)
        await model.bluetoothLoggingProfileRefreshTask?.value
        #expect(model.bluetoothLoggingProfileStatus == .installed)
        #expect(model.btleServerReportLogSource != nil)
        let activeGeneration = model.btleServerReportLogGeneration

        // Attributed `<private>` report immediately pauses `btleServerReportLogSource`.
        model.handleRedactedBTLEServerReport(
            .init(peripheral: googleBLE, reportID: 2),
            sourceGeneration: activeGeneration
        )
        #expect(model.btleServerLogRedactedObserved)
        #expect(model.btleServerReportLogSource == nil)
        await model.bluetoothLoggingProfileRefreshTask?.value
        #expect(model.btleServerLogRedactedObserved)
        #expect(model.btleServerReportLogSource == nil)

        // Static `.installed` result must NOT clear the runtime `<private>` pause or restart the loop.
        model.applyBluetoothLoggingProfileStatus(.installed)
        #expect(model.btleServerLogRedactedObserved)
        #expect(model.btleServerReportLogSource == nil)
        model.synchronizeBTLEServerLogSource()
        #expect(model.btleServerReportLogSource == nil)

        // Explicit Recheck resets redacted flag and restarts once `.installed` is confirmed again.
        model.recheckBluetoothLoggingProfile()
        #expect(!model.btleServerLogRedactedObserved)
        #expect(model.btleServerReportLogSource == nil)
        await model.bluetoothLoggingProfileRefreshTask?.value
        #expect(model.bluetoothLoggingProfileStatus == .installed)
        #expect(model.btleServerReportLogSource != nil)
        let secondGeneration = model.btleServerReportLogGeneration
        #expect(secondGeneration > activeGeneration)

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

        simulatedStatus.withLock { $0 = .installed }
        model.setG9N9NBluetoothLogRecoveryEnabled(true)
        await model.bluetoothLoggingProfileRefreshTask?.value
        #expect(model.btleServerReportLogSource != nil)
        #expect(model.btleServerReportLogGeneration > secondGeneration)
        model.handleAttributedBTLEServerReport(
            .init(peripheral: googleBLE, reportID: 2, data: Data([0x42, 0x00])),
            sourceGeneration: secondGeneration
        )

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

    @Test func unattributedRedactedReportsRefreshProfileAndStopWhenRemoved() async throws {
        let suite = "g9n9n-btle-log-unattributed-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        settings.onboardingPurpose = .initialSetup
        let googleBLE = UUID()
        let googleID = settings.registerBluetoothRemote(identifier: googleBLE, model: .chromecastVoiceRemote)
        settings.bindHIDFingerprint("fp-g9n9n-redaction", to: googleID)
        settings.completeOnboarding()

        let providerState = OSAllocatedUnfairLock(initialState: (status: BluetoothLoggingProfileStatus.installed, calls: 0))
        let model = BridgeAppModel(
            settings: settings,
            initialAudioDevices: [],
            permissionSnapshotProvider: {
                HIDPermissionSnapshot(inputMonitoringGranted: true, accessibilityGranted: true)
            }
        )
        model.bluetoothLoggingProfileStatusProvider = {
            providerState.withLock { state in
                state.calls += 1
                return state.status
            }
        }
        defer {
            model.setG9N9NBluetoothLogRecoveryEnabled(false)
            model.stop()
        }
        model.started = true
        model.setG9N9NBluetoothLogRecoveryEnabled(true)
        #expect(settings.recordG9N9NBluetoothLogRecoveryIntegration(for: googleID))
        await model.bluetoothLoggingProfileRefreshTask?.value
        #expect(model.bluetoothLoggingProfileStatus == .installed)
        #expect(model.btleServerReportLogSource != nil)
        let installedGeneration = model.btleServerReportLogGeneration
        let baselineCalls = providerState.withLock { $0.calls }

        // Unattributed `<private>` triggers throttled status refresh but does NOT falsely pause while `.installed`.
        for offset in 0..<4 {
            model.handleRedactedBTLEServerReport(
                .init(peripheral: nil, reportID: 2),
                sourceGeneration: installedGeneration,
                now: 200.0 + Double(offset) * 0.5
            )
        }
        await model.bluetoothLoggingProfileRefreshTask?.value
        #expect(providerState.withLock { $0.calls } == baselineCalls + 1)
        #expect(!model.btleServerLogRedactedObserved)
        #expect(model.btleServerReportLogSource != nil)

        // If the user removed the profile before the next refresh window, status becomes `.notInstalled` and stops.
        providerState.withLock { $0.status = .notInstalled }
        model.handleRedactedBTLEServerReport(
            .init(peripheral: nil, reportID: 2),
            sourceGeneration: installedGeneration,
            now: 215.0
        )
        await model.bluetoothLoggingProfileRefreshTask?.value
        #expect(model.bluetoothLoggingProfileStatus == .notInstalled)
        #expect(model.btleServerReportLogSource == nil)

        // Directly attributed `<private>` still pauses immediately even while status reads `.installed`.
        providerState.withLock { $0.status = .installed }
        model.recheckBluetoothLoggingProfile()
        await model.bluetoothLoggingProfileRefreshTask?.value
        #expect(model.bluetoothLoggingProfileStatus == .installed)
        #expect(model.btleServerReportLogSource != nil)
        let activeGeneration = model.btleServerReportLogGeneration
        model.handleRedactedBTLEServerReport(
            .init(peripheral: googleBLE, reportID: 2),
            sourceGeneration: activeGeneration,
            now: 220.0
        )
        await model.bluetoothLoggingProfileRefreshTask?.value
        #expect(model.btleServerLogRedactedObserved)
        #expect(model.btleServerReportLogSource == nil)
    }

    @Test func disablingBluetoothLogRecoveryCancelsActiveHoldsRepeatsAndPendingGesturesWithoutAffectingNativeMonitor() throws {
        let suite = "g9n9n-cancel-on-stop-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        let googleID = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        let nativeID = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        settings.setG9N9NInputMode(.bluetoothLogRecovery, for: googleID)
        settings.bindHIDFingerprint("fp-g9n9n-cancel", to: googleID)
        settings.bindHIDFingerprint("fp-native-other", to: nativeID)
        settings.setBaseBinding(
            ConfiguredButtonAction(action: .commandReturn, shortcut: nil),
            for: .ok,
            trigger: .doubleClick,
            profileID: googleID
        )
        settings.setBaseBinding(
            ConfiguredButtonAction(action: .space, shortcut: nil),
            for: .mute,
            trigger: .longPress,
            profileID: googleID
        )
        settings.setBaseBinding(
            ConfiguredButtonAction(action: .arrowDown, shortcut: nil),
            for: .down,
            trigger: .singleClick,
            profileID: googleID
        )
        settings.setBaseBinding(
            ConfiguredButtonAction(action: .arrowDown, shortcut: nil),
            for: .down,
            trigger: .singleClick,
            profileID: nativeID
        )
        settings.completeOnboarding()

        let logScheduler = ControlledTestScheduler()
        var logActions: [(RemoteButton, ButtonTrigger, ButtonAction)] = []
        let logMonitor = HIDRemoteMonitor(
            settings: settings,
            allowsG9N9N: true,
            profileID: googleID,
            targetFingerprint: "fp-g9n9n-cancel",
            scheduler: logScheduler,
            runtimePermissions: { true },
            nativeSuppressionAvailable: { true },
            actionPerformer: { button, trigger, configured in
                logActions.append((button, trigger, configured.action))
                return true
            },
            diagnosticLogger: { _ in }
        )
        logMonitor.connectSimulatedDevice(fingerprint: "fp-g9n9n-cancel", profileID: googleID, isSeized: true)
        defer { logMonitor.disconnectSimulatedDevice() }

        let nativeScheduler = ControlledTestScheduler()
        var nativeActions: [(RemoteButton, ButtonTrigger, ButtonAction)] = []
        let nativeMonitor = HIDRemoteMonitor(
            settings: settings,
            allowsG9N9N: false,
            allowsT1Remote: false,
            profileID: nativeID,
            targetFingerprint: "fp-native-other",
            scheduler: nativeScheduler,
            runtimePermissions: { true },
            nativeSuppressionAvailable: { true },
            actionPerformer: { button, trigger, configured in
                nativeActions.append((button, trigger, configured.action))
                return true
            },
            diagnosticLogger: { _ in }
        )
        nativeMonitor.connectSimulatedDevice(fingerprint: "fp-native-other", profileID: nativeID, isSeized: true)
        defer { nativeMonitor.disconnectSimulatedDevice() }

        let model = BridgeAppModel(
            settings: settings,
            initialAudioDevices: [],
            permissionSnapshotProvider: {
                HIDPermissionSnapshot(inputMonitoringGranted: true, accessibilityGranted: true)
            }
        )
        defer {
            model.hidMonitors.removeAll()
            model.stop()
        }
        model.started = true
        model.bluetoothLoggingProfileStatus = .installed
        model.hidMonitors["fp-g9n9n-cancel"] = logMonitor
        model.hidMonitors["fp-native-other"] = nativeMonitor
        model.setG9N9NBluetoothLogRecoveryEnabled(true)

        // 1. Hold `.down` (repeatable), press & release `.ok` (schedules double-click timeout for delayed singleClick),
        //    and hold `.mute` (schedules long-press timeout) via `btle_log`.
        logMonitor.handleSimulatedGoogleReport(
            reportID: 2,
            data: Data([0x43, 0x00]),
            source: "btle_log",
            origin: .btleServerLog
        ) // down
        logMonitor.handleSimulatedGoogleReport(
            reportID: 2,
            data: Data([0x41, 0x00]),
            source: "btle_log",
            origin: .btleServerLog
        ) // ok + still holding down? Report 2 here clears down first -> keep chord via ok then release ok, then hold down + mute via report 1 or sequential:
        // Wait: send ok press & release first, then down press, then mute is separate; actually Report 1 allows holding 2 keys or sequential keeps repeat+doubleclick!
        // Reset cleanly: press & release ok (arms double-click timer), press down (arms repeat), press mute (wait: Report 2 only carries 1 key at a time, so separate presses test all three cleanly).
        logMonitor.handleSimulatedGoogleReport(reportID: 2, data: Data([0x00, 0x00]), source: "btle_log", origin: .btleServerLog)
        logMonitor.resetInputState()
        logActions.removeAll()

        // Tap `.ok` -> deferred single-click waiting on double-click timeout (300 ms).
        logMonitor.handleSimulatedGoogleReport(
            reportID: 1,
            data: Data([0x07]),
            descriptor: G9N9NProtocol.indexedConsumerDescriptor,
            source: "btle_log",
            origin: .btleServerLog
        )
        logMonitor.handleSimulatedGoogleReport(
            reportID: 1,
            data: Data([0x00]),
            descriptor: G9N9NProtocol.indexedConsumerDescriptor,
            source: "btle_log",
            origin: .btleServerLog
        )
        // Simultaneously hold `.down` (repeatable, 350 ms) and `.mute` (long-press pending, 550 ms).
        logMonitor.handleSimulatedGoogleReport(
            reportID: 1,
            data: Data([0x04, 0x08]),
            descriptor: G9N9NProtocol.indexedConsumerDescriptor,
            source: "btle_log",
            origin: .btleServerLog
        )
        // Native monitor holds Down independently via `.iohid`.
        nativeMonitor.handleSimulatedReport(reportID: 1, data: Data([0x51, 0x00]), source: "device")
        #expect(logActions.count == 1)
        #expect(!logMonitor.activeUsages.isEmpty)
        #expect(!logMonitor.btleLogActiveUsages.isEmpty)

        // Disable log recovery while key is held and double-click timer is still pending!
        model.setG9N9NBluetoothLogRecoveryEnabled(false)
        #expect(logMonitor.activeUsages.isEmpty)
        #expect(logMonitor.btleLogActiveUsages.isEmpty)
        #expect(logMonitor.btleLogPendingGestureButtons.isEmpty)

        // Advancing virtual clock past repeat + double-click + long-press windows triggers ZERO further G9N9N actions,
        // while the separate native monitor continues its normal hold repeat unaffected.
        logScheduler.advance(to: 2_000)
        nativeScheduler.advance(to: 600)
        #expect(logActions.count == 1)
        #expect(nativeActions.count >= 2)
    }

    @Test func btleServerLogRejectsDescriptorReportIDMismatch() throws {
        let suite = "g9n9n-descriptor-mismatch-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        let googleID = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        settings.setG9N9NInputMode(.bluetoothLogRecovery, for: googleID)
        settings.completeOnboarding()

        var actions: [ButtonAction] = []
        let monitor = HIDRemoteMonitor(
            settings: settings,
            allowsG9N9N: true,
            profileID: googleID,
            runtimePermissions: { true },
            nativeSuppressionAvailable: { true },
            actionPerformer: { _, _, configured in
                actions.append(configured.action)
                return true
            },
            diagnosticLogger: { _ in }
        )
        monitor.connectSimulatedDevice(fingerprint: "fp-g9n9n-desc", profileID: googleID, isSeized: true)
        defer { monitor.disconnectSimulatedDevice() }

        // Indexed descriptor (e.g. FW 26.7) must reject Report ID 2 from `btle_log`.
        monitor.handleSimulatedGoogleReport(
            reportID: 2,
            data: Data([0x42, 0x00]),
            descriptor: G9N9NProtocol.indexedConsumerDescriptor,
            source: "btle_log",
            origin: .btleServerLog
        )
        #expect(actions.isEmpty)

        // Indexed descriptor accepts Report ID 1 from `btle_log`.
        monitor.handleSimulatedGoogleReport(
            reportID: 1,
            data: Data([0x03]),
            descriptor: G9N9NProtocol.indexedConsumerDescriptor,
            source: "btle_log",
            origin: .btleServerLog
        )
        #expect(actions == [.arrowUp])

        // Consumer Report 2 descriptor (e.g. 0x011B) must reject Report ID 1 from `btle_log`.
        let report2Descriptor = Data([0x05, 0x0C, 0x09, 0x01, 0xA1, 0x01, 0x85, 0x02, 0xC0])
        monitor.handleSimulatedGoogleReport(
            reportID: 1,
            data: Data([0x04]),
            descriptor: report2Descriptor,
            source: "btle_log",
            origin: .btleServerLog
        )
        #expect(actions == [.arrowUp])
    }

    @Test func remoteButtonObservationComparesOrigin() {
        let profileID = UUID()
        let iohid = RemoteButtonObservation(profileID: profileID, buttons: [.up], origin: .iohid)
        let btle = RemoteButtonObservation(profileID: profileID, buttons: [.up], origin: .btleServerLog)
        let iohidSame = RemoteButtonObservation(profileID: profileID, buttons: [.up], origin: .iohid)

        #expect(iohid == iohidSame)
        #expect(iohid != btle)
    }

    @Test func periodicProfileVerificationStopsBackgroundSourceWithoutRemoteInput() async throws {
        let suite = "g9n9n-periodic-verify-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        let googleBLE = UUID()
        let googleID = settings.registerBluetoothRemote(identifier: googleBLE, model: .chromecastVoiceRemote)
        settings.setG9N9NInputMode(.bluetoothLogRecovery, for: googleID)
        settings.bindHIDFingerprint("fp-g9n9n-periodic", to: googleID)
        settings.completeOnboarding()

        let providerState = OSAllocatedUnfairLock(initialState: BluetoothLoggingProfileStatus.installed)
        let model = BridgeAppModel(
            settings: settings,
            initialAudioDevices: [],
            permissionSnapshotProvider: {
                HIDPermissionSnapshot(inputMonitoringGranted: true, accessibilityGranted: true)
            }
        )
        model.bluetoothLoggingProfileCheckIntervalNanoseconds = 20_000_000
        model.bluetoothLoggingProfileStatusProvider = {
            providerState.withLock { $0 }
        }
        defer {
            model.setG9N9NBluetoothLogRecoveryEnabled(false)
            model.stop()
        }
        model.started = true
        model.setG9N9NBluetoothLogRecoveryEnabled(true)
        await model.bluetoothLoggingProfileRefreshTask?.value
        #expect(model.bluetoothLoggingProfileStatus == .installed)
        #expect(model.btleServerReportLogSource != nil)

        // Removing the profile with ZERO subsequent remote reports still stops the log source.
        providerState.withLock { $0 = .notInstalled }
        for _ in 0..<40 where model.btleServerReportLogSource != nil {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(model.bluetoothLoggingProfileStatus == .notInstalled)
        #expect(model.btleServerReportLogSource == nil)

        // Becoming `.unknown` while running also fails closed without waiting for remote input.
        providerState.withLock { $0 = .installed }
        model.recheckBluetoothLoggingProfile()
        await model.bluetoothLoggingProfileRefreshTask?.value
        #expect(model.btleServerReportLogSource != nil)

        providerState.withLock { $0 = .unknown }
        for _ in 0..<40 where model.btleServerReportLogSource != nil {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(model.bluetoothLoggingProfileStatus == .unknown)
        #expect(model.btleServerReportLogSource == nil)
    }

    @Test func attributedReportsDoNotResetRedactionRefreshThrottleAndConcurrentRefreshesCoalesce() async throws {
        let suite = "g9n9n-redaction-throttle-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        let googleBLE = UUID()
        let googleID = settings.registerBluetoothRemote(identifier: googleBLE, model: .chromecastVoiceRemote)
        settings.setG9N9NInputMode(.bluetoothLogRecovery, for: googleID)
        settings.bindHIDFingerprint("fp-g9n9n-throttle", to: googleID)
        settings.completeOnboarding()

        let monitor = HIDRemoteMonitor(
            settings: settings,
            allowsG9N9N: true,
            profileID: googleID,
            targetFingerprint: "fp-g9n9n-throttle",
            runtimePermissions: { true },
            nativeSuppressionAvailable: { true },
            actionPerformer: { _, _, _ in true },
            diagnosticLogger: { _ in }
        )
        monitor.connectSimulatedDevice(fingerprint: "fp-g9n9n-throttle", profileID: googleID, isSeized: true)
        defer { monitor.disconnectSimulatedDevice() }

        let providerCalls = OSAllocatedUnfairLock(initialState: 0)
        let model = BridgeAppModel(
            settings: settings,
            initialAudioDevices: [],
            permissionSnapshotProvider: {
                HIDPermissionSnapshot(inputMonitoringGranted: true, accessibilityGranted: true)
            }
        )
        model.bluetoothLoggingProfileStatusProvider = {
            providerCalls.withLock { $0 += 1 }
            return .installed
        }
        defer {
            model.hidMonitors.removeAll()
            model.setG9N9NBluetoothLogRecoveryEnabled(false)
            model.stop()
        }
        model.started = true
        model.hidMonitors["fp-g9n9n-throttle"] = monitor
        model.setG9N9NBluetoothLogRecoveryEnabled(true)
        await model.bluetoothLoggingProfileRefreshTask?.value
        let baseline = providerCalls.withLock { $0 }
        let generation = model.btleServerReportLogGeneration

        // Unattributed redaction triggers 1 refresh at t=100.
        model.handleRedactedBTLEServerReport(
            .init(peripheral: nil, reportID: 2),
            sourceGeneration: generation,
            now: 100.0
        )
        await model.bluetoothLoggingProfileRefreshTask?.value
        #expect(providerCalls.withLock { $0 } == baseline + 1)

        // Normal attributed report must NOT reset the 10-second throttle window.
        model.handleAttributedBTLEServerReport(
            .init(peripheral: googleBLE, reportID: 2, data: Data([0x41, 0x00])),
            sourceGeneration: generation
        )
        model.handleAttributedBTLEServerReport(
            .init(peripheral: googleBLE, reportID: 2, data: Data([0x00, 0x00])),
            sourceGeneration: generation
        )
        model.handleRedactedBTLEServerReport(
            .init(peripheral: nil, reportID: 2),
            sourceGeneration: generation,
            now: 103.0
        )
        await model.bluetoothLoggingProfileRefreshTask?.value
        #expect(providerCalls.withLock { $0 } == baseline + 1)

        // After >=10 seconds, the next unattributed redaction refreshes again.
        model.handleRedactedBTLEServerReport(
            .init(peripheral: nil, reportID: 2),
            sourceGeneration: generation,
            now: 110.5
        )
        await model.bluetoothLoggingProfileRefreshTask?.value
        #expect(providerCalls.withLock { $0 } == baseline + 2)

        // Concurrent refresh requests coalesce into a single in-flight query.
        let gate = OSAllocatedUnfairLock<CheckedContinuation<BluetoothLoggingProfileStatus, Never>?>(initialState: nil)
        model.bluetoothLoggingProfileStatusProvider = {
            providerCalls.withLock { $0 += 1 }
            return await withCheckedContinuation { continuation in
                gate.withLock { $0 = continuation }
            }
        }
        let beforeCoalesce = providerCalls.withLock { $0 }
        model.refreshBluetoothLoggingProfileStatus(coalescingIfInFlight: true)
        model.refreshBluetoothLoggingProfileStatus(coalescingIfInFlight: true)
        for _ in 0..<20 where gate.withLock({ $0 == nil }) {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(providerCalls.withLock { $0 } == beforeCoalesce + 1)
        gate.withLock { $0 }?.resume(returning: .installed)
        await model.bluetoothLoggingProfileRefreshTask?.value
    }

    @Test func disablingBluetoothLogRecoveryClearsFinishedGesturesAndPreservesOtherRemotesAppSwitcher() async throws {
        let suite = "g9n9n-switcher-isolation-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        let googleID = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        let nativeID = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        settings.setG9N9NInputMode(.bluetoothLogRecovery, for: googleID)
        settings.bindHIDFingerprint("fp-g9n9n-switcher", to: googleID)
        settings.bindHIDFingerprint("fp-native-switcher", to: nativeID)
        settings.setBaseBinding(
            ConfiguredButtonAction(action: .space, shortcut: nil),
            for: .ok,
            trigger: .singleClick,
            profileID: googleID
        )
        settings.setBaseBinding(
            ConfiguredButtonAction(action: .escape, shortcut: nil),
            for: .mute,
            trigger: .doubleClick,
            profileID: googleID
        )
        settings.setBaseBinding(
            ConfiguredButtonAction(action: .appSwitcher, shortcut: nil),
            for: .home,
            trigger: .singleClick,
            profileID: nativeID
        )
        settings.setBaseBinding(
            ConfiguredButtonAction(action: .appSwitcher, shortcut: nil),
            for: .home,
            trigger: .singleClick,
            profileID: googleID
        )
        settings.completeOnboarding()

        let scheduler = ControlledTestScheduler()
        let coordinator = HIDAppSwitcherCoordinator(
            session: KeyboardInjector.AppSwitcherSession(
                hardwareFlags: { [] },
                keyStatePoster: { _, _, _, _ in true }
            ),
            scheduler: scheduler,
            frontmostBundleIdentifier: { "test.editor" },
            diagnosticLogger: { _ in }
        )

        let logMonitor = HIDRemoteMonitor(
            settings: settings,
            allowsG9N9N: true,
            profileID: googleID,
            targetFingerprint: "fp-g9n9n-switcher",
            scheduler: scheduler,
            runtimePermissions: { true },
            nativeSuppressionAvailable: { true },
            actionPerformer: { _, _, _ in true },
            diagnosticLogger: { _ in },
            appSwitcherCoordinator: coordinator
        )
        logMonitor.connectSimulatedDevice(fingerprint: "fp-g9n9n-switcher", profileID: googleID, isSeized: true)
        defer { logMonitor.disconnectSimulatedDevice() }

        let nativeMonitor = HIDRemoteMonitor(
            settings: settings,
            allowsG9N9N: false,
            allowsT1Remote: false,
            profileID: nativeID,
            targetFingerprint: "fp-native-switcher",
            scheduler: scheduler,
            runtimePermissions: { true },
            nativeSuppressionAvailable: { true },
            actionPerformer: { _, _, _ in true },
            diagnosticLogger: { _ in },
            appSwitcherCoordinator: coordinator
        )
        nativeMonitor.connectSimulatedDevice(fingerprint: "fp-native-switcher", profileID: nativeID, isSeized: true)
        defer { nativeMonitor.disconnectSimulatedDevice() }

        let model = BridgeAppModel(
            settings: settings,
            initialAudioDevices: [],
            permissionSnapshotProvider: {
                HIDPermissionSnapshot(inputMonitoringGranted: true, accessibilityGranted: true)
            }
        )
        model.appSwitcherCoordinator = coordinator
        model.bluetoothLoggingProfileStatusProvider = { .installed }
        defer {
            model.hidMonitors.removeAll()
            model.setG9N9NBluetoothLogRecoveryEnabled(false)
            model.stop()
        }
        model.started = true
        model.hidMonitors["fp-g9n9n-switcher"] = logMonitor
        model.hidMonitors["fp-native-switcher"] = nativeMonitor
        model.setG9N9NBluetoothLogRecoveryEnabled(true)
        await model.bluetoothLoggingProfileRefreshTask?.value

        // 1. Log remote presses and releases OK -> finished gesture clears btleLogPendingGestureButtons.
        logMonitor.handleSimulatedGoogleReport(reportID: 2, data: Data([0x41, 0x00]), source: "btle_log", origin: .btleServerLog)
        logMonitor.handleSimulatedGoogleReport(reportID: 2, data: Data([0x00, 0x00]), source: "btle_log", origin: .btleServerLog)
        #expect(logMonitor.btleLogPendingGestureButtons.isEmpty)

        // 2. Even when the log remote STILL has a pending gesture timeout (double-click on Mute),
        //    opening App Switcher from the native remote and then disabling BTLE log recovery
        //    must cancel the log remote's pending gesture WITHOUT closing the native remote's switcher.
        logMonitor.handleSimulatedGoogleReport(reportID: 2, data: Data([0xE2, 0x00]), source: "btle_log", origin: .btleServerLog)
        logMonitor.handleSimulatedGoogleReport(reportID: 2, data: Data([0x00, 0x00]), source: "btle_log", origin: .btleServerLog)
        #expect(logMonitor.btleLogPendingGestureButtons == [.mute])

        let homeUsage = RemoteButton.home.hidUsage
        nativeMonitor.handleSimulatedReport(reportID: 1, data: Data([UInt8(homeUsage & 255), UInt8(homeUsage >> 8)]), source: "device")
        nativeMonitor.handleSimulatedReport(reportID: 1, data: Data([0x00, 0x00]), source: "device")
        #expect(coordinator.isActive)

        model.setG9N9NBluetoothLogRecoveryEnabled(false)
        #expect(logMonitor.btleLogPendingGestureButtons.isEmpty)
        #expect(coordinator.isActive)

        coordinator.finishIfActive(reason: "test_cleanup", confirmed: false)

        // 3. When the BTLE log remote ITSELF owns the active App Switcher, disabling log recovery closes it.
        model.setG9N9NBluetoothLogRecoveryEnabled(true)
        await model.bluetoothLoggingProfileRefreshTask?.value
        logMonitor.handleSimulatedGoogleReport(reportID: 2, data: Data([0x23, 0x02]), source: "btle_log", origin: .btleServerLog)
        logMonitor.handleSimulatedGoogleReport(reportID: 2, data: Data([0x00, 0x00]), source: "btle_log", origin: .btleServerLog)
        #expect(coordinator.isActive)
        model.setG9N9NBluetoothLogRecoveryEnabled(false)
        #expect(!coordinator.isActive)
    }
}
