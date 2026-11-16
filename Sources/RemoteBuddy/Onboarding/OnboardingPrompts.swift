import Foundation

enum OnboardingVoiceGesturePrompt {
    static func text(
        for mode: VoiceGestureMode,
        fnTapModeEnabled: Bool = false,
        controlSource: OnboardingControlSource = .unselected,
        locale: Locale
    ) -> String {
        let isChinese = locale.identifier.lowercased().hasPrefix("zh")
        let snapshot = LocalizationSnapshot(language: isChinese ? .simplifiedChinese : .english)
        if controlSource == .t1Remote {
            return snapshot.text(
                fnTapModeEnabled
                    ? "onboarding.voice_prompt.t1.fn_tap"
                    : "onboarding.voice_prompt.t1.hold"
            )
        }
        if fnTapModeEnabled {
            return snapshot.text("onboarding.voice_prompt.generic.fn_tap")
        }
        switch mode {
        case .hold:
            return snapshot.text("onboarding.voice_prompt.generic.hold")
        case .toggle:
            return snapshot.text("onboarding.voice_prompt.generic.toggle")
        }
    }
}

