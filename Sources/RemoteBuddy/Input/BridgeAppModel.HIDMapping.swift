import AppKit
import AVFoundation
import Combine
import CoreAudio
import CoreBluetooth
import Foundation

extension BridgeAppModel {
    func applyHIDSettings(
        allowVoiceKeyModeFallback: Bool = true,
        forceRestartMonitors: Bool = false
    ) {
        if audio.suspensionState.suspendsHIDMonitoring {
            suspendHIDMonitoring(reason: "system_suspended")
            return
        }
        let permissionSnapshot = permissionSnapshotProvider()
        appliedHIDPermissionSnapshot = permissionSnapshot
        if !permissionSnapshot.inputMonitoringGranted || !permissionSnapshot.accessibilityGranted {
            // Detach input filtering before system calls and the Fn-cleanup early return below.
            // The later startHIDMonitors() teardown cannot protect that early-return path.
            stopHIDMonitors()
        }
        if !permissionSnapshot.accessibilityGranted {
            _ = releaseVoiceKeyIfNeeded()
        }
        if started, permissionSnapshot.inputMonitoringGranted, permissionSnapshot.accessibilityGranted {
            preferredInputSourceMonitor.start()
        } else {
            preferredInputSourceMonitor.stop(
                preservingExplicitVoiceSession: VoiceKeySessionPreservationPolicy
                    .shouldPreserveInputSourceSession(
                        latchHeld: voiceKeyLatch.isHeld,
                        heldMode: heldVoiceKeyMode,
                        pendingMode: pendingVoiceKeyMode
                    )
            )
        }
        let requestedVoiceKeyMode = settings.effectiveVoiceKeyMode
        let accessibilityGranted = permissionSnapshot.accessibilityGranted
        let requestedFnTapMode = settings.effectiveVoiceFnTapModeEnabled

        if !settings.isTestingVoiceTrigger && settings.effectiveVoiceFnTapModeEnabled != requestedFnTapMode {
            settings.voiceFnTapModeEnabled = requestedFnTapMode
        }
        if !requestedFnTapMode, voiceFnTapSession.requiresCleanupBeforeMapping {
            voiceFnTapSession.setEnabled(false) { [weak self] cleaned in
                guard cleaned else { return }
                self?.applyHIDSettings(
                    allowVoiceKeyModeFallback: allowVoiceKeyModeFallback,
                    forceRestartMonitors: forceRestartMonitors
                )
            }
            return
        }
        pendingHIDServiceMappingRefresh = false
        requestNextHIDPermissionIfNeeded()
        if settings.selectedRemoteProfile?.model.isATVVRemote == true {
            // ATVV remotes have no native Fn, while Xiaomi/T1 HID services still need
            // their global UserKeyMapping policy while this card is selected.
            let atvvPowerKeySuppressed = applyVoiceFunctionMapping(
                neutralizeVoiceKey: shouldNeutralizeNativeVoiceKey)
            voiceFnTapSession.setEnabled(requestedFnTapMode && accessibilityGranted)
            startHIDMonitors(
                powerKeySuppressed: atvvPowerKeySuppressed,
                forceRestart: forceRestartMonitors
            )
            if settings.selectedRemoteProfile?.model.isT1Remote == true {
                completeHIDMappingRecoveryIfNeeded()
                if voiceFunctionMapper.lastApplyFailedVerification {
                    scheduleHIDMappingRecoveryIfNeeded(verificationFailed: true)
                } else if !voiceFunctionMapper.hasMatchingServices {
                    scheduleHIDMappingRecoveryIfNeeded()
                }
            }
            refreshVoiceKeyCompatibilityWarning()
            return
        }

        let canFallbackVoiceKeyMode = Self.canFallbackVoiceKeyMode(
            isStreaming: isStreaming,
            allowVoiceKeyModeFallback: allowVoiceKeyModeFallback
        )
        var powerKeySuppressed: Bool
        if requiresOrderedVoiceFn {
            voiceFnTapSession.setEnabled(false)
            powerKeySuppressed = applyVoiceFunctionMapping(neutralizeVoiceKey: true)
            if !voiceFunctionMapper.isVoiceKeyNeutralized {
                voiceShortcutStatus = LocalizedMessage("voice_button.status.waiting")
                AppLogger.shared.write("VOICE KEY ordered_fn waiting reason=native_key_not_neutralized")
            }
        } else if requestedFnTapMode, accessibilityGranted {
            powerKeySuppressed = applyVoiceFunctionMapping(neutralizeVoiceKey: true)
            if voiceFunctionMapper.isVoiceKeyNeutralized {
                voiceFnTapSession.setEnabled(true)
            } else if !canFallbackVoiceKeyMode, isStreaming {
                AppLogger.shared.write(
                    "VOICE FN TAP mode_preserved reason=voice_active_mapping_failed"
                )
            } else if !canFallbackVoiceKeyMode {
                AppLogger.shared.write(
                    "VOICE FN TAP mode_preserved reason=voice_start_mapping_failed"
                )
            } else if HIDMappingRecoveryPolicy.shouldPreserveFnTapPreferenceAfterMappingFailure(
                hasMatchingServices: voiceFunctionMapper.hasMatchingServices
            ) {
                voiceFnTapSession.setEnabled(false)
                AppLogger.shared.write(
                    "VOICE FN TAP mode_pending_mapping reason=no_matching_service"
                )
                scheduleHIDMappingRecoveryIfNeeded()
            } else {
                if !settings.isTestingVoiceTrigger { settings.voiceFnTapModeEnabled = false }
                voiceFnTapSession.setEnabled(false)
                powerKeySuppressed = applyVoiceFunctionMapping(neutralizeVoiceKey: false)
            }
        } else if requestedVoiceKeyMode != .function {
            powerKeySuppressed = applyVoiceFunctionMapping(neutralizeVoiceKey: true)
            if !voiceFunctionMapper.isVoiceKeyNeutralized {
                if voiceFunctionMapper.hasMatchingServices {
                    if isStreaming {
                        voiceShortcutStatus = LocalizedMessage("voice_button.status.waiting")
                        AppLogger.shared.write(
                            "VOICE KEY mode_preserved reason=voice_active_mapping_failed " +
                                "mode=\(requestedVoiceKeyMode.rawValue)"
                        )
                    } else if canFallbackVoiceKeyMode && !settings.isTestingVoiceTrigger {
                        settings.voiceKeyMode = .function
                        powerKeySuppressed = applyVoiceFunctionMapping(neutralizeVoiceKey: false)
                        AppLogger.shared.write(
                            "VOICE KEY mode_fallback reason=voice_mapping_failed " +
                                "mode=\(requestedVoiceKeyMode.rawValue)"
                        )
                    } else {
                        voiceShortcutStatus = LocalizedMessage("voice_button.status.waiting")
                        AppLogger.shared.write(
                            "VOICE KEY mode_preserved reason=voice_start_mapping_failed " +
                                "mode=\(requestedVoiceKeyMode.rawValue)"
                        )
                    }
                } else if !accessibilityGranted {
                    voiceShortcutStatus = LocalizedMessage(
                        "connection.voice_key_mode.command_permission"
                    )
                    AppLogger.shared.write(
                        "VOICE KEY mode_pending_permission_and_mapping " +
                            "mode=\(requestedVoiceKeyMode.rawValue)"
                    )
                } else {
                    voiceShortcutStatus = LocalizedMessage("voice_button.status.waiting")
                    AppLogger.shared.write(
                        "VOICE KEY mode_pending_mapping reason=no_matching_service " +
                            "mode=\(requestedVoiceKeyMode.rawValue)"
                    )
                }
            } else if !accessibilityGranted {
                voiceShortcutStatus = LocalizedMessage(
                    "connection.voice_key_mode.command_permission"
                )
                AppLogger.shared.write(
                    "VOICE KEY mode_pending_permission mode=\(requestedVoiceKeyMode.rawValue)"
                )
            }
        } else {
            if requestedFnTapMode {
                if !settings.isTestingVoiceTrigger { settings.voiceFnTapModeEnabled = false }
            }
            voiceFnTapSession.setEnabled(false)
            powerKeySuppressed = applyVoiceFunctionMapping(neutralizeVoiceKey: false)
        }
        startHIDMonitors(
            powerKeySuppressed: powerKeySuppressed,
            forceRestart: forceRestartMonitors
        )
        completeHIDMappingRecoveryIfNeeded()
        if voiceFunctionMapper.lastApplyFailedVerification {
            scheduleHIDMappingRecoveryIfNeeded(verificationFailed: true)
        } else if !voiceFunctionMapper.hasMatchingServices {
            scheduleHIDMappingRecoveryIfNeeded()
        }
        refreshVoiceKeyCompatibilityWarning()
    }

    func scheduleHIDMappingRecoveryIfNeeded(verificationFailed: Bool = false) {
        if settings.selectedRemoteProfile?.model.isChromecastRemote == true {
            cancelHIDMappingRecovery(reason: "google_atvv_voice")
            return
        }
        guard !audio.suspensionState.suspendsHIDMonitoring else {
            cancelHIDMappingRecovery(reason: "system_suspended")
            return
        }
        if verificationFailed {
            let permissions = permissionSnapshotProvider().monitoringPermissions
            guard permissions.inputMonitoringGranted, permissions.accessibilityGranted else { return }
        }
        guard hidMappingRecoveryWorkItem == nil else { return }
        let delay: TimeInterval?
        if verificationFailed {
            delay = HIDMappingRecoveryPolicy.verificationFailedRetryDelay(
                forAttempt: hidVerificationRecoveryAttempt,
                started: started
            )
        } else {
            delay = HIDMappingRecoveryPolicy.retryDelay(
                forAttempt: hidMappingRecoveryAttempt,
                started: started,
                readyBridgeCount: readyBluetoothBridgeCount,
                hasMatchingServices: voiceFunctionMapper.hasMatchingServices
            )
        }
        guard let delay else {
            if !verificationFailed,
               started,
               readyBluetoothBridgeCount > 0,
               !voiceFunctionMapper.hasMatchingServices,
               hidMappingRecoveryAttempt == HIDMappingRecoveryPolicy.retryDelays.count {
                AppLogger.shared.write(
                    "HID MAPPING RECOVERY exhausted attempts=\(hidMappingRecoveryAttempt) " +
                        "ready_bridges=\(readyBluetoothBridgeCount)"
                )
            } else if verificationFailed,
                      started,
                      hidVerificationRecoveryAttempt == HIDMappingRecoveryPolicy.retryDelays.count {
                AppLogger.shared.write(
                    "HID MAPPING RECOVERY verification_exhausted attempts=\(hidVerificationRecoveryAttempt)"
                )
            }
            return
        }

        let attempt: Int
        if verificationFailed {
            attempt = hidVerificationRecoveryAttempt + 1
            hidVerificationRecoveryAttempt = attempt
        } else {
            attempt = hidMappingRecoveryAttempt + 1
            hidMappingRecoveryAttempt = attempt
        }
        hidMappingRecoveryGeneration &+= 1
        let generation = hidMappingRecoveryGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.hidMappingRecoveryGeneration == generation else { return }
            self.hidMappingRecoveryWorkItem = nil
            guard self.started,
                  !self.audio.suspensionState.suspendsHIDMonitoring
            else {
                self.cancelHIDMappingRecovery(reason: "conditions_changed")
                return
            }
            if verificationFailed {
                let permissions = self.permissionSnapshotProvider().monitoringPermissions
                guard permissions.inputMonitoringGranted,
                      permissions.accessibilityGranted else {
                    self.cancelHIDMappingRecovery(reason: "conditions_changed")
                    return
                }
            } else {
                guard self.readyBluetoothBridgeCount > 0,
                      !self.voiceFunctionMapper.hasMatchingServices else {
                    self.cancelHIDMappingRecovery(reason: "conditions_changed")
                    return
                }
            }
            guard self.canRefreshHIDMappingsNow else {
                // Voice is active or awaiting teardown; defer catch-up until voice becomes idle.
                self.pendingHIDServiceMappingRefresh = true
                return
            }
            AppLogger.shared.write(
                "HID MAPPING RECOVERY applying attempt=\(attempt) " +
                    "verification_failed=\(verificationFailed) " +
                    "ready_bridges=\(self.readyBluetoothBridgeCount)"
            )
            self.applyHIDSettings()
            if !verificationFailed, !self.voiceFunctionMapper.hasMatchingServices {
                self.scheduleHIDMappingRecoveryIfNeeded()
            }
        }
        hidMappingRecoveryWorkItem = workItem
        AppLogger.shared.write(
            "HID MAPPING RECOVERY scheduled attempt=\(attempt) " +
                "verification_failed=\(verificationFailed) " +
                "delay_ms=\(Int(delay * 1_000)) ready_bridges=\(readyBluetoothBridgeCount)"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func completeHIDMappingRecoveryIfNeeded() {
        guard voiceFunctionMapper.hasMatchingServices else { return }
        if voiceFunctionMapper.lastApplyFailedVerification {
            if hidMappingRecoveryAttempt > 0 {
                hidMappingRecoveryAttempt = 0
                if hidVerificationRecoveryAttempt == 0, hidMappingRecoveryWorkItem != nil {
                    hidMappingRecoveryGeneration &+= 1
                    hidMappingRecoveryWorkItem?.cancel()
                    hidMappingRecoveryWorkItem = nil
                }
            }
            return
        }
        guard hidMappingRecoveryWorkItem != nil
            || hidMappingRecoveryAttempt > 0
            || hidVerificationRecoveryAttempt > 0
        else { return }
        let attempts = hidMappingRecoveryAttempt
        let verificationAttempts = hidVerificationRecoveryAttempt
        hidMappingRecoveryGeneration &+= 1
        hidMappingRecoveryWorkItem?.cancel()
        hidMappingRecoveryWorkItem = nil
        hidMappingRecoveryAttempt = 0
        hidVerificationRecoveryAttempt = 0
        AppLogger.shared.write(
            "HID MAPPING RECOVERY completed attempts=\(attempts) " +
                "verification_attempts=\(verificationAttempts) " +
                "matched=\(voiceFunctionMapper.matchedServiceCount)"
        )
    }

    func cancelHIDMappingRecovery(reason: String) {
        guard hidMappingRecoveryWorkItem != nil || hidMappingRecoveryAttempt > 0 || hidVerificationRecoveryAttempt > 0 else { return }
        let attempts = hidMappingRecoveryAttempt
        hidMappingRecoveryGeneration &+= 1
        hidMappingRecoveryWorkItem?.cancel()
        hidMappingRecoveryWorkItem = nil
        hidMappingRecoveryAttempt = 0
        hidVerificationRecoveryAttempt = 0
        AppLogger.shared.write(
            "HID MAPPING RECOVERY cancelled reason=\(reason) attempts=\(attempts)"
        )
    }

    func startHIDMonitors(powerKeySuppressed: Bool, forceRestart: Bool = false) {
        guard !audio.suspensionState.suspendsHIDMonitoring else {
            stopHIDMonitors()
            hidMonitoringInterrupted = true
            return
        }
        let allowedLocationIDs: Set<UInt32>? = voiceFunctionMapper.powerSuppressedLocationIDs
        let targets = settings.remoteDeviceProfiles.compactMap { profile -> HIDMonitorTargetConfiguration? in
            // Siri keeps a separate adapter. Xiaomi and G9N9N share the public HID engine.
            guard !profile.model.usesPrivateAdapter,
                  let fingerprint = profile.hidFingerprint
            else { return nil }
            return HIDMonitorTargetConfiguration(
                profileID: profile.id,
                fingerprint: fingerprint,
                model: profile.model
            )
        }
        let desiredConfiguration = HIDMonitoringConfiguration(
            powerKeySuppressed: powerKeySuppressed,
            waitForMatchingServices: !voiceFunctionMapper.hasMatchingServices,
            allowedLocationIDs: allowedLocationIDs,
            targets: targets,
            compatibleHIDIdentities: settings.compatibleHIDIdentities(
                includeXiaomi: true,
                includeGoogle: true,
                includeT1: true
            ),
            excludedDiscoveryFingerprints: settings.excludedForgottenHIDFingerprints(),
            monitoringPermissions: permissionSnapshotProvider().monitoringPermissions
        )
        if canReuseRunningHIDMonitors(for: desiredConfiguration, forceRestart: forceRestart) {
            hidPowerKeySuppressed = powerKeySuppressed
            hidAllowedLocationIDs = allowedLocationIDs
            synchronizeBTLEServerLogSource()
            return
        }

        stopHIDMonitors()
        hidPowerKeySuppressed = powerKeySuppressed
        hidAllowedLocationIDs = allowedLocationIDs
        let filterStarted = hidEventSuppressor.start()
        hidFilterFailureState = (!filterStarted && hidEventSuppressor.didTapCreationFailDespitePermissions)
            ? .tapCreateFailed
            : .none
        if !filterStarted {
            let permissions = permissionSnapshotProvider()
            AppLogger.shared.write(
                "HID FILTER start_failed tap_create_denied=\(hidEventSuppressor.didTapCreationFailDespitePermissions) " +
                    "input_monitoring=\(permissions.inputMonitoringGranted) " +
                    "accessibility=\(permissions.accessibilityGranted)"
            )
        }
        for target in targets {
            let monitor = makeHIDMonitor(
                profileID: target.profileID,
                targetFingerprint: target.fingerprint
            )
            hidMonitors[target.fingerprint] = monitor
            monitor.start(
                powerKeySuppressed: powerKeySuppressed,
                allowedLocationIDs: allowedLocationIDs,
                waitForMatchingServices: desiredConfiguration.waitForMatchingServices
            )
        }
        startHIDDiscoveryIfNeeded()
        let monitors = Array(hidMonitors.values) + (discoveryHIDMonitor.map { [$0] } ?? [])
        let allMonitorsHealthy = !monitors.isEmpty && monitors.allSatisfy { $0.isMonitoring }
        let suppressorHealthy = hidEventSuppressor.isRunning
        if allMonitorsHealthy, suppressorHealthy {
            hidMonitoringInterrupted = false
            appliedHIDMonitoringConfiguration = desiredConfiguration
        }
        synchronizeBTLEServerLogSource()
        refreshRuntimePermissionDiagnosis(trigger: "hid_monitors_started")
    }

    private func canReuseRunningHIDMonitors(
        for desiredConfiguration: HIDMonitoringConfiguration,
        forceRestart: Bool
    ) -> Bool {
        guard !forceRestart,
              !hidMonitoringInterrupted,
              appliedHIDMonitoringConfiguration == desiredConfiguration
        else { return false }
        let expectedFingerprints = Set(desiredConfiguration.targets.map(\.fingerprint))
        guard Set(hidMonitors.keys) == expectedFingerprints,
              let discoveryHIDMonitor
        else { return false }
        let monitors = Array(hidMonitors.values) + [discoveryHIDMonitor]
        let suppressorHealthy = hidEventSuppressor.isRunning
        return monitors.allSatisfy { $0.isMonitoring } && suppressorHealthy
    }

    func cancelButtonMappingInteractions(device: UUID?) {
        hidMonitors.values.filter { $0.profileID == device }.forEach { $0.cancelMappingInteractions() }
        if discoveryHIDMonitor?.profileID == device { discoveryHIDMonitor?.cancelMappingInteractions() }
        AppLogger.shared.write("BUTTON CONFIGURATION phase=completed result=interactions_cancelled")
    }

    func scheduleHIDFilterRetry(
        after delay: TimeInterval = 30,
        schedule: (TimeInterval, DispatchWorkItem) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    ) {
        cancelHIDFilterRetry()
        let token = UUID()
        hidFilterRetryToken = token
        let retry = DispatchWorkItem { [weak self] in
            guard let self, self.hidFilterRetryToken == token else { return }
            self.hidFilterRetryToken = nil
            self.hidFilterRetryWorkItem = nil
            guard self.started,
                  self.hidMonitoringInterrupted,
                  self.hidFilterFailureState == .systemDisabled
            else { return }
            self.refreshHIDAfterPermissionChange()
        }
        hidFilterRetryWorkItem = retry
        schedule(delay, retry)
    }

    func cancelHIDFilterRetry() {
        hidFilterRetryToken = nil
        hidFilterRetryWorkItem?.cancel()
        hidFilterRetryWorkItem = nil
    }

    func stopHIDMonitors() {
        // Detach the blocking event tap before any synchronous IOKit close.
        cancelHIDFilterRetry()
        appliedHIDMonitoringConfiguration = nil
        appSwitcherCoordinator.cancelAll()
        hidEventSuppressor.stop()
        hidMonitors.values.forEach { $0.stop() }
        discoveryHIDMonitor?.stop()
        hidMonitors.removeAll()
        discoveryHIDMonitor = nil
        activeRemoteButtons = []
        lastObservedRemoteButtonReport = nil
        synchronizeBTLEServerLogSource()
    }

    func applyBluetoothLoggingProfileStatus(_ status: BluetoothLoggingProfileStatus) {
        bluetoothLoggingProfileStatus = status
        synchronizeBTLEServerLogSource()
    }

    func refreshBluetoothLoggingProfileStatus(coalescingIfInFlight: Bool = true) {
        if coalescingIfInFlight,
           bluetoothLoggingProfileRefreshTask != nil,
           bluetoothLoggingProfileRefreshInFlightGeneration == bluetoothLoggingProfileStatusGeneration {
            return
        }
        bluetoothLoggingProfileRefreshTask?.cancel()
        bluetoothLoggingProfileStatusGeneration &+= 1
        let generation = bluetoothLoggingProfileStatusGeneration
        bluetoothLoggingProfileRefreshInFlightGeneration = generation
        let provider = bluetoothLoggingProfileStatusProvider
        bluetoothLoggingProfileRefreshTask = Task { [weak self] in
            let status = await provider()
            await MainActor.run {
                guard let self,
                      !Task.isCancelled,
                      self.bluetoothLoggingProfileStatusGeneration == generation
                else { return }
                self.bluetoothLoggingProfileRefreshTask = nil
                self.bluetoothLoggingProfileRefreshInFlightGeneration = nil
                self.applyBluetoothLoggingProfileStatus(status)
            }
        }
    }

    private enum BTLEServerLogRedactionPolicy {
        static let unattributedRefreshInterval: TimeInterval = 10.0
    }

    func startBluetoothLoggingProfileMonitorIfNeeded() {
        guard bluetoothLoggingProfileMonitorTask == nil else { return }
        let interval = bluetoothLoggingProfileCheckIntervalNanoseconds
        bluetoothLoggingProfileMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { break }
                let shouldContinue = await MainActor.run { [weak self] () -> Bool in
                    guard let self, self.isBTLEServerLogSourceActive(for: nil) else {
                        return false
                    }
                    self.refreshBluetoothLoggingProfileStatus(coalescingIfInFlight: true)
                    return true
                }
                if !shouldContinue { break }
            }
            await MainActor.run { [weak self] in
                self?.bluetoothLoggingProfileMonitorTask = nil
            }
        }
    }

    func stopBluetoothLoggingProfileMonitor() {
        bluetoothLoggingProfileMonitorTask?.cancel()
        bluetoothLoggingProfileMonitorTask = nil
    }

    func recheckBluetoothLoggingProfile() {
        btleServerLogRedactedObserved = false
        lastUnattributedRedactionProfileRefreshAt = nil
        bluetoothLoggingProfileStatus = .unknown
        stopBTLEServerLogSource(clearingRedactedObservation: true)
        for bridge in connections.bridges.values {
            learnSelectedRemoteHIDIdentity(bridge)
        }
        refreshBluetoothLoggingProfileStatus(coalescingIfInFlight: false)
    }

    func setG9N9NBluetoothLogRecoveryEnabled(_ enabled: Bool) {
        guard settings.g9n9nBluetoothLogRecoveryEnabled != enabled else {
            synchronizeBTLEServerLogSource()
            return
        }
        settings.g9n9nBluetoothLogRecoveryEnabled = enabled
        AppLogger.shared.write("SETTINGS G9N9N_BTLE_LOG enabled=\(enabled)")
        if enabled {
            btleServerLogRedactedObserved = false
            lastUnattributedRedactionProfileRefreshAt = nil
            bluetoothLoggingProfileStatus = .unknown
            stopBTLEServerLogSource(clearingRedactedObservation: true)
            for bridge in connections.bridges.values {
                learnSelectedRemoteHIDIdentity(bridge)
            }
            refreshBluetoothLoggingProfileStatus(coalescingIfInFlight: false)
        } else {
            bluetoothLoggingProfileStatusGeneration &+= 1
            bluetoothLoggingProfileRefreshTask?.cancel()
            bluetoothLoggingProfileRefreshTask = nil
            bluetoothLoggingProfileRefreshInFlightGeneration = nil
            stopBTLEServerLogSource(clearingRedactedObservation: true)
        }
    }

    enum BTLEServerLogDispatchTarget: Equatable {
        case boundMonitor(fingerprint: String, profileID: UUID)
        case drop(reason: String)
    }

    static func btleLogRecoveryTargetPeripherals(
        profiles: [RemoteDeviceProfile],
        isOnboardingComplete: Bool,
        onboardingControlSource: OnboardingControlSource,
        selectedProfileID: UUID?
    ) -> Set<UUID> {
        var targets = Set(
            profiles
                .filter {
                    $0.model.isChromecastRemote &&
                        $0.hidFingerprint != nil &&
                        $0.effectiveG9N9NInputMode == .bluetoothLogRecovery
                }
                .compactMap(\.bluetoothIdentifier)
        )
        if !isOnboardingComplete,
           onboardingControlSource == .chromecastRemote,
           let selectedProfileID,
           let selected = profiles.first(where: {
               $0.id == selectedProfileID &&
                   $0.model.isChromecastRemote &&
                   $0.hidFingerprint != nil
           }),
           let bluetoothID = selected.bluetoothIdentifier {
            targets.insert(bluetoothID)
        }
        return targets
    }

    static func resolveBTLEServerLogDispatchTarget(
        peripheral: UUID,
        profiles: [RemoteDeviceProfile],
        boundMonitorFingerprints: Set<String>,
        isOnboardingComplete: Bool,
        onboardingControlSource: OnboardingControlSource,
        selectedProfileID: UUID?
    ) -> BTLEServerLogDispatchTarget {
        guard let profile = profiles.first(where: {
            $0.model.isChromecastRemote && $0.bluetoothIdentifier == peripheral
        }) else {
            return .drop(reason: "no_matching_profile")
        }
        let eligible = profile.effectiveG9N9NInputMode == .bluetoothLogRecovery ||
            (!isOnboardingComplete &&
                onboardingControlSource == .chromecastRemote &&
                profile.id == selectedProfileID)
        guard eligible else {
            return .drop(reason: "native_full_mode")
        }
        guard let fingerprint = profile.hidFingerprint else {
            return .drop(reason: "unbound_hid_profile")
        }
        guard boundMonitorFingerprints.contains(fingerprint) else {
            return .drop(reason: "bound_monitor_unavailable")
        }
        return .boundMonitor(fingerprint: fingerprint, profileID: profile.id)
    }

    func stopBTLEServerLogSource(clearingRedactedObservation: Bool) {
        btleServerReportLogGeneration &+= 1
        stopBluetoothLoggingProfileMonitor()
        if btleServerReportLogSource != nil {
            btleServerReportLogSource?.stop()
            btleServerReportLogSource = nil
            AppLogger.shared.write("HID BTLE_LOG source=stopped")
        }
        hidMonitors.values.forEach { $0.cancelBTLEServerLogInteractions() }
        if clearingRedactedObservation {
            btleServerLogRedactedObserved = false
        }
    }

    func isBTLEServerLogSourceActive(for sourceGeneration: UInt64?) -> Bool {
        guard started,
              settings.g9n9nBluetoothLogRecoveryEnabled,
              !audio.suspensionState.suspendsHIDMonitoring,
              btleServerReportLogSource != nil
        else { return false }
        if let sourceGeneration {
            return sourceGeneration == btleServerReportLogGeneration
        }
        return true
    }

    func synchronizeBTLEServerLogSource() {
        let permissions = permissionSnapshotProvider()
        let chromecastPeripherals = Self.btleLogRecoveryTargetPeripherals(
            profiles: settings.remoteDeviceProfiles,
            isOnboardingComplete: settings.isOnboardingComplete,
            onboardingControlSource: settings.onboardingControlSource,
            selectedProfileID: settings.selectedRemoteProfileID
        )
        let shouldRun = started &&
            settings.g9n9nBluetoothLogRecoveryEnabled &&
            !audio.suspensionState.suspendsHIDMonitoring &&
            permissions.inputMonitoringGranted &&
            permissions.accessibilityGranted &&
            bluetoothLoggingProfileStatus == .installed &&
            !btleServerLogRedactedObserved &&
            !chromecastPeripherals.isEmpty
        guard shouldRun else {
            let shouldClearRedacted = !started || !settings.g9n9nBluetoothLogRecoveryEnabled
            stopBTLEServerLogSource(clearingRedactedObservation: shouldClearRedacted)
            return
        }
        if let existing = btleServerReportLogSource {
            existing.updatePeripherals(chromecastPeripherals)
            startBluetoothLoggingProfileMonitorIfNeeded()
            return
        }
        btleServerReportLogGeneration &+= 1
        let generation = btleServerReportLogGeneration
        let source = BTLEServerReportLogSource(
            peripherals: chromecastPeripherals,
            diagnosticLogger: { message in
                DispatchQueue.main.async {
                    AppLogger.shared.write(message)
                }
            },
            onReport: { [weak self] attributed in
                MainActor.assumeIsolated {
                    self?.handleAttributedBTLEServerReport(attributed, sourceGeneration: generation)
                }
            },
            onRedactedReport: { [weak self] observation in
                MainActor.assumeIsolated {
                    self?.handleRedactedBTLEServerReport(observation, sourceGeneration: generation)
                }
            }
        )
        btleServerReportLogSource = source
        source.start()
        startBluetoothLoggingProfileMonitorIfNeeded()
    }

    func handleAttributedBTLEServerReport(
        _ attributed: BTLEServerReportLog.AttributedReport,
        sourceGeneration: UInt64? = nil
    ) {
        guard isBTLEServerLogSourceActive(for: sourceGeneration) else { return }
        let dispatchTarget = Self.resolveBTLEServerLogDispatchTarget(
            peripheral: attributed.peripheral,
            profiles: settings.remoteDeviceProfiles,
            boundMonitorFingerprints: Set(hidMonitors.keys),
            isOnboardingComplete: settings.isOnboardingComplete,
            onboardingControlSource: settings.onboardingControlSource,
            selectedProfileID: settings.selectedRemoteProfileID
        )
        switch dispatchTarget {
        case let .boundMonitor(fingerprint, _):
            guard let targetMonitor = hidMonitors[fingerprint] else { return }
            btleServerLogRedactedObserved = false
            if bluetoothLoggingProfileStatus != .installed {
                bluetoothLoggingProfileStatus = .installed
            }
            targetMonitor.handleBTLEServerLogReport(reportID: attributed.reportID, data: attributed.data)
        case let .drop(reason):
            if reason == "unbound_hid_profile", let bridge = connections.bridges[attributed.peripheral] {
                learnSelectedRemoteHIDIdentity(bridge)
            }
            AppLogger.shared.write("HID BTLE_LOG report_unrouted reason=\(reason) id=\(attributed.reportID)")
        }
    }

    func handleRedactedBTLEServerReport(
        _ observation: BTLEServerReportLog.RedactedObservation,
        sourceGeneration: UInt64? = nil,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        guard isBTLEServerLogSourceActive(for: sourceGeneration) else { return }
        guard shouldPauseOnRedactedBTLEServerReport(observation, now: now) else {
            return
        }
        btleServerLogRedactedObserved = true
        stopBTLEServerLogSource(clearingRedactedObservation: false)
        if bluetoothLoggingProfileStatus != .notInstalled {
            refreshBluetoothLoggingProfileStatus(coalescingIfInFlight: true)
        }
        if now - lastBTLEServerLogRedactedAt >= 10 {
            lastBTLEServerLogRedactedAt = now
            let attribution = observation.peripheral == nil ? "unattributed" : "peripheral"
            AppLogger.shared.write(
                "HID BTLE_LOG redacted_report_observed id=\(observation.reportID) attribution=\(attribution) action=paused"
            )
        }
    }

    private func shouldPauseOnRedactedBTLEServerReport(
        _ observation: BTLEServerReportLog.RedactedObservation,
        now: TimeInterval
    ) -> Bool {
        if observation.peripheral != nil {
            return true
        }
        let shouldRefresh = lastUnattributedRedactionProfileRefreshAt.map {
            now - $0 >= BTLEServerLogRedactionPolicy.unattributedRefreshInterval
        } ?? true
        if shouldRefresh {
            lastUnattributedRedactionProfileRefreshAt = now
            refreshBluetoothLoggingProfileStatus(coalescingIfInFlight: true)
        }
        // Unrelated BLE HID traffic can emit unattributed `<private>` lines even after the user
        // installs the Bluetooth profile; ignore them while `.installed` remains confirmed.
        return bluetoothLoggingProfileStatus != .installed
    }

    /// Releases HID monitors, event taps, input-source observers, and pending recovery work
    /// while the system is sleeping or the console session is inactive.
    func suspendHIDMonitoring(reason: String) {
        cancelHIDMappingRecovery(reason: reason)
        stopHIDMonitors()
        preferredInputSourceMonitor.stop(preservingExplicitVoiceSession: false)
        hidFilterFailureState = .none
        hidMonitoringInterrupted = true
        refreshRuntimePermissionDiagnosis(trigger: "hid_suspended:\(reason)")
    }

    func startHIDDiscoveryIfNeeded() {
        guard discoveryHIDMonitor == nil else { return }
        guard !audio.suspensionState.suspendsHIDMonitoring else {
            hidMonitoringInterrupted = true
            return
        }
        let monitor = makeHIDMonitor(
            profileID: nil,
            targetFingerprint: nil,
            excludedFingerprints: { [weak self] in
                guard let self else { return [] }
                return Set(self.hidMonitors.keys).union(self.settings.excludedForgottenHIDFingerprints())
            }
        )
        discoveryHIDMonitor = monitor
        monitor.start(
            powerKeySuppressed: hidPowerKeySuppressed,
            allowedLocationIDs: hidAllowedLocationIDs
        )
    }

    private func scheduleRemoteWakeRecovery(profileID: UUID, reason: String) {
        // Reconnection can publish readiness and rebuild HID monitors. Leave the input callback first.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.started,
                  let identifier = self.settings.remoteDeviceProfiles.first(where: { $0.id == profileID })?.bluetoothIdentifier
            else { return }
            self.connections.bridges[identifier]?.recoverAfterRemoteActivity(reason: reason)
        }
    }

    private func scheduleHIDServiceMappingRefreshIfNeeded() {
        guard started, !isTerminating else { return }
        guard !pendingHIDServiceMappingRefresh else { return }
        pendingHIDServiceMappingRefresh = true
        guard canRefreshHIDMappingsNow else { return }
        let generation = hidServiceMappingRefreshGeneration
        // Defer outside IOHIDManager callbacks before probing/reapplying IOHIDEventSystem mappings.
        _ = scheduleHIDServiceMappingRefresh(0) { [weak self] in
            guard let self,
                  self.started,
                  !self.isTerminating,
                  self.hidServiceMappingRefreshGeneration == generation
            else { return }
            self.flushPendingHIDServiceMappingRefreshIfNeeded()
        }
    }

    func flushPendingHIDServiceMappingRefreshIfNeeded(applyMappings: (() -> Void)? = nil) {
        guard pendingHIDServiceMappingRefresh, canRefreshHIDMappingsNow else { return }
        pendingHIDServiceMappingRefresh = false
        let requiresReapply = voiceFunctionMapper.needsReapply(
            suppressPowerKey: true,
            neutralizeVoiceKey: shouldNeutralizeNativeVoiceKey
        )
        if requiresReapply {
            if let applyMappings {
                applyMappings()
            } else {
                applyHIDSettings()
            }
        } else if applyMappings == nil, !voiceFunctionMapper.hasMatchingServices {
            scheduleHIDMappingRecoveryIfNeeded()
        }
    }

    private func resolveProfileIDForMonitor(
        _ monitor: HIDRemoteMonitor,
        profileID: UUID?,
        fingerprint: String,
        registerIfMissing: Bool
    ) -> UUID? {
        guard settings.allowsSetupCandidate(
            hidFingerprint: fingerprint,
            model: monitor.reportedModel
        ) else { return nil }
        let existingProfileID = profileID ?? settings.profileID(forHIDFingerprint: fingerprint)
        guard let resolvedProfileID = existingProfileID
            ?? (registerIfMissing
                ? settings.registerHIDRemote(fingerprint: fingerprint, model: monitor.reportedModel)
                : nil)
        else { return nil }
        if existingProfileID == nil {
            appliedHIDMonitoringConfiguration = nil
            monitor.assignProfileID(resolvedProfileID)
            hidMonitors[fingerprint] = monitor
            if discoveryHIDMonitor === monitor {
                discoveryHIDMonitor = nil
                startHIDDiscoveryIfNeeded()
            }
        }
        return resolvedProfileID
    }

    func makeHIDMonitor(
        profileID: UUID?,
        targetFingerprint: String?,
        excludedFingerprints: @escaping () -> Set<String> = { [] },
        runtimePermissions: (() -> Bool)? = nil
    ) -> HIDRemoteMonitor {
        let monitor = HIDRemoteMonitor(
            settings: settings,
            allowsG9N9N: true,
            allowsT1Remote: true,
            profileID: profileID,
            targetFingerprint: targetFingerprint,
            excludedFingerprints: excludedFingerprints,
            eventSuppressor: hidEventSuppressor,
            ownsEventSuppressor: false,
            permissionSnapshot: permissionSnapshotProvider,
            runtimePermissions: runtimePermissions ?? {
                HIDRemoteMonitor.isInputMonitoringGranted && KeyboardInjector.isAccessibilityTrusted
            },
            actionPerformer: { [weak self] _, _, configured in
                self?.performExternalConfiguredAction(configured) ?? false
            },
            appSwitcherCoordinator: appSwitcherCoordinator
        )
        monitor.onboardingWindowIsActive = { [weak self] in
            self?.onboardingWindowIsActive() ?? true
        }
        monitor.onCandidateAvailable = { [weak self] in
            guard let self else { return }
            self.scheduleHIDServiceMappingRefreshIfNeeded()
            for bridge in self.connections.bridges.values {
                self.learnSelectedRemoteHIDIdentity(bridge)
                bridge.recoverSystemConnectedRemote(reason: "hid_candidate")
            }
        }
        monitor.onDeviceConnected = { [weak self] profileID, fingerprint in
            guard let self else { return }
            self.hidVerificationRecoveryAttempt = 0
            self.scheduleHIDServiceMappingRefreshIfNeeded()
            guard let resolvedProfileID = profileID
                ?? self.settings.profileID(forHIDFingerprint: fingerprint) else { return }
            self.scheduleRemoteWakeRecovery(profileID: resolvedProfileID, reason: "hid_connected")
        }
        monitor.claimsRuntimeButton = { [weak self] profileID, button in
            self?.commonPhrases.claims(button, source: Self.commonPhraseHIDSource(profileID)) == true
        }
        monitor.onRuntimeButton = { [weak self] profileID, button, phase in
            self?.commonPhrases.handle(button, phase: phase, source: Self.commonPhraseHIDSource(profileID)) == true
        }
        monitor.onMonitoringInterrupted = { [weak self] in self?.hidMonitoringInterrupted = true }
        monitor.onInputReset = { [weak self] profileID in
            self?.commonPhrases.reset(source: Self.commonPhraseHIDSource(profileID))
        }
        monitor.onStatus = { [weak self, weak monitor] value in
            guard let self, let monitor else { return }
            if self.settings.selectedRemoteProfile?.model.isAppleSiriRemote == true {
                return
            }
            if monitor.profileID == self.settings.selectedRemoteProfileID || monitor.profileID == nil {
                self.hidStatus = value
                self.refreshVoiceKeyCompatibilityWarning()
                self.refreshRuntimePermissionDiagnosis(trigger: "hid_status")
            }
        }
        monitor.onActiveButtons = { [weak self] profileID, buttons in
            guard let self, profileID == self.settings.selectedRemoteProfileID else { return }
            self.activeRemoteButtons = buttons
        }
        monitor.onObservedButtonReport = { [weak self, weak monitor] profileID, buttons in
            guard let self, !buttons.isEmpty else { return }
            let origin = monitor?.currentReportOrigin ?? .iohid
            if let profileID, buttons.count == 1 {
                if origin == .btleServerLog {
                    if self.settings.recordG9N9NBluetoothLogRecoveryIntegration(for: profileID) {
                        self.synchronizeBTLEServerLogSource()
                        AppLogger.shared.write(
                            "REMOTE HID g9n9n_mode=bluetooth_log_recovery reason=btle_log_observed profile=\(profileID.uuidString)"
                        )
                    }
                } else if origin == .iohid,
                          self.settings.recordG9N9NNativeIOHIDIntegration(for: profileID) {
                    self.synchronizeBTLEServerLogSource()
                    AppLogger.shared.write(
                        "REMOTE HID g9n9n_mode=full reason=native_iohid_observed profile=\(profileID.uuidString)"
                    )
                }
            }
            self.lastObservedRemoteButtonReport = RemoteButtonObservation(
                profileID: profileID,
                buttons: buttons,
                origin: origin
            )
        }
        monitor.onNativeGoogleIOHIDVerified = { [weak self] profileID in
            guard let self else { return }
            if let profileID, self.settings.recordG9N9NNativeIOHIDIntegration(for: profileID) {
                AppLogger.shared.write(
                    "REMOTE HID g9n9n_mode=full reason=native_iohid_verified profile=\(profileID.uuidString)"
                )
            }
            self.synchronizeBTLEServerLogSource()
        }
        monitor.onButtonPressed = { [weak self, weak monitor] profileID, fingerprint, button in
            guard let self, let monitor else {
                return profileID.map { ($0, true) }
            }
            guard let resolvedProfileID = self.resolveProfileIDForMonitor(
                monitor,
                profileID: profileID,
                fingerprint: fingerprint,
                registerIfMissing: true
            ) else { return nil }
            self.scheduleRemoteWakeRecovery(profileID: resolvedProfileID, reason: "hid_button")
            self.selectRemoteProfile(resolvedProfileID)
            self.lastRemoteButtonPress = button
            let reportingModel = self.settings.remoteDeviceProfiles
                .first(where: { $0.id == resolvedProfileID })?.model ?? monitor.reportedModel
            let suppressConfiguredAction = OnboardingControlValidationPolicy
                .suppressConfiguredActions(
                    at: self.settings.onboardingStep,
                    source: self.settings.onboardingControlSource,
                    reportingModel: reportingModel,
                    onboardingWindowIsActive: self.onboardingWindowIsActive()
                )
            if suppressConfiguredAction {
                AppLogger.shared.write(
                    "ONBOARDING CONTROLS button=\(button.rawValue) action=suppressed"
                )
            }
            return (
                resolvedProfileID,
                !suppressConfiguredAction
            )
        }
        monitor.onPassthroughButtonObserved = { [weak self, weak monitor] profileID, fingerprint, button in
            guard let self, let monitor else { return profileID }
            let inT1ControlOnboarding = !self.settings.isOnboardingComplete &&
                (self.settings.onboardingStep == .remote || self.settings.onboardingStep == .controls) &&
                self.settings.onboardingControlSource == .t1Remote
            guard let resolvedProfileID = self.resolveProfileIDForMonitor(
                monitor,
                profileID: profileID,
                fingerprint: fingerprint,
                registerIfMissing: inT1ControlOnboarding
            ) else { return nil }
            if inT1ControlOnboarding {
                self.scheduleRemoteWakeRecovery(profileID: resolvedProfileID, reason: "hid_button")
                self.selectRemoteProfile(resolvedProfileID)
                self.lastRemoteButtonPress = button
            } else if resolvedProfileID == self.settings.selectedRemoteProfileID {
                self.scheduleRemoteWakeRecovery(profileID: resolvedProfileID, reason: "hid_button")
                self.lastRemoteButtonPress = button
            }
            return resolvedProfileID
        }
        monitor.onInternalAction = { [weak self] profileID, action in
            guard let self else { return }
            if let profileID { self.selectRemoteProfile(profileID) }
            self.performInternalAction(action, source: Self.commonPhraseHIDSource(profileID))
        }
        monitor.onT1VoiceHoldChanged = { _, isPressed in
            AppLogger.shared.write("HID T1 voice_hold changed pressed=\(isPressed) mode=toggle")
        }
        return monitor
    }
}
