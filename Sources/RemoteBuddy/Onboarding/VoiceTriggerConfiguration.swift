import Foundation

struct VoiceTriggerConfiguration: Codable, Equatable {
    let voiceKeyMode: VoiceKeyMode
    let voiceFnTapModeEnabled: Bool
}
