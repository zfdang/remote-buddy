import Foundation

/// Describes the current configuration without presenting untouched steps as tested.
struct OnboardingCompletionSummary {
    let remoteName: String?
    let buttonsVerified: Bool?
    let microphoneReady: Bool?
    let voiceKeyMode: VoiceKeyMode?
    let tapModeEnabled: Bool?
    let voiceTool: OnboardingVoiceTool?
    let voiceVerified: Bool?
    let isPartialSupportG9N9N: Bool

    init(purpose: OnboardingPurpose, remoteName: String, buttonsVerified: Bool,
         microphoneReady: Bool, voiceKeyMode: VoiceKeyMode, tapModeEnabled: Bool,
         voiceTool: OnboardingVoiceTool, binding: VoiceToolUserBinding?,
         isPartialSupportG9N9N: Bool = false) {
        self.remoteName = purpose == .integration ? nil : remoteName
        self.buttonsVerified = purpose == .integration ? nil : buttonsVerified
        self.microphoneReady = purpose == .initialSetup ? microphoneReady : nil
        self.voiceKeyMode = purpose == .addDevice ? nil : voiceKeyMode
        self.tapModeEnabled = purpose == .addDevice ? nil : tapModeEnabled
        self.voiceTool = purpose == .addDevice ? nil : voiceTool
        self.isPartialSupportG9N9N = purpose == .integration ? false : isPartialSupportG9N9N
        self.voiceVerified = purpose == .addDevice ? nil : (
            binding?.validationState == .verified && binding?.tool == voiceTool &&
            binding?.shortcut == voiceKeyMode && binding?.gestureMode == (tapModeEnabled ? .toggle : .hold)
        )
    }
}
