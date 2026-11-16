import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Onboarding completion summary")
struct OnboardingCompletionSummaryTests {
    @Test func summariesReflectTheCurrentValuesAndOnlyTheCurrentFlow() {
        for purpose in [OnboardingPurpose.initialSetup, .addDevice, .integration] {
            let summary = OnboardingCompletionSummary(purpose: purpose, remoteName: "Study T1",
                buttonsVerified: true, microphoneReady: false, voiceKeyMode: .rightOption,
                tapModeEnabled: false, voiceTool: .weixin, binding: nil)
            #expect(summary.remoteName == (purpose == .integration ? nil : "Study T1"))
            #expect(summary.buttonsVerified == (purpose == .integration ? nil : true))
            #expect(summary.microphoneReady == (purpose == .initialSetup ? false : nil))
            #expect(summary.voiceKeyMode == (purpose == .addDevice ? nil : .rightOption))
            #expect(summary.voiceVerified == (purpose == .addDevice ? nil : false))
        }
    }

    @Test func verificationMustMatchTheDisplayedToolShortcutAndMode() {
        let binding = VoiceToolUserBinding(tool: .weixin, shortcut: .rightOption, gestureMode: .hold,
            source: .manuallyConfirmed, validationState: .verified, verifiedToolVersion: nil, verifiedAt: Date())
        for tool in [OnboardingVoiceTool.weixin, .doubao] {
            for mode in [VoiceKeyMode.rightOption, .function] {
                for tap in [false, true] {
                    let summary = OnboardingCompletionSummary(purpose: .integration, remoteName: "Remote",
                        buttonsVerified: true, microphoneReady: true, voiceKeyMode: mode,
                        tapModeEnabled: tap, voiceTool: tool, binding: binding)
                    #expect(summary.voiceVerified == (tool == .weixin && mode == .rightOption && !tap))
                }
            }
        }
    }
}
