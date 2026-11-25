import AppKit
import Combine
import CoreBluetooth
import SwiftUI

extension OnboardingView {
    func prepareForStep(_ step: OnboardingStep) {
        buttonHelpExpanded = false
        diagnosticCopySucceeded = nil
        refreshPermissionStates()
        if allowsHardwareMonitoring {
            model.applyHIDSettings(allowVoiceKeyModeFallback: false)
        }
        switch step {
        case .voiceTool:
            refreshVoiceToolAvailability()
            refreshSelectedInputMethodStatus()
            refreshSystemFunctionKeyUsage()
        case .remoteAvailability:
            routeConnectedPhysicalRemoteIfNeeded()
        case .remote:
            observedRemoteButtons.removeAll()
            chromecastSingleKeyObserved = false
            chromecastTwoKeyDetectedWithoutSingleKey = false
            pendingChromecastComboButtons.removeAll()
            compatibleChordConfirmed = false
            remoteInputDiagnostic = remoteInputDiagnosticOverride ?? FirstUseRemoteInputDiagnostic()
            requestedRemoteConnectionRecovery = false
            secureInputWaitStartedAtUptime = nil
            prepareSelectedControlConnection()
        case .voiceTrigger:
            break
        case .permissions:
            model.refreshAudioDevices()
        case .voiceTest:
            nonTextVoiceToolConfirmed = false
            refreshSelectedVoiceToolRuntimeState()
            ensureSelectedVoiceToolRunning()
            resetVoiceTestForRetry()
        case .controls:
            testedControlButtons.removeAll()
            compatibleChordConfirmed = false
            secureInputWaitStartedAtUptime = nil
        case .complete:
            if secureInputActive != nil { secureInputActive = nil }
            if secureInputWaitStartedAtUptime != nil { secureInputWaitStartedAtUptime = nil }
            if lastLoggedSecureInputState != nil { lastLoggedSecureInputState = nil }
        }
        settings.recordFirstUseEvent(.entered, step: step)
        lastRecordedFailure = nil
        DispatchQueue.main.async {
            recordFailureTransition(failureReason)
        }
    }

    func recordFailureTransition(_ failure: FirstUseFailureReason?) {
        guard settings.onboardingStep != .voiceTest else { return }
        if let failure {
            guard failure != lastRecordedFailure else { return }
            if let previousFailure = lastRecordedFailure {
                settings.recordFirstUseEvent(
                    .recovered,
                    step: settings.onboardingStep,
                    failureReason: previousFailure
                )
            }
            settings.recordFirstUseEvent(.blocked, step: settings.onboardingStep, failureReason: failure)
        } else if let previousFailure = lastRecordedFailure {
            settings.recordFirstUseEvent(
                .recovered,
                step: settings.onboardingStep,
                failureReason: previousFailure
            )
            settings.recordFirstUseEvent(.passed, step: settings.onboardingStep)
        }
        lastRecordedFailure = failure
    }

    func performRecovery(for failure: FirstUseFailureReason) {
        settings.recordFirstUseEvent(
            .retry,
            step: settings.onboardingStep,
            failureReason: failure
        )
        switch failure {
        case .bluetoothPermissionDenied:
            requestBluetoothPermission()
        case .inputMonitoringPermissionDenied:
            requestInputMonitoringPermission()
        case .accessibilityPermissionDenied:
            requestAccessibilityPermission()
        case .permissionDesynced, .postEventAccessRestricted:
            openPrivacySecuritySettings(
                urlString: model.runtimePermissionIssue?.preferredPrivacySettingsURLString
                    ?? "x-apple.systempreferences:com.apple.preference.security?Privacy"
            )
        case .remoteNotFound:
            restartSelectedControlConnection()
        case .remoteButtonNotReady, .controlsNotConfirmed:
            if settings.onboardingControlMethod == .physicalRemote {
                model.applyHIDSettings()
            } else {
                prepareSelectedControlConnection()
            }
        case .audioNoOutputDevice, .audioSelectedDeviceMissing:
            model.refreshAudioDevices()
        case .audioOutputNotReady:
            model.applyAudioSettings(reason: "onboarding_recovery")
        case .voiceSessionNotStarted,
             .voiceSessionNotEnded,
             .voiceManualInput,
             .voiceNoTranscript,
             .voiceInputTargetNotReady,
             .voiceInputTargetFocusLost,
             .voiceExternalToolNoCommit:
            resetVoiceTestForRetry()
        case .voiceNoSamples, .voiceAudioDeliveryFailed:
            model.applyAudioSettings(reason: "onboarding_voice_retry")
            resetVoiceTestForRetry()
        }
    }

    private func restartSelectedControlConnection() {
        switch settings.onboardingControlSource {
        case .siriRemote:
            prepareSelectedControlConnection()
        case .xiaomiRemote, .t1Remote, .chromecastRemote, .unselected:
            prepareSelectedControlConnection()
        }
    }

    private func resetVoiceTestForRetry() {
        cancelVoiceTestTasks()
        voiceTranscriptDeadlineToken = UUID()
        voiceAttemptStartedAtUptime = nil
        voiceTranscriptWaitStartedAtUptime = nil
        activeFocusLossStartedAtUptime = nil
        voiceSessionStarted = false
        voiceSamplesReceived = false
        voiceSessionEnded = false
        lastVoiceTranscriptCandidate = ""
        manualTranscriptInputObserved = false
        transcript = ""
        voiceAttempt = FirstUseVoiceAttemptDiagnostic(
            attemptID: voiceAttempt.attemptID,
            phase: .idle,
            triggerPath: "none",
            triggerReady: false,
            editorMounted: transcriptEditorMounted,
            windowKeyAtStart: false,
            firstResponderAtStart: false,
            firstResponderAtEnd: false,
            focusLost: false,
            firstSampleLatencyMilliseconds: nil,
            sessionDurationMilliseconds: nil,
            transcriptWaitMilliseconds: nil,
            result: .none
        )
        lastRecordedFailure = nil
        requestTranscriptFocus()
    }
}
