import AppKit
import Combine
import CoreBluetooth
import SwiftUI

extension OnboardingView {
    var microphoneDriverInstalled: Bool {
        model.audioDevices.contains {
            OnboardingAudioSelectionPolicy.isSupportedDevice(uid: $0.uid, name: $0.name)
        }
    }

    var capabilities: OnboardingCapabilities {
        OnboardingCapabilities(
            systemFunctionKeyAvailable: systemFunctionKeyAvailable,
            bluetoothGranted: bluetoothAuthorization == .allowedAlways,
            inputMonitoringGranted: inputMonitoringGranted,
            accessibilityGranted: accessibilityGranted,
            remoteConnected: selectedControlConnected,
            remoteButtonObserved: !observedRemoteButtons.isEmpty,
            microphoneDriverInstalled: microphoneDriverInstalled,
            audioReady: model.isAudioOutputVerified,
            audioOutputSelected: audioOutputSelected,
            voiceSessionStarted: voiceSessionStarted,
            voiceSamplesReceived: voiceSamplesReceived,
            voiceSessionEnded: voiceSessionEnded,
            transcriptionAppeared: transcriptionAppeared,
            manualTranscriptInputObserved: manualTranscriptInputObserved,
            nonTextResponseConfirmed: nonTextResponseConfirmed,
            testedRemoteButtonCount: testedControlButtons.count
        )
    }

    var canContinue: Bool {
        let policyAllowsContinue = OnboardingFlowPolicy.canContinue(
            from: settings.onboardingStep,
            voiceTool: settings.onboardingVoiceTool,
            remoteAvailability: settings.onboardingRemoteAvailability,
            controlMethod: settings.onboardingControlMethod,
            voiceKeyMode: settings.selectedVoiceTrigger.voiceKeyMode,
            voiceToolSetupReady: voiceToolBlockingHintKey == nil && proposedPairingPlan != nil,
            selectedDevice: settings.onboardingDevice,
            capabilities: capabilities
        )
        if settings.onboardingStep == .voiceTest {
            return policyAllowsContinue && settings.isTestingVoiceTrigger &&
                voiceAttempt.result == .passed &&
                (verifiedTranscriptionAppeared || nonTextResponseConfirmed) &&
                selectedVoiceToolRuntimeReady
        }
        return policyAllowsContinue &&
            (settings.onboardingStep != .voiceTool ||
                (voiceToolSelectionIsValid &&
                    proposedPairingPlan != nil))
    }

    var visibleVoiceTools: [OnboardingVoiceTool] {
        OnboardingVoiceToolVisibilityPolicy.tools
    }

    var allRecognizedVoiceToolsUnavailable: Bool {
        [OnboardingVoiceTool.weixin, .doubao, .chatterfly, .voiceBuddy, .bageshuo, .typeless].allSatisfy {
            voiceToolAvailability[$0] == .notInstalled
        }
    }

    private var voiceToolSelectionIsValid: Bool {
        switch settings.onboardingVoiceTool {
        case .unselected:
            return false
        case .macosDictation, .other:
            return true
        case .weixin, .doubao, .chatterfly, .voiceBuddy, .bageshuo, .typeless:
            return voiceToolAvailability[settings.onboardingVoiceTool] == .available
        }
    }

    var voiceToolRequiresHoldConfirmation: Bool {
        VoiceToolAdapterProfile.profile(for: settings.onboardingVoiceTool).supportedModes == [.hold]
            && settings.selectedVoiceTrigger.voiceFnTapModeEnabled
    }

    var voiceToolRequiresTapConfirmation: Bool {
        VoiceToolAdapterProfile.profile(for: settings.onboardingVoiceTool).supportedModes == [.toggle]
            && !settings.selectedVoiceTrigger.voiceFnTapModeEnabled
    }

    var voiceToolBlockingHintKey: String? {
        if settings.onboardingVoiceTool == .unselected { return "onboarding.voice_tool.choose_required" }
        if !voiceToolSelectionIsValid { return "onboarding.voice_tool.install_required" }
        if settings.onboardingVoiceTool == .macosDictation && settings.selectedVoiceTrigger.voiceKeyMode != .function {
            return "onboarding.voice_tool.trigger_incompatible"
        }
        if voiceToolRequiresHoldConfirmation { return "onboarding.voice_tool.hold_required" }
        if voiceToolRequiresTapConfirmation { return "onboarding.voice_tool.tap_required" }
        if !hasViewedInputMethodGuideSteps(viewedInputMethodGuideSteps) {
            return "onboarding.voice_tool.guide.continue_hint"
        }
        return nil
    }

    func hasViewedInputMethodGuideSteps(_ viewed: Set<Int>) -> Bool {
        let steps = inputMethodGuideSteps(for: settings.onboardingVoiceTool)
        return !steps.isEmpty && steps.allSatisfy { viewed.contains($0.id) }
    }

    var effectivePreferredGesture: VoiceGestureMode {
        settings.onboardingPreferredGesture ?? proposedPairingPlan?.binding.gestureMode ?? .hold
    }

    var proposedPairingPlan: OnboardingVoicePairingPlan? {
        guard !voiceToolRequiresTapConfirmation, !voiceToolRequiresHoldConfirmation else { return nil }
        let selectedBinding: VoiceToolUserBinding?
        if let staged = settings.stagedVoiceToolBinding,
           staged.tool == settings.onboardingVoiceTool {
            selectedBinding = staged
        } else if let verified = settings.verifiedVoiceToolBinding,
                  verified.tool == settings.onboardingVoiceTool,
                  verified.validationState == .verified {
            // Keep the tool binding, but a newly selected trigger or gesture must be tested again.
            selectedBinding = verified
        } else {
            selectedBinding = nil
        }
        return OnboardingVoicePairingPlan.resolve(
            tool: settings.onboardingVoiceTool,
            controlSource: settings.onboardingControlSource,
            preferredGesture: settings.selectedVoiceTrigger.voiceFnTapModeEnabled ? .toggle : .hold,
            userBinding: selectedBinding,
            selectedShortcut: settings.selectedVoiceTrigger.voiceKeyMode
        )
    }

    var diagnosticContext: FirstUseDiagnosticContext {
        FirstUseDiagnosticContext(
            step: settings.onboardingStep,
            remoteAvailability: settings.onboardingRemoteAvailability,
            controlMethod: settings.onboardingControlMethod,
            capabilities: capabilities,
            hasSelectedAudioUID: !settings.selectedAudioDeviceUID.isEmpty,
            voiceAttempt: settings.onboardingStep == .voiceTest ? voiceAttempt : nil,
            remoteInput: remoteInputDiagnostic,
            runtimePermissionIssue: model.runtimePermissionIssue
        )
    }

    var failureReason: FirstUseFailureReason? {
        return diagnosticContext.failureReason
    }

    var supportedAudioDevices: [AudioDeviceInfo] {
        model.audioDevices.filter { device in
            OnboardingAudioSelectionPolicy.isSupportedDevice(uid: device.uid, name: device.name)
        }
    }

    var selectedAudioDevice: AudioDeviceInfo? {
        supportedAudioDevices.first { $0.uid == settings.selectedAudioDeviceUID }
    }

    private var selectedAudioDeviceDiagnosticKind: VirtualAudioDeviceDiagnosticKind {
        .classify(selectedAudioDevice)
    }

    var audioOutputSelected: Bool {
        OnboardingAudioSelectionPolicy.isSupportedDeviceSelected(
            selectedUID: settings.selectedAudioDeviceUID,
            availableSupportedUIDs: supportedAudioDevices.lazy.map(\.uid)
        )
    }

    var onboardingAudioReady: Bool {
        audioOutputSelected && model.isAudioOutputVerified
    }

    var transcriptionAppeared: Bool {
        !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func captureVoiceTranscriptCandidate(_ text: String) {
        guard settings.onboardingStep == .voiceTest,
              voiceAttempt.phase == .recording || voiceAttempt.phase == .awaitingTranscript,
              !manualTranscriptInputObserved,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        lastVoiceTranscriptCandidate = text
    }

    var verifiedTranscriptionAppeared: Bool {
        transcriptionAppeared && !manualTranscriptInputObserved
    }

    var nonTextResponseConfirmed: Bool {
        settings.onboardingVoiceTool.supportsNonTextConfirmation &&
            nonTextVoiceToolConfirmed &&
            !manualTranscriptInputObserved
    }

    var selectedControlConnected: Bool {
        if settings.onboardingControlMethod == .physicalRemote {
            return OnboardingFlowPolicy.isPhysicalRemoteRecognized(
                at: settings.onboardingStep,
                voiceConnectionReady: model.isOnboardingControlSourceConnected(
                    settings.onboardingControlSource
                ),
                validatedHIDButtonObserved: !observedRemoteButtons.isEmpty
            )
        }
        return model.isOnboardingControlSourceConnected(settings.onboardingControlSource)
    }

    var selectedControlConnectedKey: String {
        switch settings.onboardingControlMethod {
        case .physicalRemote:
            return "onboarding.side.remote_connected"
        case .unselected:
            return "onboarding.side.control_selected"
        }
    }

    var primaryActionKey: String {
        switch settings.onboardingStep {
        case .complete: return "onboarding.action.open_app"
        default: return "onboarding.action.continue"
        }
    }
}
