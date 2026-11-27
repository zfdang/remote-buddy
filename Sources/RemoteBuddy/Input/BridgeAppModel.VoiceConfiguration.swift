import AppKit
import AVFoundation
import Combine
import CoreAudio
import CoreBluetooth
import Foundation

extension BridgeAppModel {
    func makeVoiceFnTapSession(
        schedule: @escaping OperationScheduler = ScheduledOperation.mainQueue
    ) -> VoiceFnTapSessionController {
        var startTarget: ApplicationIntegrationController.VoiceInputTarget?
        return VoiceFnTapSessionController(
            startTapCount: { [weak self] in
                self?.settings.onboardingVoiceTool.functionKeyStartTapCount ?? 1
            },
            schedule: schedule,
            destinationReadiness: { [weak self] completion in
                guard let self else { return .immediate }
                startTarget = self.settings.onboardingVoiceTool.functionKeyStartTapCount > 1
                    ? self.applicationIntegrationController.currentVoiceInputTarget() : nil
                return self.prepareIntegratedVoiceInputDestination(
                    completion: completion, onTarget: { target in
                        if startTarget == nil { startTarget = target }
                    }
                )
            },
            validateStart: { [weak self] in
                guard let self, let target = startTarget else { return true }
                guard self.applicationIntegrationController.isCurrentVoiceInputTarget(target) else {
                    self.recordApplicationIntegrationStatus(.cancelled(.targetChanged))
                    return false
                }
                return true
            },
            setTriggerPressed: { [weak self, trigger = voiceTapTrigger] pressed in
                let submitted = trigger.setPressed(pressed)
                if pressed {
                    self?.completeApplicationIntegrationVoiceTrigger(started: submitted)
                    if submitted { self?.preferredInputSourceMonitor.markVoiceTriggerSubmitted() }
                }
                return submitted
            },
            enqueueAudio: { [weak self] samples in
                self?.enqueueVoiceFnTapAudio(samples)
            },
            drainAudio: { [weak self] operationID, completion in
                guard let self else {
                    completion()
                    return
                }
                self.audio.output.endSessionAfterDraining(
                    source: "voice_fn_tap",
                    operationID: operationID,
                    maximumDelay: self.audio.output.pendingPlaybackDuration + 0.75
                ) { outcome in
                    AppLogger.shared.write(
                        "VOICE FN TAP playback_stop operation_id=\(operationID) " +
                            "phase=completed result=\(outcome.rawValue)"
                    )
                    completion()
                }
            },
            onFailure: { [weak self] failure in
                self?.handleVoiceFnTapFailure(failure)
            },
            enqueuePreRollAudio: { [weak self] in self?.enqueueVoiceFnTapAudio($0, isPreRoll: true) },
            pendingPlaybackDuration: { [weak self] in self?.audio.output.pendingPlaybackDuration ?? 0 },
            logger: { AppLogger.shared.write($0) },
            onIdle: { [weak self, trigger = voiceTapTrigger] in
                trigger.reset()
                self?.preferredInputSourceMonitor.endVoiceSession()
                self?.flushPendingVoiceToolMappingRefresh()
                self?.releaseVirtualAudioOutputIfUnused(reason: "voice_fn_tap_idle")
            }
        )
    }


    /// Tap pre-roll covers one shared four-second focus/input-source/destination budget.
    /// Cancelling the returned wait is silent because the Fn session owns stop.
    func prepareIntegratedVoiceInputDestination(
        completion: @escaping (VoiceInputDestinationWaitResult) -> Void,
        schedule: @escaping OperationScheduler = ScheduledOperation.mainQueue,
        onTarget: @escaping (ApplicationIntegrationController.VoiceInputTarget) -> Void = { _ in }
    ) -> VoiceInputDestinationWait {
        clearApplicationIntegrationStatus()
        let initialIntegrationTarget = applicationIntegrationController.currentVoiceInputTarget()
        if let initialIntegrationTarget {
            if applicationIntegrationController.isEnabledVoiceInputTarget(initialIntegrationTarget) {
                recordApplicationIntegrationStatus(.waiting)
            }
            onTarget(initialIntegrationTarget)
        }
        let report: (VoiceInputDestinationWaitResult) -> Void = { [weak self] result in
            if case let .cancelled(reason) = result {
                self?.preferredInputSourceMonitor.endVoiceSession()
                self?.recordApplicationIntegrationStatus(.cancelled(reason))
            }
            completion(result)
        }
        let sequence = VoiceInputPreparationSequence(schedule: schedule)
        let wait = sequence.start(stages: [
            { [weak self] done in self?.prepareTapInputSource(completion: done) ?? .cancelled(.superseded) },
            { [weak self] done in
                guard let self else { return .cancelled(.superseded) }
                let switchedInputSource = self.preferredInputSourceMonitor.lastExplicitVoiceSessionSwitchedInputSource
                return self.applicationIntegrationController.prepareForVoiceInput(
                    expectedTarget: initialIntegrationTarget,
                    resyncFocusedComposer: switchedInputSource,
                    onTarget: onTarget,
                    completion: done
                )
            },
            { [weak self] done in self?.voiceInputDestinationCoordinator.waitUntilReady(completion: done) ?? .cancelled(.superseded) },
        ], completion: report)
        switch wait {
        case .immediate:
            return .immediate
        case let .cancelled(reason):
            preferredInputSourceMonitor.endVoiceSession()
            recordApplicationIntegrationStatus(.cancelled(reason))
            return .cancelled(reason)
        case let .waiting(operation):
            return .waiting(.mainQueueCancellation { [weak self] in
                operation.cancel()
                self?.preferredInputSourceMonitor.endVoiceSession()
            })
        }
    }

    /// Adapt the source monitor's callback to a cancellable preparation stage.
    /// Cancelling invalidates activation before any delayed completion can submit a key.
    func prepareTapInputSource(
        completion: @escaping (VoiceInputDestinationWaitResult) -> Void
    ) -> VoiceInputDestinationWait {
        var starting = true
        var immediateResult: Bool?
        preferredInputSourceMonitor.beginVoiceSession { ready in
            if starting { immediateResult = ready }
            else { completion(ready ? .ready : .cancelled(.actionFailed)) }
        }
        starting = false
        if let immediateResult {
            if !immediateResult { preferredInputSourceMonitor.endVoiceSession() }
            return immediateResult ? .immediate : .cancelled(.actionFailed)
        }
        return .waiting(.mainQueueCancellation { [weak self] in
            self?.preferredInputSourceMonitor.endVoiceSession()
        })
    }

    // Main-queue lifecycle, like HID settings and the remote voice callbacks.
    func voiceToolDidChange() {
        pendingVoiceToolMappingRefresh = true
        flushPendingVoiceToolMappingRefresh()
    }

    var canRefreshHIDMappingsNow: Bool {
        started && !isTerminating && !audio.suspensionState.suspendsHIDMonitoring &&
            !isStreaming && !voiceSession.isActive && !hasPendingBluetoothVoiceWork &&
            voiceSession.pendingStart.identifier == nil && !voiceKeyLatch.isHeld &&
            !voiceKeyActivationInProgress && !voiceFnTapSession.requiresCleanupBeforeMapping
    }

    func flushPendingVoiceToolMappingRefresh(applyMappings: (() -> Void)? = nil) {
        guard canRefreshHIDMappingsNow else { return }
        if pendingVoiceToolMappingRefresh {
            pendingVoiceToolMappingRefresh = false
            if applyMappings == nil {
                pendingHIDServiceMappingRefresh = false
            }
            if let applyMappings { applyMappings() } else { applyHIDSettings() }
            if applyMappings != nil {
                flushPendingHIDServiceMappingRefreshIfNeeded(applyMappings: applyMappings)
            }
            return
        }
        flushPendingHIDServiceMappingRefreshIfNeeded(applyMappings: applyMappings)
    }
    var requiresOrderedVoiceFn: Bool {
        (settings.effectiveVoiceKeyMode == .function && !settings.effectiveVoiceFnTapModeEnabled &&
            !settings.enabledApplicationIntegrations.isEmpty) || OrderedVoiceActivationPolicy.needsSoftwareFn(
            mode: settings.effectiveVoiceKeyMode,
            fnTapEnabled: settings.effectiveVoiceFnTapModeEnabled,
            preferredInputSourceID: settings.onboardingVoiceTool.preferredInputSourceID
        )
    }
    /// Native Xiaomi services remain present when the selected card is a
    /// G9N9N. Their mapping follows the global trigger, not the selected family.
    var shouldNeutralizeNativeVoiceKey: Bool {
        settings.effectiveVoiceKeyMode != .function || settings.effectiveVoiceFnTapModeEnabled || requiresOrderedVoiceFn
    }

    var isVoiceConfigurationBusy: Bool {
        isStreaming || hasActiveVirtualAudioSource || voiceKeyLatch.isHeld ||
            voiceKeyActivationInProgress || voiceSession.pendingStart.identifier != nil ||
            voiceFnTapSession.requiresCleanupBeforeMapping || voiceKeyReleaseRetry != nil ||
            g9n9nSmartToggle.isActive
    }

    func handleVoiceFnTapFailure(_ failure: VoiceFnTapFailure) {
        releaseVirtualAudioOutputIfUnused(reason: "voice_fn_tap_failed")
        if voiceFnTapSession.releaseRecoveryBlocked {
            voiceShortcutStatus = LocalizedMessage("voice_button.status.cleanup_failed")
            AppLogger.shared.write("VOICE FN TAP cleanup blocked reason=accessibility_unavailable")
            return
        }
        AppLogger.shared.write("VOICE FN TAP failed reason=\(failure.rawValue) fallback=hardware_fn")
        if settings.isTestingVoiceTrigger {
            settings.discardOnboardingVoiceTrial()
        } else {
            settings.voiceFnTapModeEnabled = false
        }
        voiceFnTapSession.setEnabled(false)
        applyHIDSettings()
    }

    func requestNextHIDPermissionIfNeeded() {
        let request = HIDPermissionGate.nextPermissionRequest(
            inputMonitoringGranted: HIDRemoteMonitor.isInputMonitoringGranted,
            accessibilityGranted: KeyboardInjector.isAccessibilityTrusted
        )
        switch request {
        case .none:
            break
        case .inputMonitoring:
            _ = HIDRemoteMonitor.requestInputMonitoringAccess()
        case .accessibility:
            _ = KeyboardInjector.requestAccessibilityAccess()
        }
    }

    func requestInputMonitoringPermission() {
        _ = HIDRemoteMonitor.requestInputMonitoringAccess()
        openPrivacyPane("Privacy_ListenEvent")
    }

    func requestAccessibilityPermission() {
        _ = KeyboardInjector.requestAccessibilityAccess()
        openPrivacyPane("Privacy_Accessibility")
    }
}
