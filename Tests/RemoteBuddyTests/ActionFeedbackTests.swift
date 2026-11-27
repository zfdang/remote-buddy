import CoreGraphics
import Foundation
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
        #expect(origin.y == ActionFeedbackLayout.bubbleBottomInset - ActionFeedbackLayout.contentPadding)

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
        #expect(!settings.hideSuccessActionFeedback)

        settings.hideSuccessActionFeedback = true
        settings.hideAllActionFeedback = true
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.hideSuccessActionFeedback)
        #expect(reloaded.hideAllActionFeedback)

        let center = ActionFeedbackCenter(now: Date.init, log: { _ in }, pasteboardWriter: { _ in })
        let model = BridgeAppModel(settings: settings, initialAudioDevices: [])
        model.actionFeedbackCenter = center

        // With hideAllActionFeedback=true, neither success nor failure is presented, yet actions still run.
        var executedCount = 0
        let ran = model.performExternalConfiguredAction(
            ConfiguredButtonAction(action: .screenshot, shortcut: nil),
            accessibilityTrusted: { true },
            secureInputEnabled: { false },
            sender: { _, _, _ in
                executedCount += 1
                return true
            }
        )
        #expect(ran)
        #expect(executedCount == 1)
        #expect(center.presentation == nil)

        // When only hideSuccessActionFeedback=true, failures still appear and carry permission recovery,
        // while successes stay hidden.
        settings.hideAllActionFeedback = false
        let denied = model.performExternalConfiguredAction(
            ConfiguredButtonAction(action: .commandPaste, shortcut: nil),
            accessibilityTrusted: { false },
            secureInputEnabled: { false },
            sender: { _, _, _ in true }
        )
        #expect(!denied)
        #expect(center.presentation?.kind == .failure)
        center.dismiss()

        let suppressedSuccess = model.performExternalConfiguredAction(
            ConfiguredButtonAction(action: .screenshot, shortcut: nil),
            accessibilityTrusted: { true },
            secureInputEnabled: { false },
            sender: { _, _, _ in true }
        )
        #expect(suppressedSuccess)
        #expect(center.presentation == nil)

        // When both toggles are off, discrete action success HUD renders normally.
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
}
