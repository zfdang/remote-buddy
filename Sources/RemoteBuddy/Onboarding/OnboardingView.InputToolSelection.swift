import AppKit
import Combine
import CoreBluetooth
import SwiftUI

extension OnboardingView {
    var voiceToolContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            onboardingTitle("onboarding.voice_tool.title")
            Text(verbatim: localization.text("onboarding.voice_tool.detail"))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(voiceToolGuideText("onboarding.voice_tool.guide.match_shortcut"))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if voiceToolBlockingHintKey == "onboarding.voice_tool.tap_required" {
                VStack(alignment: .leading, spacing: 8) {
                    Text(localization.text("onboarding.voice_tool.tap_required"))
                        .foregroundStyle(.orange)
                    HStack {
                        onboardingActionButton(id: "voice-tool.enable-tap") {
                            settings.selectOnboardingFnTapMode(true)
                            stageCurrentDocumentedPairingPlanIfPossible()
                        } label: { Text(localization.text("onboarding.voice_tool.enable_tap")) }
                        .buttonStyle(.borderedProminent)
                        onboardingActionButton(id: "voice-tool.choose-another") {
                            selectVoiceTool(.unselected)
                        } label: { Text(localization.text("onboarding.voice_tool.choose_another")) }
                        .buttonStyle(.bordered)
                    }
                }
            }

            if voiceToolBlockingHintKey == "onboarding.voice_tool.trigger_incompatible" {
                VStack(alignment: .leading, spacing: 8) {
                    Text(localization.text("onboarding.voice_tool.trigger_incompatible"))
                        .foregroundStyle(.orange)
                    HStack {
                        onboardingActionButton(id: "voice-tool.use-fn") {
                            selectFunctionTriggerForVoiceTool()
                        } label: { Text(localization.text("onboarding.voice_tool.use_fn")) }
                        .buttonStyle(.borderedProminent)
                        onboardingActionButton(id: "voice-tool.choose-another") {
                            selectVoiceTool(.unselected)
                        } label: { Text(localization.text("onboarding.voice_tool.choose_another")) }
                        .buttonStyle(.bordered)
                    }
                }
            }

            if allRecognizedVoiceToolsUnavailable {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.orange)
                    Text(verbatim: localization.text("onboarding.voice_tool.none_detected"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.orange.opacity(0.22), lineWidth: 1)
                }
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8, alignment: .top),
                    GridItem(.flexible(), alignment: .top),
                ],
                spacing: 8
            ) {
                ForEach(visibleVoiceTools) { tool in
                    voiceToolCard(for: tool)
                }
            }

            if settings.onboardingVoiceTool == .doubao && voiceToolAvailability[.doubao] == .notInstalled {
                HStack(spacing: 8) {
                    Text(verbatim: localization.text("onboarding.voice_tool.doubao.install_detail"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    onboardingLink(id: "voice-tool.doubao.install", destination: AppLinks.doubaoInputMethod) {
                        Text(verbatim: localization.text("onboarding.voice_tool.doubao.install"))
                    }
                    .font(.system(size: 12, weight: .semibold))
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            if settings.onboardingVoiceTool == .voiceBuddy {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "waveform.circle.fill")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(verbatim: localization.text("onboarding.voice_tool.voice_buddy.intro"))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 8) {
                                if voiceToolAvailability[.voiceBuddy] == .notInstalled {
                                    Text(verbatim: localization.text("onboarding.voice_tool.voice_buddy.install_detail"))
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                                onboardingLink(
                                    id: "voice-tool.voice-buddy.website",
                                    destination: AppLinks.voiceBuddyWebsite(for: localization.locale)
                                ) {
                                    Text(verbatim: localization.text("onboarding.voice_tool.voice_buddy.website"))
                                }
                                .font(.system(size: 12, weight: .semibold))
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
                }
            }

            if settings.onboardingVoiceTool == .bageshuo && voiceToolAvailability[.bageshuo] == .notInstalled {
                HStack(spacing: 8) {
                    Text(verbatim: localization.text("onboarding.voice_tool.bageshuo.install_detail"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    onboardingLink(id: "voice-tool.bageshuo.install", destination: AppLinks.bageshuoWebsite) {
                        Text(verbatim: localization.text("onboarding.voice_tool.bageshuo.install"))
                    }
                    .font(.system(size: 12, weight: .semibold))
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            if proposedPairingPlan?.fnTapModeEnabled == true {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                    Text(verbatim: fnTapExplanationText(fallbackKey: "onboarding.voice_tool.fn_tap_banner"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }

            if settings.onboardingVoiceTool == .other {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "mic.badge.xmark")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                    Text(verbatim: localization.text("onboarding.voice_tool.other.setup_detail"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
                }
            }

        }
    }
    func selectFunctionTriggerForVoiceTool() {
        settings.selectOnboardingVoiceTrigger(.function)
        selectedInputMethodGuideStep = nil
        viewedInputMethodGuideSteps.removeAll()
        refreshSystemFunctionKeyUsage()
        stageCurrentDocumentedPairingPlanIfPossible()
    }

}
