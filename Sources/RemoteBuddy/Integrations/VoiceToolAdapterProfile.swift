import Foundation

enum OnboardingVoiceTool: String, CaseIterable, Codable, Identifiable {
    case unselected
    case weixin
    case doubao
    case chatterfly
    case voiceBuddy = "voice_buddy"
    case bageshuo
    case typeless
    case macosDictation = "macos_dictation"
    case other

    var id: String { rawValue }

    var titleKey: String {
        "onboarding.voice_tool.\(rawValue).title"
    }

    var detailKey: String {
        "onboarding.voice_tool.\(rawValue).detail"
    }

    var preferredInputSourceID: String? {
        switch self {
        case .doubao:
            return "com.bytedance.inputmethod.doubaoime.pinyin"
        case .weixin:
            return "com.tencent.inputmethod.wetype.pinyin"
        case .unselected, .chatterfly, .voiceBuddy, .bageshuo, .typeless, .macosDictation, .other:
            return nil
        }
    }

    /// Input source selected automatically before each live voice session.
    /// WeType listens for its global shortcut across active input sources; calling
    /// `TISSelectInputSource` from a background helper before sending the trigger
    /// can break direct text insertion in Electron/Chromium hosts (Command+V fallback).
    var automaticVoiceSessionInputSourceID: String? {
        switch self {
        case .doubao:
            return preferredInputSourceID
        case .weixin, .unselected, .chatterfly, .voiceBuddy, .bageshuo, .typeless, .macosDictation, .other:
            return nil
        }
    }

    var applicationBundleIdentifier: String? {
        switch self {
        case .chatterfly:
            return "com.tencent.inputmethod.chatterfly"
        case .voiceBuddy:
            return "com.voicebuddy.app"
        case .bageshuo:
            return "com.bageshuo"
        case .typeless:
            return "now.typeless.desktop"
        case .unselected, .doubao, .weixin, .macosDictation, .other:
            return nil
        }
    }

    var requiresInputSourceSelection: Bool {
        preferredInputSourceID != nil
    }

    /// Fn taps that start one voice session. macOS Dictation uses "Press 🌐 Twice"
    /// to start and one Fn press to stop.
    var functionKeyStartTapCount: Int {
        self == .macosDictation ? 2 : 1
    }
}


struct VoiceToolAdapterProfile: Equatable {
    let tool: OnboardingVoiceTool
    let supportedModes: Set<VoiceGestureMode>
    let defaultShortcutByMode: [VoiceGestureMode: VoiceKeyMode]
    let recommendedMode: VoiceGestureMode?
    let installationProbe: VoiceToolInstallationProbe
    let evidenceState: VoiceToolEvidenceState

    static func profile(for tool: OnboardingVoiceTool) -> Self {
        switch tool {
        case .weixin:
            return Self(
                tool: tool,
                supportedModes: [.hold, .toggle],
                defaultShortcutByMode: [.hold: .suggestedShortcut, .toggle: .rightCommand],
                recommendedMode: .hold,
                installationProbe: .inputSource,
                evidenceState: .pending
            )
        case .doubao:
            return Self(
                tool: tool,
                supportedModes: [.hold, .toggle],
                defaultShortcutByMode: [.hold: .suggestedShortcut, .toggle: .rightCommand],
                recommendedMode: .hold,
                installationProbe: .inputSource,
                evidenceState: .verified
            )
        case .bageshuo:
            return Self(
                tool: tool,
                supportedModes: [.toggle],
                defaultShortcutByMode: [.toggle: .suggestedShortcut],
                recommendedMode: .toggle,
                installationProbe: .applicationBundle,
                evidenceState: .verified
            )
        case .typeless:
            return Self(
                tool: tool,
                supportedModes: [.toggle],
                defaultShortcutByMode: [.toggle: .suggestedShortcut],
                recommendedMode: .toggle,
                installationProbe: .applicationBundle,
                evidenceState: .verified
            )
        case .macosDictation:
            return Self(
                tool: tool,
                supportedModes: [.toggle],
                defaultShortcutByMode: [.toggle: .function],
                recommendedMode: .toggle,
                installationProbe: .none,
                evidenceState: .pending
            )
        case .chatterfly:
            // Global voice shortcuts work without changing the active input source.
            // Only hold-to-talk is integrated; onboarding still requires a real voice test.
            return Self(
                tool: tool,
                supportedModes: [.hold],
                defaultShortcutByMode: [.hold: .suggestedShortcut],
                recommendedMode: .hold,
                installationProbe: .applicationBundle,
                evidenceState: .pending
            )
        case .voiceBuddy:
            return Self(
                tool: tool,
                supportedModes: [.hold, .toggle],
                defaultShortcutByMode: [.hold: .function, .toggle: .function],
                recommendedMode: .hold,
                installationProbe: .applicationBundle,
                evidenceState: .verified
            )
        case .other:
            return Self(
                tool: tool,
                supportedModes: [.hold, .toggle],
                // The third-party tool remains unobserved; the preset chord is only
                // the temporary Onboarding trigger and still requires the user's
                // real voice-text confirmation before it can be committed.
                defaultShortcutByMode: [.hold: .suggestedShortcut, .toggle: .suggestedShortcut],
                recommendedMode: .hold,
                installationProbe: .none,
                evidenceState: .unknown
            )
        case .unselected:
            return Self(
                tool: tool,
                supportedModes: [],
                defaultShortcutByMode: [:],
                recommendedMode: nil,
                installationProbe: .none,
                evidenceState: .unknown
            )
        }
    }
}

