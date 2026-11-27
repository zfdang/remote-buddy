import AppKit
import CoreGraphics
import Foundation
import Testing
import SwiftUI
@testable import RemoteBuddy

@Suite("Voice shortcut configuration")
@MainActor
struct VoiceTriggerConfigurationTests {
    private func withSettings(_ body: (AppSettings, UserDefaults) throws -> Void) throws {
        let defaults = EphemeralUserDefaults()
        try body(AppSettings(defaults: defaults), defaults)
    }

    @Test func selectedChordPersistsWithoutReplacingTheCommittedTriggerUntilVerified() throws {
        try withSettings { settings, defaults in
            settings.voiceKeyMode = .rightOption
            settings.setOnboardingControlSource(.xiaomiRemote)
            settings.setOnboardingVoiceTool(.weixin)
            settings.setOnboardingStep(.voiceTrigger)
            settings.selectOnboardingVoiceTrigger(.suggestedShortcut)
            #expect(settings.voiceKeyMode == .rightOption)
            #expect(AppSettings(defaults: defaults).voiceKeyMode == .rightOption)
            #expect(AppSettings(defaults: defaults).selectedVoiceTrigger.voiceKeyMode == .suggestedShortcut)
            let view = OnboardingView(model: BridgeAppModel(settings: settings, initialAudioDevices: []))
            let plan = try #require(view.proposedPairingPlan)
            #expect(plan.binding.shortcut == .suggestedShortcut)
            #expect(plan.binding.gestureMode == .hold)
            settings.beginOnboardingVoiceTrial(plan)
            #expect(settings.effectiveVoiceKeyMode == .rightOption)
            settings.setOnboardingStep(.voiceTest)
            #expect(settings.effectiveVoiceKeyMode == .suggestedShortcut)
            #expect(settings.voiceKeyMode == .rightOption)
            #expect(AppSettings(defaults: defaults).effectiveVoiceKeyMode == .suggestedShortcut)
            settings.verifyOnboardingVoiceBinding()
            #expect(settings.voiceKeyMode == .suggestedShortcut)
            #expect(AppSettings(defaults: defaults).voiceKeyMode == .suggestedShortcut)
            #expect(settings.verifiedVoiceToolBinding?.validationState == .verified)
        }
    }

    @Test func cancellingIntegrationDiscardsBothPendingTriggerAndTapChanges() throws {
        try withSettings { settings, _ in
            let profile = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
            settings.selectRemoteProfile(profile)
            settings.voiceKeyMode = .rightOption
            settings.setOnboardingVoiceTool(.weixin)
            settings.completeOnboarding()
            SettingsPageBehavior.beginIntegrationSetup(tool: .weixin, settings: settings)
            settings.selectOnboardingVoiceTrigger(.function)
            settings.selectOnboardingFnTapMode(true)
            #expect(settings.voiceKeyMode == .rightOption)
            #expect(!settings.voiceFnTapModeEnabled)
            let view = OnboardingView(model: BridgeAppModel(settings: settings, initialAudioDevices: []))
            settings.beginOnboardingVoiceTrial(try #require(view.proposedPairingPlan))
            settings.setOnboardingStep(.voiceTest)
            #expect(settings.effectiveVoiceKeyMode == .function)
            #expect(settings.effectiveVoiceFnTapModeEnabled)
            settings.dismissOnboarding()
            #expect(settings.voiceKeyMode == .rightOption)
            #expect(!settings.voiceFnTapModeEnabled)
            #expect(settings.onboardingVoiceTrigger == nil)
            #expect(settings.stagedVoiceToolBinding == nil)
        }
    }

    @Test func rerunningAnUnchangedVerifiedBindingStillRequiresANewVoiceTest() throws {
        try withSettings { settings, _ in
            settings.setOnboardingControlSource(.xiaomiRemote)
            settings.setOnboardingVoiceTool(.weixin)
            settings.voiceKeyMode = .rightOption
            let verified = VoiceToolUserBinding(tool: .weixin, shortcut: .rightOption,
                gestureMode: .hold, source: .manuallyConfirmed, validationState: .verified,
                verifiedToolVersion: "1", verifiedAt: Date())
            settings.verifiedVoiceToolBinding = verified
            let view = OnboardingView(model: BridgeAppModel(settings: settings, initialAudioDevices: []))
            settings.beginOnboardingVoiceTrial(try #require(view.proposedPairingPlan))
            settings.setOnboardingStep(.voiceTest)
            #expect(settings.isTestingVoiceTrigger)
            #expect(settings.stagedVoiceToolBinding?.validationState == .staged)
            #expect(settings.stagedVoiceToolBinding?.verifiedAt == nil)
            #expect(settings.verifiedVoiceToolBinding == verified)
            #expect(!view.canContinue)
        }
    }

    @Test func oldVerificationCannotOverrideANewTriggerAndFnInstructionsFollowTheSelection() throws {
        try withSettings { settings, _ in
            settings.setOnboardingControlSource(.xiaomiRemote)
            settings.setOnboardingVoiceTool(.weixin)
            settings.verifiedVoiceToolBinding = VoiceToolUserBinding(tool: .weixin,
                shortcut: .function, gestureMode: .hold, source: .manuallyConfirmed,
                validationState: .verified, verifiedToolVersion: "1", verifiedAt: Date())
            settings.selectOnboardingVoiceTrigger(.rightOption)
            let view = OnboardingView(model: BridgeAppModel(settings: settings, initialAudioDevices: []))
            let plan = try #require(view.proposedPairingPlan)
            #expect(plan.binding.shortcut == .rightOption)
            #expect(plan.binding.validationState == .staged)
            #expect(plan.binding.verifiedAt == nil)
            #expect(!view.inputMethodGuideSteps(for: .weixin).contains { step in
                if case .systemFunctionKey = step.content { return true }; return false
            })
            settings.selectOnboardingVoiceTrigger(.function)
            #expect(view.inputMethodGuideSteps(for: .weixin).contains { step in
                if case .systemFunctionKey = step.content { return true }; return false
            })
        }
    }

    @Test func guideSummaryUsesTheCandidateModeEvenWithoutAValidPairingPlan() throws {
        try withSettings { settings, _ in
            let view = OnboardingView(model: BridgeAppModel(settings: settings, initialAudioDevices: []))
            settings.selectOnboardingFnTapMode(true)
            #expect(view.proposedPairingPlan == nil)
            #expect(view.voiceToolGuideGesture == .toggle)
            settings.setOnboardingControlSource(.xiaomiRemote)
            settings.setOnboardingVoiceTool(.macosDictation)
            settings.selectOnboardingVoiceTrigger(.rightOption)
            #expect(view.proposedPairingPlan == nil)
            #expect(view.voiceToolGuideGesture == .toggle)
            settings.selectOnboardingFnTapMode(false)
            #expect(view.voiceToolGuideGesture == .hold)
        }
    }

    @Test func anExpiredVoiceTrialCanReturnToToolSetupWithoutCommittingTheCandidate() throws {
        try withSettings { settings, defaults in
            settings.voiceKeyMode = .rightOption
            settings.setOnboardingControlSource(.xiaomiRemote)
            settings.setOnboardingVoiceTool(.weixin)
            settings.selectOnboardingVoiceTrigger(.suggestedShortcut)
            settings.setOnboardingStep(.voiceTest)
            let view = OnboardingView(model: BridgeAppModel(settings: settings, initialAudioDevices: []))
            #expect(!settings.isTestingVoiceTrigger)
            #expect(!view.canContinue)
            view.returnToVoiceToolConfiguration()
            #expect(settings.onboardingStep == .voiceTool)
            #expect(settings.voiceKeyMode == .rightOption)
            #expect(AppSettings(defaults: defaults).voiceKeyMode == .rightOption)
        }
    }

    @Test func toolSetupRequiresEveryApplicableInstructionToBeViewed() throws {
        try withSettings { settings, _ in
            settings.setOnboardingControlSource(.xiaomiRemote)
            settings.setOnboardingVoiceTool(.weixin)
            settings.setOnboardingStep(.voiceTool)
            settings.selectOnboardingVoiceTrigger(.rightOption)
            let view = OnboardingView(model: BridgeAppModel(settings: settings, initialAudioDevices: []),
                voiceToolAvailabilityOverride: [.weixin: .available], permissionOverrides: .allGranted)
            #expect(view.voiceToolBlockingHintKey == "onboarding.voice_tool.guide.continue_hint")
            #expect(!view.canContinue)
            let ids = Set(view.inputMethodGuideSteps(for: .weixin).map(\.id))
            #expect(view.hasViewedInputMethodGuideSteps(ids))
            for id in ids {
                #expect(!view.hasViewedInputMethodGuideSteps(ids.subtracting([id])))
            }
            view.continueFlow()
            #expect(settings.onboardingStep == .voiceTool)
            #expect(settings.voiceKeyMode == .suggestedShortcut)
            // Switching to Fn adds its system-conflict instruction to the required views.
            settings.selectOnboardingVoiceTrigger(.function)
            #expect(!view.hasViewedInputMethodGuideSteps(ids))
        }
    }

    @Test func correctingDictationTriggerChangesOnlyTheCandidateAndStillRequiresTesting() throws {
        try withSettings { settings, defaults in
            settings.voiceKeyMode = .rightOption
            settings.setOnboardingControlSource(.xiaomiRemote)
            settings.setOnboardingVoiceTool(.macosDictation)
            settings.selectOnboardingVoiceTrigger(.suggestedShortcut)
            settings.selectOnboardingFnTapMode(true)
            let view = OnboardingView(model: BridgeAppModel(settings: settings, initialAudioDevices: []),
                permissionOverrides: .allGranted)
            #expect(view.voiceToolBlockingHintKey == "onboarding.voice_tool.trigger_incompatible")
            view.selectFunctionTriggerForVoiceTool()
            #expect(settings.selectedVoiceTrigger.voiceKeyMode == .function)
            #expect(settings.voiceKeyMode == .rightOption)
            #expect(AppSettings(defaults: defaults).voiceKeyMode == .rightOption)
            #expect(settings.stagedVoiceToolBinding?.validationState == .staged)
            #expect(!view.canContinue)
        }
    }

    @Test func unavailableToolsAndUnsupportedShortcutsExplainWhyContinueIsBlocked() throws {
        try withSettings { settings, _ in
            settings.setOnboardingControlSource(.xiaomiRemote)
            settings.setOnboardingStep(.voiceTool)
            settings.setOnboardingVoiceTool(.weixin)
            let view = OnboardingView(model: BridgeAppModel(settings: settings, initialAudioDevices: []),
                voiceToolAvailabilityOverride: [.weixin: .notInstalled], permissionOverrides: .allGranted)
            #expect(!view.canContinue)
            #expect(view.voiceToolBlockingHintKey == "onboarding.voice_tool.install_required")
            settings.setOnboardingVoiceTool(.macosDictation)
            settings.selectOnboardingVoiceTrigger(.rightOption)
            #expect(!view.canContinue)
            #expect(view.voiceToolBlockingHintKey == "onboarding.voice_tool.trigger_incompatible")
        }
    }

    @Test func systemAndWechatConflictsAreSeparateAndDictationKeepsItsSystemBinding() throws {
        try withSettings { settings, _ in
            settings.setOnboardingControlSource(.xiaomiRemote)
            let view = OnboardingView(model: BridgeAppModel(settings: settings, initialAudioDevices: []))
            for tool in [OnboardingVoiceTool.weixin, .typeless, .macosDictation] {
                settings.setOnboardingVoiceTool(tool)
                for mode in [VoiceKeyMode.function, .rightOption] {
                    settings.selectOnboardingVoiceTrigger(mode)
                    let steps = view.inputMethodGuideSteps(for: tool)
                    #expect(Set(steps.map(\.id)).count == steps.count)
                    #expect(!steps.contains { if case .screenshot("weixin-app-shortcuts") = $0.content { return true }; return false })
                    let hasSystemFn = steps.contains { if case .systemFunctionKey = $0.content { return true }; return false }
                    #expect(hasSystemFn == (mode == .function && tool != .macosDictation))
                }
            }
        }
    }

    @Test(arguments: [OnboardingVoiceToolAvailability.notInstalled, .available])
    func chatterflyHoldBannerFollowsInstallationPriority(availability: OnboardingVoiceToolAvailability) async throws {
        let defaults = EphemeralUserDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.voiceFnTapModeEnabled = true
        settings.setOnboardingControlSource(.xiaomiRemote)
        settings.setOnboardingVoiceTool(.chatterfly)
        settings.selectOnboardingFnTapMode(true)
        settings.setOnboardingStep(.voiceTool)
        let probe = OnboardingInteractionProbe(openURL: { _ in })
        let view = OnboardingView(
            model: BridgeAppModel(settings: settings, initialAudioDevices: []),
            allowsInputSourceSwitching: false,
            allowsHardwareMonitoring: false,
            systemFunctionKeyAvailableOverride: true,
            voiceToolAvailabilityOverride: [.chatterfly: availability],
            interactionProbe: probe,
            permissionOverrides: .allGranted
        )
        #expect(view.voiceToolBlockingHintKey == (availability == .available
            ? "onboarding.voice_tool.hold_required" : "onboarding.voice_tool.install_required"))
        let controller = NSHostingController(rootView: view
            .environmentObject(LocalizationStore(settings: settings)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 850),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        try await waitForTestCondition("voice tool page registers controls") {
            probe.actions["continue"] != nil && probe.actions["voice-tool.chatterfly.website"] != nil
        }
        #expect((probe.actions["voice-tool.enable-hold"] != nil) == (availability == .available))
        if availability == .notInstalled {
            probe.invoke("voice-tool.enable-hold")
            #expect(settings.selectedVoiceTrigger.voiceFnTapModeEnabled)
            #expect(settings.voiceFnTapModeEnabled)
            #expect(view.proposedPairingPlan == nil)
        }
    }

    @Test func chatterflyRequiresExplicitHoldModeAndShowsSetupGuide() throws {
        try withSettings { settings, _ in
            settings.setOnboardingControlSource(.xiaomiRemote)
            settings.setOnboardingVoiceTool(.chatterfly)
            settings.selectOnboardingFnTapMode(true)
            settings.selectOnboardingVoiceTrigger(.suggestedShortcut)
            let view = OnboardingView(model: BridgeAppModel(settings: settings, initialAudioDevices: []),
                voiceToolAvailabilityOverride: [.chatterfly: .available])
            #expect(view.voiceToolRequiresHoldConfirmation)
            #expect(view.voiceToolBlockingHintKey == "onboarding.voice_tool.hold_required")
            #expect(view.proposedPairingPlan == nil)
            #expect(settings.selectedVoiceTrigger.voiceFnTapModeEnabled)
            settings.selectOnboardingFnTapMode(false)
            #expect(!view.voiceToolRequiresHoldConfirmation)
            let plan = try #require(view.proposedPairingPlan)
            #expect(plan.binding.gestureMode == .hold)
            #expect(plan.binding.shortcut == .suggestedShortcut)
            #expect(!plan.fnTapModeEnabled)
            #expect(view.voiceToolBlockingHintKey == "onboarding.voice_tool.guide.continue_hint")
            let steps = view.inputMethodGuideSteps(for: .chatterfly)
            #expect(Set(steps.map(\.id)).count == steps.count)
            #expect(steps.contains { if case .screenshot("chatterfly-settings") = $0.content { return true }; return false })
        }
    }

    @Test func selectingATapOnlyToolDoesNotSilentlyChangeTheSelectedMode() throws {
        try withSettings { settings, _ in
            settings.setOnboardingControlSource(.xiaomiRemote)
            settings.setOnboardingVoiceTool(.typeless)
            settings.selectOnboardingFnTapMode(false)
            let view = OnboardingView(model: BridgeAppModel(settings: settings, initialAudioDevices: []))
            #expect(view.voiceToolRequiresTapConfirmation)
            #expect(view.proposedPairingPlan == nil)
            #expect(!settings.selectedVoiceTrigger.voiceFnTapModeEnabled)
            settings.selectOnboardingFnTapMode(true)
            #expect(!view.voiceToolRequiresTapConfirmation)
            let plan = try #require(view.proposedPairingPlan)
            #expect(plan.fnTapModeEnabled)
            #expect(!settings.voiceFnTapModeEnabled)
        }
    }

    @Test func tapToolsUseTheSelectedChordAndDictationKeepsItsSpecificSystemSequence() throws {
        for tool in [OnboardingVoiceTool.bageshuo, .typeless] {
            let plan = try #require(OnboardingVoicePairingPlan.resolve(tool: tool, controlSource: .xiaomiRemote,
                selectedShortcut: .suggestedShortcut))
            #expect(plan.binding.shortcut == .suggestedShortcut)
            #expect(plan.fnTapModeEnabled)
        }
        #expect(OnboardingVoicePairingPlan.resolve(tool: .macosDictation, controlSource: .xiaomiRemote,
            selectedShortcut: .suggestedShortcut) == nil)
    }

    @Test func optionTapModeIsOnlyCommittedWithTheVerifiedBinding() throws {
        try withSettings { settings, _ in
            settings.voiceKeyMode = .rightOption
            settings.setOnboardingControlSource(.xiaomiRemote)
            settings.setOnboardingVoiceTool(.weixin)
            settings.selectOnboardingFnTapMode(true)
            #expect(!settings.voiceFnTapModeEnabled)
            let view = OnboardingView(model: BridgeAppModel(settings: settings, initialAudioDevices: []))
            let plan = try #require(view.proposedPairingPlan)
            #expect(plan.binding.shortcut == .rightOption)
            #expect(plan.fnTapModeEnabled)
            settings.beginOnboardingVoiceTrial(plan)
            settings.setOnboardingStep(.voiceTest)
            #expect(settings.effectiveVoiceFnTapModeEnabled)
            #expect(!settings.voiceFnTapModeEnabled)
            view.continueFlow() // No real transcript was observed, so this cannot commit.
            #expect(!settings.voiceFnTapModeEnabled)
            #expect(settings.verifiedVoiceToolBinding == nil)
            settings.verifyOnboardingVoiceBinding()
            #expect(settings.voiceFnTapModeEnabled)
            #expect(settings.voiceKeyMode == .rightOption)
        }
    }

    @Test func testStatusWaitsForRecordingToEndBeforeWaitingForText() {
        func key(started: Bool, samples: Bool, ended: Bool, result: FirstUseVoiceAttemptResult = .none) -> String {
            OnboardingView.voiceTestStatusKey(toolReady: true, manualInput: false, result: result,
                sessionStarted: started, samplesReceived: samples, sessionEnded: ended)
        }
        #expect(key(started: false, samples: false, ended: false) == "onboarding.voice_test.waiting_voice")
        #expect(key(started: true, samples: true, ended: false) == "onboarding.voice_test.receiving")
        #expect(key(started: true, samples: true, ended: true) == "onboarding.voice_test.waiting_text")
        #expect(key(started: true, samples: true, ended: true, result: .passed) == "onboarding.voice_test.success")
        #expect(OnboardingView.voiceTestStatusKey(toolReady: true, manualInput: false, result: .passed,
            sessionStarted: true, samplesReceived: true, sessionEnded: true, nonTextConfirmed: true) == "onboarding.voice_test.success_non_text")
        #expect(key(started: true, samples: true, ended: true, result: .audioDeliveryFailed) == "onboarding.recovery.voice.audio_delivery_failed.title")
    }

    @Test @MainActor func externalToolNoCommitRecoveryDetailDynamicallyReflectsConfiguredShortcutAndTool() throws {
        try withSettings { settings, _ in
            let view = OnboardingView(model: BridgeAppModel(settings: settings, initialAudioDevices: []))

            // 1. zh-Hans with Doubao and default suggested shortcut (Ctrl + Shift + R)
            settings.applicationLanguage = .simplifiedChinese
            settings.setOnboardingVoiceTool(.doubao)
            settings.selectOnboardingVoiceTrigger(.suggestedShortcut)
            var loc = LocalizationStore(settings: settings, resourceBundle: RemoteBuddyResourceBundle.mainOrDevelopment)
            var detail = view.recoveryDetailText(for: .voiceExternalToolNoCommit, using: loc)
            #expect(detail.contains("豆包输入法"))
            #expect(detail.contains("Remote Buddy Mic"))
            #expect(detail.contains("Ctrl (⌃) + Shift (⇧) + R"))
            #expect(!detail.contains("%1$@"))
            #expect(!detail.contains("%2$@"))
            #expect(!detail.contains("%3$@"))
            #expect(!detail.contains("%@"))

            // 2. English with WeType
            settings.applicationLanguage = .english
            settings.setOnboardingVoiceTool(.weixin)
            loc = LocalizationStore(settings: settings, resourceBundle: RemoteBuddyResourceBundle.mainOrDevelopment)
            detail = view.recoveryDetailText(for: .voiceExternalToolNoCommit, using: loc)
            #expect(detail.contains("WeType"))
            #expect(detail.contains("Remote Buddy Mic"))
            #expect(detail.contains("Ctrl (⌃) + Shift (⇧) + R"))
            #expect(!detail.contains("%1$@"))
            #expect(!detail.contains("%2$@"))
            #expect(!detail.contains("%3$@"))
            #expect(!detail.contains("%@"))

            // 3. Modifier mode (.function)
            settings.applicationLanguage = .simplifiedChinese
            settings.selectOnboardingVoiceTrigger(.function)
            loc = LocalizationStore(settings: settings, resourceBundle: RemoteBuddyResourceBundle.mainOrDevelopment)
            detail = view.recoveryDetailText(for: .voiceExternalToolNoCommit, using: loc)
            #expect(detail.contains("Fn/地球键"))
            #expect(!detail.contains("%@"))

            // 4. Custom shortcut
            let custom = VoiceKeyMode.shortcut(CustomKeyboardShortcut(
                keyCode: 9, modifierFlags: [.control, .option], keyLabel: "V"
            ))
            settings.selectOnboardingVoiceTrigger(custom)
            detail = view.recoveryDetailText(for: .voiceExternalToolNoCommit, using: loc)
            #expect(detail.contains("Ctrl (⌃) + Option (⌥) + V"))
            #expect(!detail.contains("%@"))
        }
    }

    @Test func voiceChordsUseWordsSymbolsAndPlusSeparators() throws {
        try withSettings { settings, _ in
            for language in [AppLanguage.simplifiedChinese, .english] {
                settings.applicationLanguage = language
                let localization = LocalizationStore(settings: settings, resourceBundle: RemoteBuddyResourceBundle.mainOrDevelopment)
                let mode = VoiceKeyMode.shortcut(CustomKeyboardShortcut(keyCode: 9,
                    modifierFlags: [.control, .option], keyLabel: "V"))
                #expect(mode.displayName(using: localization) == "Ctrl (⌃) + Option (⌥) + V")
            }
        }
    }

    @Test func voiceShortcutPresetsMatchTheSupportedMenuChoices() {
        let expected: [NSEvent.ModifierFlags] = [[.control, .shift], [.control, .option], [.control, .command]]
        let chords: [VoiceKeyMode] = [(UInt16(15), "R"), (UInt16(9), "V")].flatMap { keyCode, label in
            expected.map { .shortcut(CustomKeyboardShortcut(keyCode: keyCode, modifierFlags: $0, keyLabel: label)) }
        }
        #expect(VoiceKeyMode.suggestedShortcut == .shortcut(CustomKeyboardShortcut(
            keyCode: 15, modifierFlags: [.control, .shift], keyLabel: "R"
        )))
        #expect(VoiceKeyMode.shortcutPresets == chords)
        #expect(VoiceKeyMode.allCases == [.function, .rightOption, .rightCommand] + chords)
        #expect(VoiceKeyMode.allCases.count == 9)
        #expect(Set(VoiceKeyMode.allCases).count == 9)
        #expect(!VoiceKeyMode.allCases.contains(.leftCommand))
        #expect(!VoiceKeyMode.allCases.contains(.leftOption))
        for preset in VoiceKeyMode.allCases {
            #expect(VoiceTriggerPicker.menuChoices(for: preset) == VoiceKeyMode.allCases)
        }
        let custom = VoiceKeyMode.shortcut(CustomKeyboardShortcut(
            keyCode: 40, modifierFlags: [.command, .option], keyLabel: "K"
        ))
        for nonPreset in [VoiceKeyMode.leftCommand, .leftOption, custom] {
            #expect(VoiceTriggerPicker.menuChoices(for: nonPreset) == VoiceKeyMode.allCases + [nonPreset])
        }
    }

    @Test func customTriggersRoundTripInSettingsAndBindings() throws {
        for mode in VoiceKeyMode.allCases + [.shortcut(CustomKeyboardShortcut(
            keyCode: 40, modifierFlags: [.command, .option], keyLabel: "K"))] {
            #expect(VoiceKeyMode(rawValue: mode.rawValue) == mode)
            #expect(try JSONDecoder().decode(VoiceKeyMode.self, from: JSONEncoder().encode(mode)) == mode)
        }
        #expect(VoiceKeyMode(rawValue: "shortcut:9:0") == nil)
        #expect(VoiceKeyMode(rawValue: "shortcut:65535:917504") == nil)
    }

    @Test func integrationAlwaysSelectsTheTriggerBeforeToolSetupAndKeepsExistingValues() throws {
        try withSettings { settings, _ in
            let profile = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
            settings.selectRemoteProfile(profile)
            settings.voiceKeyMode = .rightOption
            settings.completeOnboarding()
            SettingsPageBehavior.beginIntegrationSetup(tool: .typeless, settings: settings)
            #expect(settings.onboardingStep == .voiceTrigger)
            #expect(settings.voiceKeyMode == .rightOption)
            #expect(!settings.voiceFnTapModeEnabled)
            #expect(OnboardingPurpose.integration.previousStep(before: .voiceTrigger) == nil)
            #expect(OnboardingPurpose.integration.nextStep(after: .voiceTrigger) == .voiceTool)
        }
    }

    @Test func freshSettingsDefaultToCtrlShiftRInsteadOfFn() throws {
        try withSettings { settings, _ in
            let expected = VoiceKeyMode.shortcut(CustomKeyboardShortcut(
                keyCode: 15, modifierFlags: [.control, .shift], keyLabel: "R"
            ))
            #expect(VoiceKeyMode.suggestedShortcut == expected)
            #expect(settings.voiceKeyMode == expected)
            #expect(settings.selectedVoiceTrigger.voiceKeyMode == expected)
        }
    }

    @Test func shortcutGuideScreenshotsHighlightActiveShortcutAndShowExampleNotice() throws {
        try withSettings { settings, _ in
            settings.setOnboardingControlSource(.xiaomiRemote)
            let view = OnboardingView(model: BridgeAppModel(settings: settings, initialAudioDevices: []))

            for resource in [
                "doubao-settings",
                "weixin-input-settings",
                "bageshuo-settings",
                "chatterfly-settings",
                "voicebuddy-setting-fn",
            ] {
                #expect(OnboardingView.screenshotShortcutNotice(for: resource) == .configureShortcut)
                let callout = try #require(OnboardingView.screenshotShortcutCallout(for: resource))
                #expect(callout.trailingX > 0 && callout.trailingX < 1)
                #expect(callout.centerY > 0 && callout.centerY < 1)
            }
            #expect(OnboardingView.screenshotShortcutNotice(for: "weixin-app-shortcuts") == .conflictCheck)
            #expect(OnboardingView.screenshotShortcutCallout(for: "weixin-app-shortcuts") == nil)
            for nonShortcutResource in [
                "doubao-menu",
                "weixin-input-menu",
                "weixin-input-microphone",
                "macos-dictation-shortcut",
                "system-fn",
            ] {
                #expect(OnboardingView.screenshotShortcutNotice(for: nonShortcutResource) == nil)
                #expect(OnboardingView.screenshotShortcutCallout(for: nonShortcutResource) == nil)
            }

            let widerContainer = OnboardingView.aspectFitRect(
                imageSize: CGSize(width: 1200, height: 960),
                in: CGSize(width: 408, height: 260)
            )
            #expect(abs(widerContainer.width - 325) < 0.01)
            #expect(abs(widerContainer.height - 260) < 0.01)
            #expect(abs(widerContainer.minX - 41.5) < 0.01)
            #expect(widerContainer.minY == 0)

            let tallerContainer = OnboardingView.aspectFitRect(
                imageSize: CGSize(width: 1400, height: 1400),
                in: CGSize(width: 200, height: 300)
            )
            #expect(tallerContainer == CGRect(x: 0, y: 50, width: 200, height: 200))

            let zhSettings = AppSettings(defaults: EphemeralUserDefaults())
            zhSettings.applicationLanguage = .simplifiedChinese
            let zhStore = LocalizationStore(settings: zhSettings)
            let enSettings = AppSettings(defaults: EphemeralUserDefaults())
            enSettings.applicationLanguage = .english
            let enStore = LocalizationStore(settings: enSettings)

            let shortcutCaptionKey = "onboarding.voice_tool.guide.screenshot.weixin_input_settings"
            for tool in OnboardingVoiceTool.allCases {
                settings.setOnboardingVoiceTool(tool)
                settings.selectOnboardingVoiceTrigger(.function)
                let fnSteps = view.inputMethodGuideSteps(for: tool)
                settings.selectOnboardingVoiceTrigger(.suggestedShortcut)
                let chordSteps = view.inputMethodGuideSteps(for: tool)

                #expect(fnSteps.count == chordSteps.count || settings.selectedVoiceTrigger.voiceKeyMode != .function)
                for step in chordSteps {
                    guard case let .screenshot(resourceName) = step.content else { continue }
                    let key = "onboarding.voice_tool.guide.screenshot." +
                        resourceName.replacingOccurrences(of: "-", with: "_")
                    for store in [zhStore, enStore] {
                        let fnCaption = LocalizedMessage(
                            key,
                            arguments: [VoiceKeyMode.function.displayName(using: store), store.text("onboarding.gesture.hold")]
                        ).text(using: store)
                        let chordCaption = LocalizedMessage(
                            key,
                            arguments: [VoiceKeyMode.suggestedShortcut.displayName(using: store), store.text("onboarding.gesture.hold")]
                        ).text(using: store)
                        if fnCaption != chordCaption {
                            #expect(OnboardingView.screenshotShortcutNotice(for: resourceName) == .configureShortcut)
                            #expect(OnboardingView.screenshotShortcutCallout(for: resourceName) != nil)
                        }
                    }
                }
            }

            for store in [zhStore, enStore] {
                #expect(!store.text("onboarding.voice_tool.guide.screenshot.example_badge").isEmpty)
                for notice in [
                    OnboardingGuideScreenshotShortcutNotice.configureShortcut,
                    .conflictCheck,
                ] {
                    let localizedNotice = LocalizedMessage(
                        notice.localizationKey,
                        arguments: ["Ctrl (^) + Shift (⇧) + R", "Hold"]
                    ).text(using: store)
                    #expect(localizedNotice.contains("Ctrl (^) + Shift (⇧) + R"))
                }
            }

            let shortcut = "Ctrl (^) + Shift (⇧) + R"
            let sampleCaption = LocalizedMessage(shortcutCaptionKey, arguments: [shortcut, "按住说话"])
                .text(using: zhStore)
            let highlighted = OnboardingView.highlightedGuideText(
                sampleCaption,
                highlighting: shortcut,
                fontSize: 12
            )
            #expect(String(highlighted.characters) == sampleCaption)
            let styledRuns = highlighted.runs.filter { $0.foregroundColor == .red }
            #expect(styledRuns.count == 1)
            for run in highlighted.runs {
                let runText = String(highlighted[run.range].characters)
                if runText == shortcut {
                    #expect(run.foregroundColor == .red)
                    #expect(run.font == .system(size: 12, weight: .bold))
                } else {
                    #expect(run.foregroundColor == nil)
                    #expect(run.font == nil)
                }
            }

            let unchanged = OnboardingView.highlightedGuideText(sampleCaption, highlighting: "")
            #expect(String(unchanged.characters) == sampleCaption)
            #expect(unchanged.runs.allSatisfy { $0.foregroundColor == nil && $0.font == nil })
        }
    }
}

@Suite("Held voice shortcuts")
struct HeldVoiceShortcutTests {
    private var shortcut: CustomKeyboardShortcut {
        CustomKeyboardShortcut(keyCode: 9, modifierFlags: [.control, .shift, .option], keyLabel: "V")
    }

    @Test func publicVoiceKeyEntryDispatchesChordsToTheHeldShortcutSession() {
        let session = HeldVoiceShortcut()
        let mode = VoiceKeyMode.shortcut(CustomKeyboardShortcut(keyCode: 9,
            modifierFlags: [.control, .option], keyLabel: "V"))
        var edges: [(UInt16, Bool)] = []
        let post: KeyboardInjector.KeyStatePoster = { code, down, _ in edges.append((code, down)); return true }
        for down in [true, false] {
            #expect(KeyboardInjector.setVoiceKeyPressed(mode, isPressed: down,
                accessibilityTrusted: { true }, keyStatePoster: { _, _, _ in
                    Issue.record("A chord must use the held-shortcut path"); return false
                }, secureInputEnabled: { false }, shortcutSession: session,
                shortcutKeyStatePoster: post, shortcutHardwareFlags: { [] }))
        }
        #expect(edges.map(\.0) == [59, 58, 9, 9, 58, 59])
        #expect(edges.map(\.1) == [true, true, true, false, false, false])
    }

    @Test func failedStartRecoveryUsesBoundedBackoffAndReleasesOnlyItsOwnedKeys() {
        let clock = ControlledTestScheduler()
        let session = HeldVoiceShortcut()
        var canRelease = false
        var physical: CGEventFlags = []
        var releases: [(UInt16, CGEventFlags)] = []
        let post: KeyboardInjector.KeyStatePoster = { code, down, flags in
            if down { return code != 9 }
            releases.append((code, flags))
            return canRelease
        }
        #expect(!session.setPressed(true, shortcut: shortcut, post: post,
            hardwareFlags: { physical }, schedule: clock.voiceSchedule))
        #expect(clock.tasks.map(\.delay) == [50])
        physical = ShortcutEventSequence.modifierFlags(for: 54)
        canRelease = true
        releases.removeAll()
        clock.runAll()
        #expect(releases.map(\.0) == [9, 56, 58, 59])
        #expect(releases.allSatisfy { $0.1.contains(.maskCommand) })
        #expect(!releases.contains { $0.0 == 54 })
        #expect(clock.activeCount == 0)
        var oldSessionPosts = 0
        #expect(session.setPressed(false, shortcut: shortcut, post: { _, _, _ in oldSessionPosts += 1; return true }))
        #expect(oldSessionPosts == 0)
    }

    @Test func failedStartRecoveryStopsAfterEightScheduledAttempts() {
        let clock = ControlledTestScheduler()
        let session = HeldVoiceShortcut()
        var canRelease = false
        let post: KeyboardInjector.KeyStatePoster = { code, down, _ in down ? code != 9 : canRelease }
        #expect(!session.setPressed(true, shortcut: shortcut, post: post,
            hardwareFlags: { [] }, schedule: clock.voiceSchedule))
        clock.runAll()
        #expect(clock.tasks.map(\.delay) == [50, 100, 200, 400, 800, 1000, 1000, 1000])
        #expect(clock.activeCount == 0)
        canRelease = true
        #expect(session.setPressed(false, shortcut: shortcut, post: post))
    }

    @Test func voiceChordsReachHIDListenersAndKeepTheComposedFlagsThroughRelease() throws {
        var events: [CGEvent] = []
        var locations: [CGEventTapLocation] = []
        let post: (CGEventTapLocation, CGEvent) -> Void = { location, event in
            locations.append(location)
            events.append(event)
        }
        let chord: CGEventFlags = [.maskControl, .maskShift]
        #expect(KeyboardInjector.postVoiceShortcutState(code: 59, isDown: true,
            flags: .maskControl, eventPoster: post))
        #expect(KeyboardInjector.postVoiceShortcutState(code: 56, isDown: true,
            flags: chord, eventPoster: post))
        #expect(KeyboardInjector.postVoiceShortcutState(code: 9, isDown: true,
            flags: chord, eventPoster: post))
        #expect(KeyboardInjector.postVoiceShortcutState(code: 9, isDown: false,
            flags: chord, eventPoster: post))
        #expect(KeyboardInjector.postVoiceShortcutState(code: 56, isDown: false,
            flags: .maskControl, eventPoster: post))
        #expect(KeyboardInjector.postVoiceShortcutState(code: 59, isDown: false,
            flags: [], eventPoster: post))
        #expect(locations == Array(repeating: .cghidEventTap, count: 6))
        #expect(events.map(\.type) == [.flagsChanged, .flagsChanged, .keyDown, .keyUp, .flagsChanged, .flagsChanged])
        #expect(events.map(\.flags) == [.maskControl, chord, chord, chord, .maskControl, []])
        #expect(events.allSatisfy {
            $0.getIntegerValueField(.eventSourceUserData) == KeyboardInjector.orderedVoiceEventMarker &&
                $0.getIntegerValueField(.eventSourceStateID) != Int64(CGEventSourceStateID.hidSystemState.rawValue)
        })
    }

    @Test func chordStaysPressedUntilReleaseAndReleasesInReverseOrder() {
        let session = HeldVoiceShortcut()
        var edges: [(UInt16, Bool, CGEventFlags)] = []
        let post: KeyboardInjector.KeyStatePoster = { edges.append(($0, $1, $2)); return true }
        #expect(session.setPressed(true, shortcut: shortcut, post: post, hardwareFlags: { [] }))
        #expect(edges.map(\.0) == [59, 58, 56, 9])
        #expect(edges.allSatisfy { $0.1 })
        #expect(edges.last?.2.contains([.maskControl, .maskShift, .maskAlternate]) == true)
        #expect(session.setPressed(true, shortcut: shortcut, post: post, hardwareFlags: { [] }))
        #expect(edges.count == 4)
        #expect(session.setPressed(false, shortcut: shortcut, post: post, hardwareFlags: { [] }))
        #expect(edges.map(\.0) == [59, 58, 56, 9, 9, 56, 58, 59])
        #expect(edges.suffix(4).allSatisfy { !$0.1 })
        #expect(edges.last?.2.isEmpty == true)
    }

    @Test(arguments: [false, true])
    func hidSnapshotsDoNotReintroduceOwnedModifiersDuringRelease(laggingSnapshot: Bool) {
        let session = HeldVoiceShortcut()
        let chord = CustomKeyboardShortcut(keyCode: 9, modifierFlags: [.control, .shift], keyLabel: "V")
        var observed: CGEventFlags = []
        var events: [(UInt16, Bool, CGEventFlags)] = []
        let post: KeyboardInjector.KeyStatePoster = { code, down, flags in
            events.append((code, down, flags))
            if down || !laggingSnapshot { observed = flags }
            return true
        }
        #expect(session.setPressed(true, shortcut: chord, post: post, hardwareFlags: { observed }))
        #expect(session.setPressed(false, shortcut: chord, post: post))
        #expect(events.map(\.0) == [59, 56, 9, 9, 56, 59])
        #expect(events[3].2.contains([.maskControl, .maskShift]))
        #expect(events[4].2.contains(.maskControl))
        #expect(!events[4].2.contains(.maskShift))
        #expect(events[5].2.isEmpty)
    }

    @Test func oppositePhysicalModifierRemainsHeldWhileOwnedSideReleases() {
        let session = HeldVoiceShortcut()
        let chord = CustomKeyboardShortcut(keyCode: 9, modifierFlags: [.control], keyLabel: "V")
        var observed: CGEventFlags = []
        var lastFlags: CGEventFlags = []
        let post: KeyboardInjector.KeyStatePoster = { _, _, flags in
            observed = flags
            lastFlags = flags
            return true
        }
        #expect(session.setPressed(true, shortcut: chord, post: post, hardwareFlags: { observed }))
        // The user presses right Control while synthetic left Control is held.
        observed.formUnion(CGEventFlags(rawValue: 0x2000))
        #expect(session.setPressed(false, shortcut: chord, post: post))
        #expect(lastFlags.contains(.maskControl))
        #expect(lastFlags.contains(CGEventFlags(rawValue: 0x2000)))
        #expect(!lastFlags.contains(CGEventFlags(rawValue: 0x0001)))
    }

    @Test func physicalModifiersAreNotAcquiredAndRemainSetDuringCleanup() {
        let session = HeldVoiceShortcut()
        var physical: CGEventFlags = .maskAlternate
        var edges: [(UInt16, Bool, CGEventFlags)] = []
        let post: KeyboardInjector.KeyStatePoster = { edges.append(($0, $1, $2)); return true }
        #expect(session.setPressed(true, shortcut: shortcut, post: post, hardwareFlags: { physical }))
        #expect(edges.map(\.0) == [59, 56, 9])
        physical.formUnion(.maskCommand)
        #expect(session.setPressed(false, shortcut: shortcut, post: post))
        #expect(edges.last?.2.contains([.maskAlternate, .maskCommand]) == true)
        #expect(!edges.contains { $0.0 == 58 })
    }

    @Test func failedMainKeyPressCleansUpEveryAttemptedKey() {
        let session = HeldVoiceShortcut()
        var edges: [(UInt16, Bool)] = []
        let post: KeyboardInjector.KeyStatePoster = { code, down, _ in
            edges.append((code, down)); return !(code == 9 && down)
        }
        #expect(!session.setPressed(true, shortcut: shortcut, post: post, hardwareFlags: { [] }))
        #expect(edges.suffix(4).map(\.0) == [9, 56, 58, 59])
        #expect(edges.suffix(4).allSatisfy { !$0.1 })
    }

    @Test func failedReleaseIsRetriedBeforeAnotherChordCanAcquireKeys() {
        let session = HeldVoiceShortcut()
        var failRelease = true
        var downs = 0
        let post: KeyboardInjector.KeyStatePoster = { _, down, _ in
            if down { downs += 1 }; return down || !failRelease
        }
        #expect(session.setPressed(true, shortcut: shortcut, post: post, hardwareFlags: { [] }))
        #expect(!session.setPressed(false, shortcut: shortcut, post: post))
        #expect(!session.setPressed(true, shortcut: shortcut, post: post, hardwareFlags: { [] }))
        #expect(downs == 4)
        failRelease = false
        #expect(session.setPressed(false, shortcut: shortcut, post: post))
    }
    @Test func tapConversionClicksTheWholeSelectedChordAtBothSessionEdges() {
        let clock = ControlledTestScheduler()
        let keys = HeldVoiceShortcut()
        var edges: [(UInt16, Bool)] = []
        let post: KeyboardInjector.KeyStatePoster = { code, down, _ in edges.append((code, down)); return true }
        let session = VoiceFnTapSessionController(schedule: clock.voiceSchedule,
            setTriggerPressed: { down in keys.setPressed(down, shortcut: shortcut, post: post, hardwareFlags: { [] }) },
            enqueueAudio: { _ in }, drainAudio: { _, done in done() }, onFailure: { _ in Issue.record("Tap failed") })
        session.setEnabled(true)
        #expect(session.startVoice())
        clock.runAll()
        #expect(edges.map(\.0) == [59, 58, 56, 9, 9, 56, 58, 59])
        #expect(session.stopVoice())
        clock.runAll()
        #expect(edges.map(\.0) == Array(repeating: [59, 58, 56, 9, 9, 56, 58, 59], count: 2).flatMap { $0 })
        #expect(session.phase == .idle)
    }

    @Test func tapTriggerRetainsItsShortcutUntilCleanupCompletes() {
        var selected = VoiceKeyMode.suggestedShortcut
        var posted: [(VoiceKeyMode, Bool)] = []
        let trigger = VoiceTapTrigger(selectedMode: { selected }, setKey: { posted.append(($0, $1)); return true })
        #expect(trigger.setPressed(true))
        selected = .rightOption
        #expect(trigger.setPressed(false))
        #expect(trigger.setPressed(true))
        #expect(trigger.setPressed(false))
        #expect(posted.allSatisfy { $0.0 == .suggestedShortcut })
        trigger.reset()
        #expect(trigger.setPressed(true))
        #expect(posted.last?.0 == .rightOption)
        #expect(trigger.setPressed(false))
    }

    @Test func consecutiveVoiceSessionsStillSendEveryModifierWhenHIDSnapshotLags() {
        let session = HeldVoiceShortcut()
        let chord = CustomKeyboardShortcut(keyCode: 9, modifierFlags: [.control, .command], keyLabel: "V")
        var observed: CGEventFlags = []
        var sequences: [[(UInt16, Bool)]] = []
        var current: [(UInt16, Bool)] = []
        var now: TimeInterval = 100
        let post: KeyboardInjector.KeyStatePoster = { code, down, flags in
            current.append((code, down))
            if down { observed = flags }
            return true
        }
        for _ in 0..<4 {
            current = []
            #expect(session.setPressed(true, shortcut: chord, post: post,
                hardwareFlags: { observed }, uptime: { now }))
            #expect(session.setPressed(false, shortcut: chord, post: post))
            sequences.append(current)
            now += 2
        }
        let expected: [(UInt16, Bool)] = [(59, true), (55, true), (9, true), (9, false), (55, false), (59, false)]
        for seq in sequences {
            #expect(seq.map(\.0) == expected.map(\.0))
            #expect(seq.map(\.1) == expected.map(\.1))
        }
    }

    @Test func voiceShortcutPolicyClearsStaleHIDModifiersWithoutPhysicalKeysAndStripsInternalBits() {
        let polluted = CGEventFlags(rawValue: 0x2014_0109) // 0x20000000 | Control | Command | 0x100 | 0x0001 | 0x0008
        #expect(KeyboardHardwareModifierPolicy.voiceShortcutNormalized(polluted, heldKeys: []) == [])
        let shiftOnly = KeyboardHardwareModifierPolicy.voiceShortcutNormalized(
            polluted.union(.maskShift), heldKeys: [60]
        )
        #expect(shiftOnly == .maskShift)
    }

    @Test func voiceKeyEventsStripNonCoalescedAndQuartzInternalFlags() throws {
        let polluted = CGEventFlags(rawValue: 0x2000_0100)
        for mode in [VoiceKeyMode.function, .rightOption] {
            let down = try #require(KeyboardInjector.makeMarkedKeyEvent(
                code: mode.keyCode, isDown: true, flags: mode.eventFlags,
                marker: KeyboardInjector.orderedVoiceEventMarker,
                hardwareFlags: { polluted }
            ))
            #expect(down.flags == mode.eventFlags)
            let up = try #require(KeyboardInjector.makeMarkedKeyEvent(
                code: mode.keyCode, isDown: false, flags: [],
                marker: KeyboardInjector.orderedVoiceEventMarker,
                hardwareFlags: { polluted.union(ShortcutEventSequence.modifierFlags(for: mode.keyCode)) }
            ))
            #expect(up.flags == [])
        }
    }

}
