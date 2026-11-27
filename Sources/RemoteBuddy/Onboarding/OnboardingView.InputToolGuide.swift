import AppKit
import Combine
import CoreBluetooth
import SwiftUI

extension OnboardingView {
    @ViewBuilder
    func voiceToolCard(for tool: OnboardingVoiceTool) -> some View {
        let isSelected = settings.onboardingVoiceTool == tool

        VStack(alignment: .leading, spacing: 0) {
            onboardingActionButton(id: "voice-tool.\(tool.rawValue)") {
                selectVoiceTool(tool)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: voiceToolIcon(tool))
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 32, height: 32)
                        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(localization.text(tool.titleKey))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(localization.text(tool.detailKey))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if voiceToolAvailability[tool] == .notInstalled {
                            Text(verbatim: localization.text("onboarding.voice_tool.status.not_installed"))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 17))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .top)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .top)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.09)
                : Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isSelected
                        ? Color.accentColor.opacity(0.65)
                        : Color.primary.opacity(0.08),
                    lineWidth: 1
                )
        }
    }

    func inputMethodGuide(for tool: OnboardingVoiceTool) -> some View {
        let steps = inputMethodGuideSteps(for: tool)
        let selectedIndex = selectedInputMethodGuideStep.flatMap { index in
            steps.indices.contains(index) ? index : nil
        }

        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(localization.text("onboarding.voice_tool.guide.title"))
                    .font(.system(size: 15, weight: .semibold))
                Text(localization.text("onboarding.voice_tool.guide.detail"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if tool.requiresInputSourceSelection {
                inputSourceSwitchStatus(for: tool)
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8, alignment: .top),
                    GridItem(.flexible(), alignment: .top),
                ],
                spacing: 8
            ) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    let isViewed = viewedInputMethodGuideSteps.contains(step.id)
                    onboardingActionButton(id: "input-guide.\(index)") {
                        selectedInputMethodGuideStep = index
                        viewedInputMethodGuideSteps.insert(step.id)
                    } label: {
                        HStack(alignment: .center, spacing: 8) {
                            Group {
                                if isViewed {
                                    Image(systemName: "eye")
                                        .font(.system(size: 11, weight: .bold))
                                } else {
                                    Text("\(index + 1)")
                                        .font(.system(size: 12, weight: .bold))
                                }
                            }
                                .frame(width: 22, height: 22)
                                .background(
                                    selectedIndex == index ? Color.accentColor : Color.primary.opacity(0.08),
                                    in: Circle()
                                )
                                .foregroundStyle(
                                    selectedIndex == index ? Color.white : Color.primary
                                )
                            VStack(alignment: .leading, spacing: 3) {
                                Text(voiceToolGuideText(step.titleKey))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.primary)
                                if isViewed {
                                    Text(localization.text("onboarding.guide.viewed"))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxHeight: .infinity, alignment: .center)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(minHeight: 54)
                        .background(
                            selectedIndex == index
                                ? Color.accentColor.opacity(0.09)
                                : Color.primary.opacity(0.035),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(
                                    selectedIndex == index
                                        ? Color.accentColor.opacity(0.55)
                                        : Color.primary.opacity(0.08),
                                    lineWidth: 1
                                )
                        }
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                }
            }

            if let selectedIndex {
                switch steps[selectedIndex].content {
                case let .screenshot(resourceName):
                    onboardingGuideScreenshot(resourceName: resourceName)
                case let .instruction(systemImage, detailKey):
                    onboardingGuideInstruction(systemImage: systemImage, detailKey: detailKey)
                case .systemFunctionKey:
                    systemFunctionKeyInstruction
                case .microphoneIntegration:
                    externalToolMicrophoneConfigurationCard
                }
            } else {
                Text(verbatim: localization.text("onboarding.voice_tool.guide.select_step"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            }
            wechatShortcutHelp
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var wechatShortcutHelp: some View {
        VStack(alignment: .leading, spacing: 8) {
            onboardingActionButton(id: "wechat-conflict.toggle") {
                wechatHelpExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: wechatHelpExpanded ? "chevron.down" : "chevron.right")
                    Text(localization.text("onboarding.voice_tool.guide.release_wechat_shortcut"))
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if wechatHelpExpanded {
                onboardingGuideScreenshot(resourceName: "weixin-app-shortcuts")
            }
        }
    }

    private func inputSourceSwitchStatus(for tool: OnboardingVoiceTool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: inputSourceSwitchResult == .selected ? "checkmark.circle.fill" : "keyboard.badge.ellipsis")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(inputSourceSwitchResult == .selected ? Color.green : Color.accentColor)

            Text(inputSourceSwitchStatusText(for: tool))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            if inputSourceSwitchResult == .unavailable || inputSourceSwitchResult == .failed {
                onboardingActionButton(id: "input-source.activate") {
                    activateSelectedInputMethod()
                } label: {
                    Text(verbatim: localization.text(
                        inputSourceSwitchResult == .failed
                            ? "onboarding.voice_tool.switch.retry"
                            : "onboarding.voice_tool.switch.select"
                    ))
                }
                .buttonStyle(.bordered)
            }

            if inputSourceSwitchResult == .notSelected {
                onboardingActionButton(id: "input-source.activate") {
                    activateSelectedInputMethod()
                } label: {
                    Text(verbatim: localization.text("onboarding.voice_tool.switch.select"))
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    func onboardingGuideScreenshot(resourceName: String) -> some View {
        let captionKey = "onboarding.voice_tool.guide.screenshot." +
            resourceName.replacingOccurrences(of: "-", with: "_")
        let shortcutName = voiceToolGuideShortcutDisplayName
        return VStack(alignment: .leading, spacing: 8) {
            if let image = onboardingGuideImage(resourceName: resourceName) {
                onboardingGuidePreview(image: image, resourceName: resourceName)
                    .frame(height: 260)
                    .frame(maxWidth: .infinity)
                    // Guide pictures are informational; clicks belong to the surrounding controls.
                    .allowsHitTesting(false)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                    }
            } else {
                Text(verbatim: localization.text("onboarding.voice_tool.guide.image_missing"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            }
            Group {
                Text(Self.highlightedGuideText(
                    voiceToolGuideText(captionKey),
                    highlighting: shortcutName,
                    fontSize: 12
                ))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notice = Self.screenshotShortcutNotice(for: resourceName) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.red)
                        .padding(.top, 1)
                    Text(Self.highlightedGuideText(
                        voiceToolGuideText(notice.localizationKey),
                        highlighting: shortcutName,
                        fontSize: 12
                    ))
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.red.opacity(0.24), lineWidth: 1)
                }
            }
        }
    }

    private func onboardingGuidePreview(image: NSImage, resourceName: String) -> some View {
        GeometryReader { geometry in
            let fittedRect = Self.aspectFitRect(imageSize: image.size, in: geometry.size)
            ZStack(alignment: .topLeading) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geometry.size.width, height: geometry.size.height)

                if let callout = Self.screenshotShortcutCallout(for: resourceName) {
                    let anchorWidth = fittedRect.width * callout.trailingX
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        HStack(spacing: 3) {
                            Text(verbatim: localization.text("onboarding.voice_tool.guide.screenshot.example_badge"))
                                .font(.system(size: 9.5, weight: .bold))
                                .multilineTextAlignment(.trailing)
                                .lineSpacing(1)
                                .fixedSize(horizontal: true, vertical: true)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 8.5, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.red.opacity(0.92), in: RoundedRectangle(cornerRadius: 5))
                        .shadow(color: Color.black.opacity(0.20), radius: 2, y: 1)
                    }
                    .frame(width: anchorWidth, alignment: .trailing)
                    .position(
                        x: fittedRect.minX + anchorWidth / 2,
                        y: fittedRect.minY + fittedRect.height * callout.centerY
                    )
                }
            }
        }
    }

    private func onboardingGuideInstruction(
        systemImage: String,
        detailKey: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34)
            Text(Self.highlightedGuideText(
                voiceToolGuideText(detailKey),
                highlighting: voiceToolGuideShortcutDisplayName,
                fontSize: 13
            ))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var systemFunctionKeyInstruction: some View {
        VStack(alignment: .leading, spacing: 12) {
            onboardingGuideScreenshot(resourceName: "system-fn")

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemFunctionKeyAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(systemFunctionKeyAvailable ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(localization.text(
                        systemFunctionKeyAvailable
                            ? "onboarding.voice_tool.system_fn.ready"
                            : "onboarding.voice_tool.system_fn.conflict"
                    ))
                    .font(.system(size: 14, weight: .semibold))
                    Text(verbatim: localization.text("onboarding.voice_tool.system_fn.detail"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if !systemFunctionKeyAvailable {
                    onboardingActionButton(id: "keyboard-settings.open") {
                        openKeyboardSettings()
                    } label: {
                        Text(verbatim: localization.text("onboarding.voice_tool.system_fn.open_settings"))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    func inputMethodGuideSteps(
        for tool: OnboardingVoiceTool
    ) -> [OnboardingInputMethodGuideStep] {
        let toolSteps: [OnboardingInputMethodGuideStep]
        switch tool {
        case .doubao:
            toolSteps = [
                OnboardingInputMethodGuideStep(
                    id: 1,
                    titleKey: "onboarding.voice_tool.guide.select_doubao",
                    content: .screenshot("doubao-menu")
                ),
                OnboardingInputMethodGuideStep(
                    id: 2,
                    titleKey: "onboarding.voice_tool.guide.configure_doubao",
                    content: .screenshot("doubao-settings")
                ),
            ]
        case .weixin:
            toolSteps = [
                OnboardingInputMethodGuideStep(
                    id: 1,
                    titleKey: "onboarding.voice_tool.guide.select_weixin",
                    content: .screenshot("weixin-input-menu")
                ),
                OnboardingInputMethodGuideStep(
                    id: 2,
                    titleKey: "onboarding.voice_tool.guide.configure_weixin",
                    content: .screenshot("weixin-input-settings")
                ),
            ]
        case .bageshuo:
            toolSteps = [
                OnboardingInputMethodGuideStep(
                    id: 1,
                    titleKey: "onboarding.voice_tool.guide.open_bageshuo",
                    content: .screenshot("bageshuo-menu")
                ),
                OnboardingInputMethodGuideStep(
                    id: 2,
                    titleKey: "onboarding.voice_tool.guide.configure_bageshuo",
                    content: .screenshot("bageshuo-settings")
                ),
            ]
        case .typeless:
            toolSteps = [
                OnboardingInputMethodGuideStep(
                    id: 1,
                    titleKey: "onboarding.voice_tool.guide.open_typeless",
                    content: .instruction(
                        systemImage: "waveform.badge.mic",
                        detailKey: "onboarding.voice_tool.guide.open_typeless.detail"
                    )
                ),
                OnboardingInputMethodGuideStep(
                    id: 2,
                    titleKey: "onboarding.voice_tool.guide.configure_typeless",
                    content: .instruction(
                        systemImage: "hand.tap.fill",
                        detailKey: "onboarding.voice_tool.guide.configure_typeless.detail"
                    )
                ),
            ]
        case .chatterfly:
            toolSteps = [
                OnboardingInputMethodGuideStep(
                    id: 1,
                    titleKey: "onboarding.voice_tool.guide.open_chatterfly",
                    content: .instruction(systemImage: "waveform", detailKey: "onboarding.voice_tool.guide.open_chatterfly.detail")
                ),
                OnboardingInputMethodGuideStep(
                    id: 2,
                    titleKey: "onboarding.voice_tool.guide.configure_chatterfly",
                    content: .screenshot("chatterfly-settings")
                ),
            ]
        case .voiceBuddy:
            toolSteps = [
                OnboardingInputMethodGuideStep(
                    id: 1,
                    titleKey: "onboarding.voice_tool.guide.open_voice_buddy",
                    content: .instruction(systemImage: "waveform.circle.fill", detailKey: "onboarding.voice_tool.guide.open_voice_buddy.detail")
                ),
                OnboardingInputMethodGuideStep(
                    id: 2,
                    titleKey: "onboarding.voice_tool.guide.configure_voice_buddy",
                    content: .screenshot("voicebuddy-setting-fn")
                ),
            ]
        case .macosDictation:
            // Dictation needs 🌐 assigned to it, so the generic "release system Fn"
            // step does not apply.
            return [
                OnboardingInputMethodGuideStep(
                    id: 1,
                    titleKey: "onboarding.voice_tool.guide.enable_dictation",
                    content: .screenshot("macos-dictation-enable")
                ),
                OnboardingInputMethodGuideStep(
                    id: 2,
                    titleKey: "onboarding.voice_tool.guide.configure_dictation",
                    content: .screenshot("macos-dictation-shortcut")
                ),
                OnboardingInputMethodGuideStep(
                    id: 3,
                    titleKey: "onboarding.voice_tool.guide.select_microphone",
                    content: .microphoneIntegration
                ),
            ]
        case .other:
            toolSteps = [
                OnboardingInputMethodGuideStep(
                    id: 1,
                    titleKey: "onboarding.voice_tool.guide.open_other",
                    content: .instruction(
                        systemImage: "mic.fill",
                        detailKey: "onboarding.voice_tool.guide.open_other.detail"
                    )
                ),
                OnboardingInputMethodGuideStep(
                    id: 2,
                    titleKey: "onboarding.voice_tool.guide.configure_other",
                    content: .instruction(
                        systemImage: "globe",
                        detailKey: "onboarding.voice_tool.guide.configure_other.detail"
                    )
                ),
            ]
        case .unselected:
            return []
        }

        var steps = toolSteps + [
            OnboardingInputMethodGuideStep(
                id: 3,
                titleKey: "onboarding.voice_tool.guide.select_microphone",
                content: .microphoneIntegration
            ),
        ]
        if settings.selectedVoiceTrigger.voiceKeyMode == .function {
            steps.append(OnboardingInputMethodGuideStep(
                id: 4,
                titleKey: "onboarding.voice_tool.guide.release_system_fn",
                content: .systemFunctionKey
            ))
        }
        return steps
    }

    var voiceToolGuideGesture: VoiceGestureMode {
        settings.selectedVoiceTrigger.voiceFnTapModeEnabled ? .toggle : .hold
    }

    var voiceToolGuideShortcutDisplayName: String {
        settings.selectedVoiceTrigger.voiceKeyMode.displayName(using: localization)
    }

    static func screenshotShortcutCallout(
        for resourceName: String
    ) -> OnboardingGuideScreenshotShortcutCallout? {
        switch resourceName {
        case "weixin-input-settings":
            .init(trailingX: 0.785, centerY: 0.317)
        case "doubao-settings":
            .init(trailingX: 0.795, centerY: 0.236)
        case "bageshuo-settings":
            .init(trailingX: 0.722, centerY: 0.220)
        case "chatterfly-settings":
            .init(trailingX: 0.700, centerY: 0.262)
        case "voicebuddy-setting-fn":
            .init(trailingX: 0.832, centerY: 0.348)
        default:
            nil
        }
    }

    static func aspectFitRect(imageSize: CGSize, in containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              containerSize.width > 0, containerSize.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }
        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        let fittedWidth = imageSize.width * scale
        let fittedHeight = imageSize.height * scale
        return CGRect(
            x: (containerSize.width - fittedWidth) / 2,
            y: (containerSize.height - fittedHeight) / 2,
            width: fittedWidth,
            height: fittedHeight
        )
    }

    static func screenshotShortcutNotice(
        for resourceName: String
    ) -> OnboardingGuideScreenshotShortcutNotice? {
        switch resourceName {
        case "doubao-settings",
             "weixin-input-settings",
             "bageshuo-settings",
             "chatterfly-settings",
             "voicebuddy-setting-fn":
            .configureShortcut
        case "weixin-app-shortcuts":
            .conflictCheck
        default:
            nil
        }
    }

    static func highlightedGuideText(
        _ text: String,
        highlighting shortcutDisplayName: String,
        fontSize: CGFloat = 12
    ) -> AttributedString {
        var attributed = AttributedString(text)
        guard !shortcutDisplayName.isEmpty else { return attributed }

        var searchStart = attributed.startIndex
        while searchStart < attributed.endIndex,
              let range = attributed[searchStart..<attributed.endIndex].range(of: shortcutDisplayName) {
            attributed[range].foregroundColor = .red
            attributed[range].font = .system(size: fontSize, weight: .bold)
            searchStart = range.upperBound
        }
        return attributed
    }

    func voiceToolGuideText(_ key: String) -> String {
        LocalizedMessage(key, arguments: [
            voiceToolGuideShortcutDisplayName,
            localization.text("onboarding.gesture.\(voiceToolGuideGesture.rawValue)"),
        ]).text(using: localization)
    }

    private func onboardingGuideImage(resourceName: String) -> NSImage? {
        guard let url = RemoteBuddyResourceBundle.onboardingImageURL(
            named: resourceName, isDark: colorScheme == .dark,
            in: RemoteBuddyResourceBundle.mainOrDevelopment
        ) else {
            return nil
        }
        return OnboardingImageCache.image(at: url)
    }

    func selectVoiceTool(_ tool: OnboardingVoiceTool) {
        settings.setOnboardingVoiceTool(tool)
        AppLogger.shared.write(
            "ONBOARDING VOICE_TOOL selected=\(tool.rawValue) binding_policy=selected_voice_key"
        )
        selectedInputMethodGuideStep = nil
        wechatHelpExpanded = false
        viewedInputMethodGuideSteps.removeAll()
        refreshSelectedInputMethodStatus()
        refreshSystemFunctionKeyUsage()
        stageCurrentDocumentedPairingPlanIfPossible()
    }

    func stageCurrentDocumentedPairingPlanIfPossible() {
        guard let plan = proposedPairingPlan else { return }
        settings.beginOnboardingVoiceTrial(plan)
    }
}
struct OnboardingInputMethodGuideStep: Identifiable {
    enum Content {
        case screenshot(String)
        case instruction(systemImage: String, detailKey: String)
        case systemFunctionKey
        case microphoneIntegration
    }

    let id: Int
    let titleKey: String
    let content: Content
}

struct OnboardingGuideScreenshotShortcutCallout: Equatable {
    let trailingX: CGFloat
    let centerY: CGFloat
}

enum OnboardingGuideScreenshotShortcutNotice: Equatable {
    case configureShortcut
    case conflictCheck

    var localizationKey: String {
        switch self {
        case .configureShortcut:
            "onboarding.voice_tool.guide.screenshot.example_notice"
        case .conflictCheck:
            "onboarding.voice_tool.guide.screenshot.conflict_example_notice"
        }
    }
}
