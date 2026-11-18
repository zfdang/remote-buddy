import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Voice shortcut configuration")
@MainActor
struct VoiceTriggerConfigurationTests {
    private func withSettings(_ body: (AppSettings, UserDefaults) throws -> Void) throws {
        let name = "voice-trigger-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
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
            #expect(settings.voiceKeyMode == .function)
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
        #expect(key(started: true, samples: true, ended: true, result: .audioDeliveryFailed) == "onboarding.recovery.voice.audio_delivery_failed.title")
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
        let chords: [VoiceKeyMode] = [(UInt16(9), "V"), (UInt16(15), "R")].flatMap { keyCode, label in
            expected.map { .shortcut(CustomKeyboardShortcut(keyCode: keyCode, modifierFlags: $0, keyLabel: label)) }
        }
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

}
