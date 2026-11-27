import Foundation
import IOKit
import Testing
@testable import RemoteBuddy

@Suite("Runtime permission & signature diagnostics")
@MainActor
struct RuntimePermissionDiagnosticsTests {
    @Test func hidDeviceOpenFailureMessageKeyHandlesNotPermittedAndExclusiveAccess() {
        #expect(
            HIDRemoteMonitor.deviceOpenFailureMessageKey(
                result: kIOReturnNotPermitted,
                karabinerElementsInstalled: false
            ) == HIDStatusKeys.notPermitted
        )
        #expect(
            HIDRemoteMonitor.deviceOpenFailureMessageKey(
                result: kIOReturnNotPermitted,
                karabinerElementsInstalled: true
            ) == HIDStatusKeys.notPermitted
        )
        #expect(
            HIDRemoteMonitor.deviceOpenFailureMessageKey(
                result: kIOReturnExclusiveAccess,
                karabinerElementsInstalled: false
            ) == "button_mapping.error.exclusive_access"
        )
        #expect(
            HIDRemoteMonitor.deviceOpenFailureMessageKey(
                result: kIOReturnExclusiveAccess,
                karabinerElementsInstalled: true
            ) == "button_mapping.error.exclusive_access.karabiner"
        )
        #expect(
            HIDRemoteMonitor.deviceOpenFailureMessageKey(
                result: kIOReturnError,
                karabinerElementsInstalled: false
            ) == nil
        )
    }

    @Test func diagnosisIgnoresUninitializedOrUnusedPermissionsWithoutRuntimeFailure() {
        #expect(
            RuntimePermissionDiagnosisPolicy.diagnose(
                bluetoothGranted: false,
                inputMonitoringGranted: false,
                accessibilityGranted: false,
                connectionStatusKey: "bluetooth.status.initializing",
                hidStatusKey: "button_mapping.status.disabled",
                hidFilterFailure: .none
            ) == nil
        )

        // Transient Bluetooth resetting should not flash a banner.
        #expect(
            RuntimePermissionDiagnosisPolicy.diagnose(
                bluetoothGranted: true,
                inputMonitoringGranted: true,
                accessibilityGranted: true,
                connectionStatusKey: "bluetooth.status.resetting",
                hidStatusKey: "button_mapping.status.waiting_for_device",
                hidFilterFailure: .none
            ) == nil
        )
    }

    @Test func diagnosisDetectsDesyncedSignalsGenuineRuntimeDenialsAndPreferredSettingsURLs() {
        let combinedDesync = RuntimePermissionDiagnosisPolicy.diagnose(
            bluetoothGranted: true,
            inputMonitoringGranted: true,
            accessibilityGranted: true,
            connectionStatusKey: BluetoothStatusKeys.permissionDenied,
            hidStatusKey: HIDStatusKeys.notPermitted,
            hidFilterFailure: .tapCreateFailed
        )
        #expect(
            combinedDesync == .permissionDesynced(
                signals: ["bluetooth_unauthorized", "hid_open_not_permitted", "hid_filter_tap_create_failed"]
            )
        )
        #expect(
            combinedDesync?.preferredPrivacySettingsURLString ==
                "x-apple.systempreferences:com.apple.preference.security?Privacy"
        )

        let bluetoothOnlyDesync = RuntimePermissionDiagnosisPolicy.diagnose(
            bluetoothGranted: true,
            inputMonitoringGranted: true,
            accessibilityGranted: true,
            connectionStatusKey: BluetoothStatusKeys.permissionDenied,
            hidStatusKey: "button_mapping.status.connected",
            hidFilterFailure: .none
        )
        #expect(bluetoothOnlyDesync == .permissionDesynced(signals: ["bluetooth_unauthorized"]))
        #expect(
            bluetoothOnlyDesync?.preferredPrivacySettingsURLString ==
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"
        )

        let systemDisabledDesync = RuntimePermissionDiagnosisPolicy.diagnose(
            bluetoothGranted: true,
            inputMonitoringGranted: true,
            accessibilityGranted: true,
            connectionStatusKey: "connection.status.connected_to_device",
            hidStatusKey: HIDStatusKeys.interrupted,
            hidFilterFailure: .systemDisabled
        )
        #expect(systemDisabledDesync == .permissionDesynced(signals: ["hid_filter_system_disabled"]))
        #expect(
            systemDisabledDesync?.preferredPrivacySettingsURLString ==
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        )

        #expect(
            RuntimePermissionDiagnosisPolicy.diagnose(
                bluetoothGranted: false,
                inputMonitoringGranted: true,
                accessibilityGranted: true,
                connectionStatusKey: BluetoothStatusKeys.permissionDenied,
                hidStatusKey: "button_mapping.status.waiting_for_device",
                hidFilterFailure: .none
            ) == .bluetoothPermissionDenied
        )

        #expect(
            RuntimePermissionDiagnosisPolicy.diagnose(
                bluetoothGranted: true,
                inputMonitoringGranted: false,
                accessibilityGranted: true,
                connectionStatusKey: "connection.status.searching",
                hidStatusKey: HIDStatusKeys.notPermitted,
                hidFilterFailure: .none
            ) == .inputMonitoringPermissionDenied
        )

        #expect(
            RuntimePermissionDiagnosisPolicy.diagnose(
                bluetoothGranted: true,
                inputMonitoringGranted: true,
                accessibilityGranted: true,
                connectionStatusKey: BluetoothStatusKeys.off,
                hidStatusKey: "button_mapping.status.waiting_for_device",
                hidFilterFailure: .none
            ) == .bluetoothUnavailable(statusKey: BluetoothStatusKeys.off)
        )
    }

    @Test func keyboardSuppressorTracksTapCreationFailureOnlyWhenPermissionsGranted() {
        var granted = false
        var startResult = false
        let deniedSuppressor = KeyboardEventSuppressor(
            permissionsGranted: { granted },
            tapOperations: .init(
                start: { startResult },
                stop: {},
                isEnabled: { false }
            )
        )
        #expect(!deniedSuppressor.start())
        #expect(!deniedSuppressor.didTapCreationFailDespitePermissions)

        granted = true
        #expect(!deniedSuppressor.start())
        #expect(deniedSuppressor.didTapCreationFailDespitePermissions)

        startResult = true
        #expect(deniedSuppressor.start())
        #expect(!deniedSuppressor.didTapCreationFailDespitePermissions)

        deniedSuppressor.stop()
        #expect(!deniedSuppressor.didTapCreationFailDespitePermissions)
    }

    @Test func appModelDetectsSystemDisabledEventTapAsDesyncEvenWhenPermissionsReportGranted() throws {
        let suiteName = "runtime-perm-tap-disabled-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = BridgeAppModel(
            settings: AppSettings(defaults: defaults),
            permissionSnapshotProvider: {
                HIDPermissionSnapshot(inputMonitoringGranted: true, accessibilityGranted: true)
            }
        )
        model.hidEventSuppressor.onSystemDisabled?()

        #expect(model.hidStatus.key == HIDStatusKeys.interrupted)
        #expect(model.hidFilterFailureState == .systemDisabled)
        #expect(model.runtimePermissionIssue == .permissionDesynced(signals: ["hid_filter_system_disabled"]))
        #expect(model.runtimePermissionIssueUpdatedAt != nil)
        #expect(model.runtimePermissionDiagnosisTrigger == "hid_filter_disabled")

        model.hidFilterFailureState = .none
        model.hidStatus = LocalizedMessage("button_mapping.status.connected")
        model.refreshRuntimePermissionDiagnosis(trigger: "recovered", bluetoothGranted: true)
        #expect(model.runtimePermissionIssue == nil)
        #expect(model.runtimePermissionIssueUpdatedAt == nil)
        #expect(model.runtimePermissionDiagnosisTrigger == nil)
    }

    @Test func firstUseContextChecksStaticPermissionsOnPermissionsStepAndDesyncOnRemoteStep() {
        let ungranted = OnboardingCapabilities(
            bluetoothGranted: false,
            inputMonitoringGranted: true,
            accessibilityGranted: true,
            remoteConnected: false,
            remoteButtonObserved: false
        )
        let permissionsContext = FirstUseDiagnosticContext(
            step: .permissions,
            controlMethod: .physicalRemote,
            capabilities: ungranted,
            hasSelectedAudioUID: false,
            runtimePermissionIssue: .permissionDesynced(signals: ["hid_filter_system_disabled"])
        )
        #expect(permissionsContext.failureReason == .bluetoothPermissionDenied)

        let granted = OnboardingCapabilities(
            bluetoothGranted: true,
            inputMonitoringGranted: true,
            accessibilityGranted: true,
            remoteConnected: false,
            remoteButtonObserved: false
        )
        let issue = RuntimePermissionIssue.permissionDesynced(signals: ["bluetooth_unauthorized"])
        let remoteContext = FirstUseDiagnosticContext(
            step: .remote,
            controlMethod: .physicalRemote,
            capabilities: granted,
            hasSelectedAudioUID: false,
            runtimePermissionIssue: issue
        )

        #expect(remoteContext.failureReason == .permissionDesynced)
        #expect(remoteContext.failureReason?.recoveryStep == .permissions)

        let snapshot = FirstUseDiagnosticSnapshot(
            appVersion: "1.0",
            appBuild: "718",
            systemMajorVersion: 15,
            architecture: "arm64",
            voiceTool: .unselected,
            voiceKeyMode: .function,
            voiceShortcutName: "Fn/Globe",
            voiceFnTapModeEnabled: false,
            context: remoteContext,
            voiceAttempt: FirstUseVoiceAttemptDiagnostic(
                attemptID: 0,
                phase: .idle,
                triggerPath: "none",
                triggerReady: false,
                editorMounted: false,
                windowKeyAtStart: false,
                firstResponderAtStart: false,
                firstResponderAtEnd: false,
                focusLost: false,
                firstSampleLatencyMilliseconds: nil,
                sessionDurationMilliseconds: nil,
                transcriptWaitMilliseconds: nil,
                result: .none
            ),
            bluetoothStatus: BluetoothStatusKeys.permissionDenied,
            buttonStatus: HIDStatusKeys.notPermitted,
            audioStatus: "audio.output.none_selected",
            events: [],
            appLanguage: "en"
        )

        #expect(snapshot.redactedText.contains("voice_key_mode=fn"))
        #expect(snapshot.redactedText.contains("voice_shortcut=Fn/Globe"))
        #expect(snapshot.redactedText.contains("failure=permission.desynced"))
        #expect(snapshot.redactedText.contains("runtime_permission_issue=permission_desynced(bluetooth_unauthorized)"))
    }

    @Test func relaunchApplicationValidatesBundleTerminationAndProcessLaunch() throws {
        let suiteName = "runtime-perm-relaunch-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = BridgeAppModel(settings: AppSettings(defaults: defaults))
        var launchedCalls: [(executable: String, arguments: [String])] = []
        var terminateCount = 0

        let nonAppResult = model.relaunchApplication(
            bundleURL: FileManager.default.temporaryDirectory,
            pid: 4242,
            launchProcess: { exe, args in launchedCalls.append((exe, args)) },
            terminateHandler: { terminateCount += 1 }
        )
        #expect(!nonAppResult)
        #expect(launchedCalls.isEmpty)
        #expect(terminateCount == 0)

        let tempAppURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteBuddyTest-\(UUID().uuidString).app")
        #expect(!BridgeAppModel.canRelaunchAppBundle(tempAppURL))
        try FileManager.default.createDirectory(at: tempAppURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempAppURL) }
        #expect(BridgeAppModel.canRelaunchAppBundle(tempAppURL))

        struct SimulatedLaunchFailure: Error {}
        let failedLaunch = model.relaunchApplication(
            bundleURL: tempAppURL,
            pid: 4242,
            launchProcess: { _, _ in throw SimulatedLaunchFailure() },
            terminateHandler: { terminateCount += 1 }
        )
        #expect(!failedLaunch)
        #expect(terminateCount == 0)

        let succeededLaunch = model.relaunchApplication(
            bundleURL: tempAppURL,
            pid: 4242,
            launchProcess: { exe, args in launchedCalls.append((exe, args)) },
            terminateHandler: { terminateCount += 1 }
        )
        #expect(succeededLaunch)
        #expect(launchedCalls.count == 1)
        #expect(launchedCalls[0].executable == "/bin/sh")
        #expect(launchedCalls[0].arguments.contains("4242"))
        #expect(launchedCalls[0].arguments.contains(tempAppURL.path))
        #expect(terminateCount == 1)

        model.prepareForTermination()
        let terminatingRelaunch = model.relaunchApplication(
            bundleURL: tempAppURL,
            pid: 4242,
            launchProcess: { exe, args in launchedCalls.append((exe, args)) },
            terminateHandler: { terminateCount += 1 }
        )
        #expect(!terminatingRelaunch)
        #expect(launchedCalls.count == 1)
        #expect(terminateCount == 1)
    }

    @Test func settingsDiagnosticSnapshotIncludesRuntimePermissionFields() {
        let updatedAt = Date(timeIntervalSince1970: 1_763_000_000)
        let snapshot = SettingsDiagnosticSnapshot(
            appVersion: "1.0",
            bluetoothGranted: true,
            inputMonitoringGranted: true,
            accessibilityGranted: true,
            runtimeLogAvailable: true,
            runtimePermissionIssue: "permission_desynced(bluetooth_unauthorized)",
            runtimePermissionIssueUpdatedAt: updatedAt,
            runtimePermissionDiagnosisTrigger: "hid_filter_disabled",
            connectionStatusKey: BluetoothStatusKeys.permissionDenied,
            hidStatusKey: HIDStatusKeys.notPermitted
        )
        let summary = snapshot.summary
        #expect(summary.contains("permission_desynced(bluetooth_unauthorized)"))
        #expect(summary.contains("Permission Diagnosis Trigger: hid_filter_disabled"))
        #expect(summary.contains("Permission Issue Updated At: 2025-11-13T"))
        #expect(summary.contains("Bluetooth Connection Status: bluetooth.status.permission_denied"))
        #expect(summary.contains("Button Mapping Status: button_mapping.error.not_permitted"))
    }

    @Test func newPermissionAndDiagnosticLocalizationKeysExistInEnglishAndChinese() throws {
        let suiteName = "locale-runtime-perm-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = LocalizationStore(settings: AppSettings(defaults: defaults))

        let keys = [
            HIDStatusKeys.notPermitted,
            "permission.desync.banner.title",
            "permission.desync.banner.detail",
            "permission.desync.banner.detail.with_restart",
            "permission.desync.action.restart",
            "permission.desync.action.open_settings",
            "permission.desync.restart_confirm.title",
            "permission.desync.restart_confirm.message",
            "onboarding.recovery.permission.desynced.title",
            "onboarding.recovery.permission.desynced.detail",
            "onboarding.recovery.permission.desynced.detail.with_restart",
            "onboarding.remote.permission_desync.title",
            "onboarding.remote.permission_desync.detail",
            "onboarding.remote.permission_desync.detail.with_restart",
            "onboarding.remote.bluetooth_denied.title",
            "onboarding.remote.bluetooth_denied.detail",
            "onboarding.remote.input_not_permitted.title",
            "onboarding.remote.input_not_permitted.detail",
            "onboarding.remote.bluetooth_unavailable.detail",
            "onboarding.recovery.permission.post_event_restricted.title",
            "onboarding.recovery.permission.post_event_restricted.detail",
            "onboarding.recovery.permission.post_event_restricted.detail.with_restart",
            "permission.post_event_restricted.banner.title",
            "permission.post_event_restricted.banner.detail",
            "permission.post_event_restricted.banner.detail.with_restart"
        ]

        for key in keys {
            store.select(.english)
            let en = store.text(key)
            store.select(.simplifiedChinese)
            let zh = store.text(key)
            #expect(en != key)
            #expect(zh != key)
            #expect(en != zh)
        }

        let detailKeys = [
            "onboarding.recovery.permission.post_event_restricted.detail",
            "onboarding.recovery.permission.post_event_restricted.detail.with_restart",
            "permission.post_event_restricted.banner.detail",
            "permission.post_event_restricted.banner.detail.with_restart"
        ]
        for key in detailKeys {
            store.select(.english)
            let en = store.text(key)
            #expect(en.contains("System & App Protection Override"))
            #expect(en.contains("Accessibility"))
            store.select(.simplifiedChinese)
            let zh = store.text(key)
            #expect(zh.contains("System & App Protection Override"))
            #expect(zh.contains("辅助功能"))
        }
    }

    @Test func diagnosisDetectsRestrictedPostEventAccessAndSnapshotTracksIt() {
        let restricted = RuntimePermissionDiagnosisPolicy.diagnose(
            bluetoothGranted: true,
            inputMonitoringGranted: true,
            accessibilityGranted: true,
            postEventAccessGranted: false,
            connectionStatusKey: "connection.status.connected_to_device",
            hidStatusKey: "button_mapping.status.connected",
            hidFilterFailure: .none
        )
        #expect(restricted == .postEventAccessRestricted)
        #expect(restricted?.diagnosticIdentifier == "post_event_access_restricted")
        #expect(
            restricted?.preferredPrivacySettingsURLString ==
                "x-apple.systempreferences:com.apple.preference.security?Privacy"
        )

        #expect(
            RuntimePermissionDiagnosisPolicy.diagnose(
                bluetoothGranted: true,
                inputMonitoringGranted: true,
                accessibilityGranted: false,
                postEventAccessGranted: false,
                connectionStatusKey: "connection.status.connected_to_device",
                hidStatusKey: "button_mapping.status.connected",
                hidFilterFailure: .none
            ) == nil
        )

        #expect(
            RuntimePermissionDiagnosisPolicy.diagnose(
                bluetoothGranted: false,
                inputMonitoringGranted: true,
                accessibilityGranted: true,
                postEventAccessGranted: false,
                connectionStatusKey: BluetoothStatusKeys.permissionDenied,
                hidStatusKey: "button_mapping.status.connected",
                hidFilterFailure: .none
            ) == .bluetoothPermissionDenied
        )

        #expect(
            RuntimePermissionDiagnosisPolicy.diagnose(
                bluetoothGranted: true,
                inputMonitoringGranted: true,
                accessibilityGranted: true,
                postEventAccessGranted: false,
                connectionStatusKey: BluetoothStatusKeys.permissionDenied,
                hidStatusKey: "button_mapping.status.connected",
                hidFilterFailure: .none
            ) == .permissionDesynced(signals: ["bluetooth_unauthorized"])
        )

        #expect(
            RuntimePermissionDiagnosisPolicy.diagnose(
                bluetoothGranted: true,
                inputMonitoringGranted: true,
                accessibilityGranted: true,
                postEventAccessGranted: false,
                connectionStatusKey: BluetoothStatusKeys.off,
                hidStatusKey: "button_mapping.status.connected",
                hidFilterFailure: .none
            ) == .bluetoothUnavailable(statusKey: BluetoothStatusKeys.off)
        )

        let defaulted = HIDPermissionSnapshot(inputMonitoringGranted: true, accessibilityGranted: true)
        let restrictedSnapshot = HIDPermissionSnapshot(
            inputMonitoringGranted: true,
            accessibilityGranted: true,
            postEventAccessGranted: false
        )
        #expect(defaulted.postEventAccessGranted)
        #expect(!restrictedSnapshot.postEventAccessGranted)
        #expect(defaulted != restrictedSnapshot)
    }

    @Test func appModelFirstUseAndSettingsDiagnosticsReflectRestrictedPostEventAccess() throws {
        let suiteName = "runtime-perm-post-event-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var postEventGranted = false
        let model = BridgeAppModel(
            settings: AppSettings(defaults: defaults),
            permissionSnapshotProvider: {
                HIDPermissionSnapshot(
                    inputMonitoringGranted: true,
                    accessibilityGranted: true,
                    postEventAccessGranted: postEventGranted
                )
            }
        )
        model.refreshRuntimePermissionDiagnosis(trigger: "post_event_test", bluetoothGranted: true)
        #expect(model.runtimePermissionIssue == .postEventAccessRestricted)

        postEventGranted = true
        model.refreshRuntimePermissionDiagnosis(trigger: "post_event_recovered", bluetoothGranted: true)
        #expect(model.runtimePermissionIssue == nil)

        let grantedCapabilities = OnboardingCapabilities(
            bluetoothGranted: true,
            inputMonitoringGranted: true,
            accessibilityGranted: true,
            remoteConnected: true,
            remoteButtonObserved: true
        )
        let restrictedIssue = RuntimePermissionIssue.postEventAccessRestricted
        #expect(
            FirstUseDiagnosticContext(
                step: .permissions,
                controlMethod: .physicalRemote,
                capabilities: grantedCapabilities,
                hasSelectedAudioUID: true,
                runtimePermissionIssue: restrictedIssue
            ).failureReason == .postEventAccessRestricted
        )
        #expect(
            FirstUseDiagnosticContext(
                step: .remote,
                controlMethod: .physicalRemote,
                capabilities: grantedCapabilities,
                hasSelectedAudioUID: true,
                runtimePermissionIssue: restrictedIssue
            ).failureReason == nil
        )
        #expect(
            FirstUseDiagnosticContext(
                step: .voiceTrigger,
                controlMethod: .physicalRemote,
                capabilities: grantedCapabilities,
                hasSelectedAudioUID: true,
                runtimePermissionIssue: restrictedIssue
            ).failureReason == .postEventAccessRestricted
        )
        #expect(
            FirstUseDiagnosticContext(
                step: .controls,
                controlMethod: .physicalRemote,
                capabilities: grantedCapabilities,
                hasSelectedAudioUID: true,
                runtimePermissionIssue: restrictedIssue
            ).failureReason == .postEventAccessRestricted
        )

        var voiceAttempt = FirstUseVoiceAttemptDiagnostic()
        voiceAttempt.attemptID = 1
        voiceAttempt.phase = .failed
        voiceAttempt.result = .externalToolNoCommit
        let voiceTestContext = FirstUseDiagnosticContext(
            step: .voiceTest,
            controlMethod: .physicalRemote,
            capabilities: grantedCapabilities,
            hasSelectedAudioUID: true,
            voiceAttempt: voiceAttempt,
            runtimePermissionIssue: restrictedIssue
        )
        #expect(voiceTestContext.failureReason == .postEventAccessRestricted)
        #expect(voiceTestContext.failureReason?.recoveryStep == .permissions)

        let firstUseSnapshot = FirstUseDiagnosticSnapshot(
            appVersion: "1.0",
            appBuild: "968",
            systemMajorVersion: 27,
            architecture: "arm64",
            voiceTool: .weixin,
            voiceKeyMode: .rightOption,
            voiceShortcutName: "Right Option",
            context: voiceTestContext,
            voiceAttempt: voiceAttempt,
            bluetoothStatus: "connection.status.connected_to_device",
            buttonStatus: "button_mapping.status.connected",
            audioStatus: "audio.output.current_format",
            events: [],
            appLanguage: "zh-Hans",
            postEventAccessGranted: false
        )
        #expect(firstUseSnapshot.redactedText.contains("permission_post_event=false"))
        #expect(firstUseSnapshot.redactedText.contains("failure=permission.post_event_restricted"))
        #expect(firstUseSnapshot.redactedText.contains("runtime_permission_issue=post_event_access_restricted"))

        let settingsSnapshot = SettingsDiagnosticSnapshot(
            appVersion: "1.0",
            bluetoothGranted: true,
            inputMonitoringGranted: true,
            accessibilityGranted: true,
            postEventAccessGranted: false,
            runtimeLogAvailable: true,
            runtimePermissionIssue: "post_event_access_restricted"
        )
        #expect(settingsSnapshot.summary.contains("Post Event Access: 受限或未授权 (Denied/Restricted)"))
        #expect(settingsSnapshot.auditLog.contains("post_event=false"))
    }

    @Test func voiceTestStatusAndResolvedFailureAlignWithRestrictedPostEventPermission() {
        #expect(
            FirstUseVoiceAttemptPolicy.resolvedFailureReason(
                result: .externalToolNoCommit,
                runtimePermissionIssue: .postEventAccessRestricted
            ) == .postEventAccessRestricted
        )
        #expect(
            FirstUseVoiceAttemptPolicy.resolvedFailureReason(
                result: .externalToolNoCommit,
                runtimePermissionIssue: .permissionDesynced(signals: ["hid_filter_system_disabled"])
            ) == .permissionDesynced
        )
        #expect(
            FirstUseVoiceAttemptPolicy.resolvedFailureReason(
                result: .externalToolNoCommit,
                runtimePermissionIssue: nil
            ) == .voiceExternalToolNoCommit
        )
        #expect(
            FirstUseVoiceAttemptPolicy.resolvedFailureReason(
                result: .passed,
                runtimePermissionIssue: .postEventAccessRestricted
            ) == nil
        )

        #expect(
            OnboardingView.voiceTestStatusKey(
                toolReady: true,
                manualInput: false,
                result: .externalToolNoCommit,
                sessionStarted: true,
                samplesReceived: true,
                sessionEnded: true,
                runtimePermissionIssue: .postEventAccessRestricted
            ) == "onboarding.recovery.permission.post_event_restricted.title"
        )
        #expect(
            OnboardingView.voiceTestStatusKey(
                toolReady: true,
                manualInput: false,
                result: .none,
                sessionStarted: false,
                samplesReceived: false,
                sessionEnded: false,
                runtimePermissionIssue: .postEventAccessRestricted
            ) == "onboarding.recovery.permission.post_event_restricted.title"
        )
        #expect(
            OnboardingView.voiceTestStatusKey(
                toolReady: true,
                manualInput: false,
                result: .none,
                sessionStarted: true,
                samplesReceived: true,
                sessionEnded: false,
                runtimePermissionIssue: .postEventAccessRestricted
            ) == "onboarding.voice_test.receiving"
        )
        #expect(
            OnboardingView.voiceTestStatusKey(
                toolReady: true,
                manualInput: false,
                result: .passed,
                sessionStarted: true,
                samplesReceived: true,
                sessionEnded: true,
                runtimePermissionIssue: .postEventAccessRestricted
            ) == "onboarding.voice_test.success"
        )
    }

    @Test func postEventPermissionChangesRefreshDiagnosisWithoutRebuildingHIDMonitors() throws {
        let granted = HIDPermissionSnapshot(
            inputMonitoringGranted: true,
            accessibilityGranted: true,
            postEventAccessGranted: true
        )
        let restricted = HIDPermissionSnapshot(
            inputMonitoringGranted: true,
            accessibilityGranted: true,
            postEventAccessGranted: false
        )
        let denied = HIDPermissionSnapshot(
            inputMonitoringGranted: true,
            accessibilityGranted: false,
            postEventAccessGranted: false
        )

        #expect(
            !HIDPermissionRecoveryPolicy.shouldReapplySettings(
                started: true,
                previous: granted,
                current: restricted
            )
        )
        #expect(
            !HIDPermissionRecoveryPolicy.shouldReapplySettings(
                started: true,
                previous: restricted,
                current: granted
            )
        )
        #expect(
            HIDPermissionRecoveryPolicy.shouldReapplySettings(
                started: true,
                previous: restricted,
                current: denied
            )
        )

        #expect(
            !BridgeAppModel.shouldReapplyHIDSettingsBeforeVoiceStart(
                mode: .rightOption,
                fnTapModeEnabled: false,
                requiresOrderedFn: false,
                hasHardwareVoiceKey: true,
                hasMatchingHIDServices: true,
                isVoiceKeyNeutralized: true,
                currentServicesMatchDesiredMapping: true,
                fnTapSessionEnabled: true,
                monitoringInterrupted: false,
                monitoringConfigurationApplied: true,
                appliedPermissionSnapshot: granted,
                currentPermissionSnapshot: restricted
            )
        )

        let suiteName = "runtime-perm-no-hid-rebuild-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var postEventGranted = true
        let model = BridgeAppModel(
            settings: AppSettings(defaults: defaults),
            permissionSnapshotProvider: {
                HIDPermissionSnapshot(
                    inputMonitoringGranted: true,
                    accessibilityGranted: true,
                    postEventAccessGranted: postEventGranted
                )
            }
        )
        let initialConfig = BridgeAppModel.HIDMonitoringConfiguration(
            powerKeySuppressed: true,
            waitForMatchingServices: false,
            allowedLocationIDs: nil,
            targets: [],
            compatibleHIDIdentities: [],
            excludedDiscoveryFingerprints: [],
            monitoringPermissions: granted.monitoringPermissions
        )
        model.started = true
        model.appliedHIDPermissionSnapshot = granted
        model.appliedHIDMonitoringConfiguration = initialConfig

        postEventGranted = false
        model.refreshHIDAfterPermissionChange()
        #expect(model.runtimePermissionIssue == .postEventAccessRestricted)
        #expect(model.appliedHIDMonitoringConfiguration == initialConfig)
        #expect(model.appliedHIDPermissionSnapshot == restricted)

        postEventGranted = true
        model.refreshHIDAfterPermissionChange()
        #expect(model.runtimePermissionIssue == nil)
        #expect(model.appliedHIDMonitoringConfiguration == initialConfig)
        #expect(model.appliedHIDPermissionSnapshot == granted)
    }
}
