import Testing
@testable import RemoteBuddy

@Suite("Onboarding permission regression")
struct OnboardingPermissionRegressionTests {
    @Test func buttonReportsCannotPassSetupWithoutTheVoiceConnection() {
        var capabilities = OnboardingCapabilities(bluetoothGranted: true,
            inputMonitoringGranted: true, accessibilityGranted: true,
            remoteConnected: false, remoteButtonObserved: true,
            audioReady: true, audioOutputSelected: true, testedRemoteButtonCount: 3)
        for step in [OnboardingStep.controls] {
            let context = FirstUseDiagnosticContext(step: step, capabilities: capabilities, hasSelectedAudioUID: true)
            #expect(context.failureReason == .remoteNotFound)
            #expect(!OnboardingFlowPolicy.canContinue(from: step, voiceTool: .weixin, capabilities: capabilities))
            #expect(OnboardingFlowPolicy.recoveryStep(from: step, voiceTool: .weixin,
                capabilities: capabilities, hasSelectedAudioUID: true) == .remote)
        }
        capabilities.remoteConnected = true
        #expect(OnboardingFlowPolicy.canContinue(from: .controls, voiceTool: .weixin, capabilities: capabilities))
        #expect(OnboardingFlowPolicy.canContinue(from: .complete, voiceTool: .weixin, capabilities: capabilities))
    }

    @Test func completionIsASummaryWithoutNewRuntimeChecks() {
        let capabilities = OnboardingCapabilities()
        let context = FirstUseDiagnosticContext(step: .complete, capabilities: capabilities, hasSelectedAudioUID: false)
        #expect(context.failureReason == nil)
        #expect(OnboardingFlowPolicy.canContinue(from: .complete, voiceTool: .other, capabilities: capabilities))
        #expect(OnboardingFlowPolicy.recoveryStep(from: .complete, voiceTool: .other,
            capabilities: capabilities, hasSelectedAudioUID: false) == nil)
    }

    @Test(arguments: [OnboardingStep.remote, .controls, .voiceTrigger, .voiceTest])
    func revokedPermissionOverridesLaterStepDiagnostics(step: OnboardingStep) {
        let capabilities = OnboardingCapabilities(bluetoothGranted: true,
            inputMonitoringGranted: true, accessibilityGranted: false,
            voiceSessionStarted: true, voiceSamplesReceived: true,
            voiceSessionEnded: true, transcriptionAppeared: true)
        let context = FirstUseDiagnosticContext(step: step, capabilities: capabilities, hasSelectedAudioUID: true)
        #expect(context.failureReason == .accessibilityPermissionDenied)
        #expect(!OnboardingFlowPolicy.canContinue(from: step, voiceTool: .other, capabilities: capabilities))
        #expect(OnboardingFlowPolicy.recoveryStep(from: step, voiceTool: .other,
            capabilities: capabilities, hasSelectedAudioUID: true) == .permissions)
    }
}
