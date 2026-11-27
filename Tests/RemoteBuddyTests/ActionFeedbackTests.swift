import AppKit
import CoreGraphics
import Foundation
import os
import Testing
@testable import RemoteBuddy

@Suite("Action feedback HUD and visibility settings")
struct ActionFeedbackTests {
    @MainActor
    private func makeStrings(language: AppLanguage = .english) throws -> (ActionFeedbackStrings, () -> Void) {
        let suite = "action-feedback-strings-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults)
        settings.applicationLanguage = language
        return (
            ActionFeedbackStrings(localization: LocalizationStore(settings: settings)),
            { defaults.removePersistentDomain(forName: suite) }
        )
    }

    @Test @MainActor func successMergesRepeatsAndMultipleActionsWithinWindow() throws {
        var now = Date(timeIntervalSince1970: 1_000)
        var logs: [String] = []
        let center = ActionFeedbackCenter(
            now: { now },
            successDuration: 1.3,
            failureDuration: 12,
            mergeWindow: 2,
            log: { logs.append($0) },
            pasteboardWriter: { _ in }
        )
        let (strings, cleanup) = try makeStrings()
        defer { cleanup() }

        center.record(
            ActionFeedbackEvent(
                operationID: "op-1",
                actionID: "screenshot",
                actionName: "Screenshot",
                result: .success,
                elapsedMilliseconds: 4
            ),
            strings: strings
        )
        #expect(center.presentation?.kind == .success)
        #expect(center.presentation?.title.contains("Screenshot") == true)
        #expect(center.presentation?.count == 1)

        // Repeat same action within window appends count.
        now = now.addingTimeInterval(0.4)
        center.record(
            ActionFeedbackEvent(
                operationID: "op-2",
                actionID: "screenshot",
                actionName: "Screenshot",
                result: .success,
                elapsedMilliseconds: 3
            ),
            strings: strings
        )
        #expect(center.presentation?.count == 2)
        #expect(center.presentation?.title.contains("2") == true)

        // Different action within window merges into multi-action summary.
        now = now.addingTimeInterval(0.3)
        center.record(
            ActionFeedbackEvent(
                operationID: "op-3",
                actionID: "spotlight",
                actionName: "Spotlight",
                result: .success,
                elapsedMilliseconds: 2
            ),
            strings: strings
        )
        #expect(center.presentation?.count == 3)
        #expect(center.presentation?.title == strings.format(strings.successMultipleFormat, "3"))
        #expect(logs.count == 3)
    }

    @Test @MainActor func failureSuppressesSuccessCopiesRedactedDiagnosticsAndRunsRecoveryActions() throws {
        var now = Date(timeIntervalSince1970: 2_000)
        var copied: [String] = []
        var openedSettings = 0
        var retried = 0
        let center = ActionFeedbackCenter(
            now: { now },
            successDuration: 1.3,
            failureDuration: 12,
            mergeWindow: 2,
            log: { _ in },
            pasteboardWriter: { copied.append($0) }
        )
        center.configureStandardActions(
            openSystemSettings: { openedSettings += 1 },
            reselectAction: {}
        )
        let (strings, cleanup) = try makeStrings()
        defer { cleanup() }

        center.record(
            ActionFeedbackEvent(
                operationID: "op-perm",
                actionID: "commandPaste",
                actionName: "Paste (Secret Title)",
                result: .failure(.permissionDenied),
                elapsedMilliseconds: 12
            ),
            strings: strings
        )
        #expect(center.presentation?.kind == .failure)
        #expect(center.presentation?.action == .openSystemSettings)

        // Subsequent success while a failure is visible is suppressed.
        center.record(
            ActionFeedbackEvent(
                operationID: "op-ok",
                actionID: "spotlight",
                actionName: "Spotlight",
                result: .success,
                elapsedMilliseconds: 2
            ),
            strings: strings
        )
        #expect(center.presentation?.kind == .failure)
        #expect(center.presentation?.operationID == "op-perm")

        // Diagnostics exclude user-sensitive action display names and include Remote Buddy header.
        center.copyDiagnostics()
        #expect(copied.count == 1)
        #expect(copied[0].contains("Remote Buddy "))
        #expect(!copied[0].contains("Paste (Secret Title)"))
        #expect(copied[0].contains("category permission_denied"))
        #expect(center.copiedPresentationID == center.presentation?.id)

        // Performing primary failure recovery dismisses HUD and runs the handler.
        center.perform(.openSystemSettings)
        #expect(openedSettings == 1)
        #expect(center.presentation == nil)

        // Same failure merges within merge window and supports per-event retry handler.
        center.record(
            ActionFeedbackEvent(
                operationID: "op-fail-1",
                actionID: "commandSave",
                actionName: "Save",
                result: .failure(.executionFailed),
                elapsedMilliseconds: 5
            ),
            strings: strings,
            handlers: ActionFeedbackActionHandlers(retry: { retried += 1 })
        )
        now = now.addingTimeInterval(0.5)
        center.record(
            ActionFeedbackEvent(
                operationID: "op-fail-2",
                actionID: "commandSave",
                actionName: "Save",
                result: .failure(.executionFailed),
                elapsedMilliseconds: 6
            ),
            strings: strings,
            handlers: ActionFeedbackActionHandlers(retry: { retried += 1 })
        )
        #expect(center.presentation?.count == 2)
        #expect(center.presentation?.action == .retry)
        center.perform(.retry)
        #expect(retried == 1)
        #expect(center.presentation == nil)
    }

    @Test func layoutAndScreenResolverChooseLargestIntersection() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = ActionFeedbackLayout.origin(visibleFrame: visibleFrame, panelSize: CGSize(width: 300, height: 80))
        #expect(origin.x == 570)
        let expectedBottomY: CGFloat = 17
        #expect(origin.y == expectedBottomY - ActionFeedbackLayout.contentPadding)
        let zeroPaddingOrigin = ActionFeedbackLayout.origin(
            visibleFrame: visibleFrame,
            panelSize: CGSize(width: 300, height: 80),
            contentPadding: 0
        )
        #expect(zeroPaddingOrigin.y == expectedBottomY)

        // Short screen with a Dock inset clamps panel strictly inside visibleFrame.
        let shortFrame = CGRect(x: 0, y: 70, width: 1280, height: 600)
        let shortSize = CGSize(width: 300, height: 120)
        let shortOrigin = ActionFeedbackLayout.origin(
            visibleFrame: shortFrame,
            panelSize: shortSize
        )
        #expect(shortOrigin.y >= shortFrame.minY)
        #expect(shortOrigin.y + shortSize.height <= shortFrame.maxY)

        let screen0 = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let screen1 = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let windowFrame = CGRect(x: 1340, y: 100, width: 600, height: 500)
        #expect(ActionFeedbackScreenResolver.bestScreenIndex(windowFrame: windowFrame, screenFrames: [screen0, screen1]) == 1)
        #expect(ActionFeedbackScreenResolver.bestScreenIndex(windowFrame: windowFrame, screenFrames: []) == nil)
    }

    @Test func actionSuccessFeedbackPolicyExcludesContinuousNavigationControls() {
        #expect(ConfiguredButtonAction(action: .screenshot, shortcut: nil).showsActionSuccessFeedback)
        #expect(ConfiguredButtonAction(action: .openSafari, shortcut: nil).showsActionSuccessFeedback)
        #expect(ConfiguredButtonAction(action: .customShortcut, shortcut: nil).showsActionSuccessFeedback)
        #expect(!ConfiguredButtonAction(action: .disabled, shortcut: nil).showsActionSuccessFeedback)
        #expect(!ConfiguredButtonAction(action: .arrowLeft, shortcut: nil).showsActionSuccessFeedback)
        #expect(!ConfiguredButtonAction(action: .scrollDown, shortcut: nil).showsActionSuccessFeedback)
        #expect(!ConfiguredButtonAction(action: .volumeUp, shortcut: nil).showsActionSuccessFeedback)
        #expect(!ConfiguredButtonAction(action: .appSwitcher, shortcut: nil).showsActionSuccessFeedback)
        #expect(!ConfiguredButtonAction(action: .openCommonPhrases, shortcut: nil).showsActionSuccessFeedback)
    }

    @Test @MainActor func settingsTogglesPersistAndControlActionFeedbackVisibility() throws {
        let suite = "action-feedback-settings-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        #expect(!settings.hideAllActionFeedback)
        #expect(settings.hideSuccessActionFeedback)

        // Default behavior hides discrete action successes while continuing to surface failures.
        let center = ActionFeedbackCenter(now: Date.init, log: { _ in }, pasteboardWriter: { _ in })
        let model = BridgeAppModel(settings: settings, initialAudioDevices: [])
        model.actionFeedbackCenter = center

        var executedCount = 0
        let defaultSuccess = model.performExternalConfiguredAction(
            ConfiguredButtonAction(action: .screenshot, shortcut: nil),
            accessibilityTrusted: { true },
            secureInputEnabled: { false },
            sender: { _, _, _ in
                executedCount += 1
                return true
            }
        )
        #expect(defaultSuccess)
        #expect(executedCount == 1)
        #expect(center.presentation == nil)

        let defaultFailure = model.performExternalConfiguredAction(
            ConfiguredButtonAction(action: .commandPaste, shortcut: nil),
            accessibilityTrusted: { false },
            secureInputEnabled: { false },
            sender: { _, _, _ in true }
        )
        #expect(!defaultFailure)
        #expect(center.presentation?.kind == .failure)
        center.dismiss()

        // Persisting explicit toggle changes survives reload.
        settings.hideSuccessActionFeedback = false
        settings.hideAllActionFeedback = true
        let reloaded = AppSettings(defaults: defaults)
        #expect(!reloaded.hideSuccessActionFeedback)
        #expect(reloaded.hideAllActionFeedback)

        // With hideAllActionFeedback=true, neither success nor failure is presented, yet actions still run.
        let suppressedAll = model.performExternalConfiguredAction(
            ConfiguredButtonAction(action: .commandPaste, shortcut: nil),
            accessibilityTrusted: { false },
            secureInputEnabled: { false },
            sender: { _, _, _ in true }
        )
        #expect(!suppressedAll)
        #expect(center.presentation == nil)

        // With both toggles turned off, discrete action success HUD renders normally.
        settings.hideAllActionFeedback = false
        settings.hideSuccessActionFeedback = false
        let shownSuccess = model.performExternalConfiguredAction(
            ConfiguredButtonAction(action: .screenshot, shortcut: nil),
            accessibilityTrusted: { true },
            secureInputEnabled: { false },
            sender: { _, _, _ in true }
        )
        #expect(shownSuccess)
        #expect(center.presentation?.kind == .success)
    }

    @Test(arguments: [false, true])
    @MainActor func focusInputDefersFeedbackUntilAsyncCompletion(fnTapModeEnabled: Bool) throws {
        let suite = "action-feedback-focus-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.hideAllActionFeedback = false
        settings.hideSuccessActionFeedback = false
        settings.voiceFnTapModeEnabled = fnTapModeEnabled

        var recordedLogs: [String] = []
        let center = ActionFeedbackCenter(
            now: Date.init,
            log: { recordedLogs.append($0) },
            pasteboardWriter: { _ in }
        )
        let model = BridgeAppModel(settings: settings, initialAudioDevices: [])
        model.actionFeedbackCenter = center
        let clock = ControlledTestScheduler()
        model.voiceInputDestinationCoordinator = VoiceInputDestinationCoordinator(
            schedule: clock.voiceSchedule,
            snapshot: {
                VoiceInputDestinationSnapshot(
                    bundleIdentifier: "com.example.editor",
                    role: "AXTextArea",
                    subrole: "",
                    enabled: true,
                    editable: true,
                    protectedContent: false,
                    semanticText: "Editor"
                )
            }
        )

        var capturedCompletion: (@Sendable (Bool) -> Void)?
        let submitted = model.performExternalConfiguredAction(
            ConfiguredButtonAction(action: .focusInput, shortcut: nil),
            accessibilityTrusted: { true },
            secureInputEnabled: { false },
            sender: { _, _, completion in
                capturedCompletion = completion
                return true
            }
        )
        #expect(submitted)
        #expect(capturedCompletion != nil)
        // Must NOT show success prematurely before async focus completion runs.
        #expect(center.presentation == nil)
        #expect(recordedLogs.isEmpty)

        // When async focus completion fails, exactly one failure presentation is recorded.
        capturedCompletion?(false)
        #expect(center.presentation?.kind == .failure)
        #expect(center.presentation?.count == 1)
        #expect(recordedLogs.count == 1)

        // Late second completion does not emit another feedback event.
        capturedCompletion?(true)
        #expect(recordedLogs.count == 1)

        // Async focus completion succeeding records a single success presentation.
        center.dismiss()
        recordedLogs.removeAll()
        var succeededCompletion: (@Sendable (Bool) -> Void)?
        let okSubmitted = model.performExternalConfiguredAction(
            ConfiguredButtonAction(action: .focusInput, shortcut: nil),
            accessibilityTrusted: { true },
            secureInputEnabled: { false },
            sender: { _, _, completion in
                succeededCompletion = completion
                return true
            }
        )
        #expect(okSubmitted)
        #expect(center.presentation == nil)
        succeededCompletion?(true)
        #expect(center.presentation?.kind == .success)
        #expect(recordedLogs.count == 1)

        // Immediate synchronous dispatch failure fails at once without waiting for completion.
        center.dismiss()
        recordedLogs.removeAll()
        var unusedCompletion: (@Sendable (Bool) -> Void)?
        let syncFail = model.performExternalConfiguredAction(
            ConfiguredButtonAction(action: .focusInput, shortcut: nil),
            accessibilityTrusted: { true },
            secureInputEnabled: { false },
            sender: { _, _, completion in
                unusedCompletion = completion
                return false
            }
        )
        #expect(fnTapModeEnabled ? syncFail : !syncFail)
        #expect(center.presentation?.kind == .failure)
        #expect(recordedLogs.count == 1)
        unusedCompletion?(true)
        #expect(recordedLogs.count == 1)
    }

    @Test(arguments: [false, true])
    @MainActor func applicationLaunchesReportMissingTargetsAndAsyncFailures(fnTapModeEnabled: Bool) throws {
        let suite = "action-feedback-apps-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.hideAllActionFeedback = false
        settings.hideSuccessActionFeedback = false
        settings.voiceFnTapModeEnabled = fnTapModeEnabled

        let center = ActionFeedbackCenter(now: Date.init, log: { _ in }, pasteboardWriter: { _ in })
        center.configureStandardActions(openSystemSettings: {}, reselectAction: {})
        let model = BridgeAppModel(settings: settings, initialAudioDevices: [])
        model.actionFeedbackCenter = center
        let clock = ControlledTestScheduler()
        model.voiceInputDestinationCoordinator = VoiceInputDestinationCoordinator(
            schedule: clock.voiceSchedule,
            snapshot: {
                VoiceInputDestinationSnapshot(
                    bundleIdentifier: "com.apple.Safari",
                    role: "AXTextArea",
                    subrole: "",
                    enabled: true,
                    editable: true,
                    protectedContent: false,
                    semanticText: "Search"
                )
            }
        )

        // 1. Uninstalled preset app fails synchronously with target_missing.
        let missingPreset = model.performExternalConfiguredAction(
            ConfiguredButtonAction(action: .openSafari, shortcut: nil),
            presetApplicationURL: { _ in nil }
        )
        #expect(!missingPreset)
        #expect(center.presentation?.kind == .failure)
        #expect(center.presentation?.action == .reselectAction)

        // 2. Installed preset app waits for async opener completion: no premature success.
        center.dismiss()
        let presetCompletion = OSAllocatedUnfairLock<(@Sendable (pid_t?, Error?) -> Void)?>(initialState: nil)
        let presetStarted = model.performExternalConfiguredAction(
            ConfiguredButtonAction(action: .openSafari, shortcut: nil),
            presetApplicationURL: { _ in URL(fileURLWithPath: "/Applications/Safari.app") },
            presetApplicationOpener: { _, _, completion in
                presetCompletion.withLock { $0 = completion }
            }
        )
        #expect(presetStarted)
        let capturedPresetCompletion = presetCompletion.withLock { $0 }
        #expect(capturedPresetCompletion != nil)
        #expect(center.presentation == nil)

        capturedPresetCompletion?(nil, NSError(domain: "LaunchError", code: -1))
        #expect(center.presentation?.kind == .failure)
        #expect(center.presentation?.action == .retry)

        center.dismiss()
        let presetSuccessCompletion = OSAllocatedUnfairLock<(@Sendable (pid_t?, Error?) -> Void)?>(initialState: nil)
        let presetSecondStart = model.performExternalConfiguredAction(
            ConfiguredButtonAction(action: .openSafari, shortcut: nil),
            presetApplicationURL: { _ in URL(fileURLWithPath: "/Applications/Safari.app") },
            presetApplicationOpener: { _, _, completion in
                presetSuccessCompletion.withLock { $0 = completion }
            }
        )
        #expect(presetSecondStart)
        #expect(center.presentation == nil)
        presetSuccessCompletion.withLock { $0 }?(42, nil)
        #expect(center.presentation?.kind == .success)

        // 3. Custom app async opener failure reports failure rather than premature success.
        center.dismiss()
        let profileID = settings.addCustomApplicationProfile(
            CustomApplicationProfile(
                displayName: "CustomApp",
                bundleIdentifier: "com.example.custom",
                applicationPath: "/Applications/CustomApp.app"
            )
        )
        let customCompletion = OSAllocatedUnfairLock<(@Sendable (pid_t?, Error?) -> Void)?>(initialState: nil)
        let customStarted = model.performExternalConfiguredAction(
            ConfiguredButtonAction(
                action: .openCustomApplication,
                shortcut: nil,
                applicationProfileID: profileID
            ),
            customApplicationURL: { _ in URL(fileURLWithPath: "/Applications/CustomApp.app") },
            customApplicationOpener: { _, _, completion in
                customCompletion.withLock { $0 = completion }
            }
        )
        #expect(customStarted)
        #expect(center.presentation == nil)
        customCompletion.withLock { $0 }?(nil, NSError(domain: "LaunchError", code: -2))
        #expect(center.presentation?.kind == .failure)
    }

    @Test @MainActor func coordinatorReusesHostingViewAndSkipsDuplicateVoiceOverOnCopyUpdate() {
        let center = ActionFeedbackCenter(now: Date.init, log: { _ in }, pasteboardWriter: { _ in })
        var announcements: [String] = []
        let coordinator = ActionFeedbackWindowCoordinator(
            center: center,
            preferredVisibleFrame: { CGRect(x: 0, y: 0, width: 1440, height: 900) },
            announce: { _, message in
                announcements.append(message)
            }
        )
        defer { coordinator.stop() }

        let firstID = UUID()
        let firstFailure = ActionFeedbackPresentation(
            id: firstID,
            kind: .failure,
            operationID: "op-1",
            title: "Action failed",
            context: "No accessibility",
            detail: "Enable access",
            action: .retry,
            actionTitle: "Retry",
            copyTitle: "Copy diagnostics",
            copiedTitle: "Copied",
            diagnostics: "diag",
            count: 1,
            announces: true,
            accessibilityAnnouncement: "Error: Action failed",
            errorPrefix: "Error: ",
            closeLabel: "Close"
        )

        coordinator.render(firstFailure, copiedID: nil)
        let initialHost = coordinator.hostingViewForTesting
        #expect(initialHost != nil)
        #expect(announcements == ["Error: Action failed"])

        // Copying and resetting copied badge keeps the exact same NSHostingView and does not re-announce.
        coordinator.render(firstFailure, copiedID: firstID)
        coordinator.render(firstFailure, copiedID: nil)
        #expect(coordinator.hostingViewForTesting === initialHost)
        #expect(announcements == ["Error: Action failed"])

        // A distinct new failure creates a fresh host and announces once.
        let secondFailure = ActionFeedbackPresentation(
            id: UUID(),
            kind: .failure,
            operationID: "op-2",
            title: "Second failure",
            context: "Failed",
            detail: "Retry",
            action: .retry,
            actionTitle: "Retry",
            copyTitle: "Copy diagnostics",
            copiedTitle: "Copied",
            diagnostics: "diag2",
            count: 1,
            announces: true,
            accessibilityAnnouncement: "Error: Second failure",
            errorPrefix: "Error: ",
            closeLabel: "Close"
        )
        coordinator.render(nil, copiedID: nil)
        coordinator.render(secondFailure, copiedID: nil)
        #expect(announcements == ["Error: Action failed", "Error: Second failure"])
    }
}
