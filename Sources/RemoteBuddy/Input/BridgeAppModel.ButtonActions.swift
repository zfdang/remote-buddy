import AppKit
import AVFoundation
import Combine
import CoreAudio
import CoreBluetooth
import Foundation

extension BridgeAppModel {
    func performExternalConfiguredAction(
        _ configured: ConfiguredButtonAction,
        customApplicationOpener: @escaping KeyboardInjector.CustomApplicationOpener = {
            KeyboardInjector.openCustomApplication(at: $0, application: $1, completion: $2)
        },
        accessibilityTrusted: @escaping () -> Bool = { KeyboardInjector.isAccessibilityTrusted },
        secureInputEnabled: @escaping () -> Bool = SecureInputMonitor.isEnabled,
        sender: ((
            ConfiguredButtonAction,
            CustomApplicationProfile?,
            @escaping @Sendable (Bool) -> Void
        ) -> Bool)? = nil
    ) -> Bool {
        let operationID = UUID().uuidString
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let applicationProfile = settings.customApplicationProfile(
            id: configured.applicationProfileID
        )
        let localization = LocalizationStore(settings: settings)
        let actionName = configured.feedbackDisplayName(
            using: localization,
            customApplicationName: applicationProfile?.displayName
        )
        let feedbackStrings = ActionFeedbackStrings(localization: localization)
        let retryHandler: @MainActor @Sendable () -> Void = { [weak self] in
            _ = self?.performExternalConfiguredAction(
                configured,
                customApplicationOpener: customApplicationOpener,
                accessibilityTrusted: accessibilityTrusted,
                secureInputEnabled: secureInputEnabled,
                sender: sender
            )
        }
        let isAsyncFocusInput = (configured.action == .focusInput)
        let feedbackGate = ActionFeedbackCompletionGate()
        let presentsSuccess = !settings.hideAllActionFeedback
            && !settings.hideSuccessActionFeedback
            && configured.showsActionSuccessFeedback
        let presentsFailure = !settings.hideAllActionFeedback
        let record: @MainActor @Sendable (ActionFeedbackResult, ActionFeedbackActionHandlers?) -> Void = {
            [weak self] result, extraHandlers in
            guard let self, feedbackGate.take() else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            let elapsedMs = Int((now >= startedAt ? now - startedAt : 0) / 1_000_000)
            let handlers = extraHandlers ?? ActionFeedbackActionHandlers(retry: retryHandler)
            let event = ActionFeedbackEvent(
                operationID: operationID,
                actionID: configured.action.rawValue,
                actionName: actionName,
                result: result,
                elapsedMilliseconds: elapsedMs,
                presentsSuccess: presentsSuccess,
                presentsFailure: presentsFailure
            )
            self.actionFeedbackCenter.record(event, strings: feedbackStrings, handlers: handlers)
        }

        guard !audio.suspensionState.isSuspended else {
            record(.failure(.notStarted), nil)
            return false
        }
        if configured.action == .openCustomApplication {
            guard let profile = applicationProfile,
                KeyboardInjector.resolveCustomApplicationURL(profile) != nil
            else {
                record(.failure(.targetMissing), nil)
                return false
            }
        }
        if configured.action == .openURL {
            guard CustomActionURLPolicy.validatedURL(from: configured.urlString) != nil else {
                record(.failure(.configurationUnavailable), nil)
                return false
            }
        }
        if configured.action == .customShortcut, configured.shortcut == nil {
            record(.failure(.configurationUnavailable), nil)
            return false
        }
        if configured.action.requiresNonSecureInput, secureInputEnabled() {
            record(.failure(.shortcutNotDelivered), nil)
            return false
        }
        if configured.action.requiresAccessibilityForAction, !accessibilityTrusted() {
            record(.failure(.permissionDenied), nil)
            return false
        }

        let sendAction: (UInt64?) -> Bool = { [weak self] requestID in
            guard let self else { return false }
            let completion: @Sendable (Bool) -> Void = { [weak self] succeeded in
                let finish: @MainActor @Sendable () -> Void = { [weak self] in
                    if let requestID {
                        self?.voiceInputDestinationCoordinator.completeFocusOperation(
                            requestID: requestID, succeeded: succeeded)
                    }
                    if isAsyncFocusInput {
                        record(succeeded ? .success : .failure(.executionFailed), nil)
                    }
                }
                if Thread.isMainThread {
                    MainActor.assumeIsolated { finish() }
                } else {
                    DispatchQueue.main.async { finish() }
                }
            }
            let handled: Bool
            if let sender {
                handled = sender(configured, applicationProfile, completion)
            } else {
                handled = KeyboardInjector.send(
                    configured.action,
                    shortcut: configured.shortcut,
                    applicationProfile: applicationProfile,
                    customApplicationOpener: customApplicationOpener,
                    urlString: configured.urlString,
                    focusInputCompletion: completion,
                    accessibilityTrusted: accessibilityTrusted,
                    secureInputEnabled: secureInputEnabled
                )
            }
            if !handled, let requestID {
                self.voiceInputDestinationCoordinator.cancel(requestID: requestID, reason: .actionFailed)
            }
            return handled
        }
        if settings.effectiveVoiceFnTapModeEnabled,
           let intent = VoiceInputDestinationIntent.resolve(configured: configured, applicationProfile: applicationProfile) {
            voiceInputDestinationCoordinator.beginTargetSwitch(intent: intent) { [weak self] requestID in
                guard self != nil else { return }
                let ok = sendAction(requestID)
                if !ok {
                    record(.failure(.executionFailed), nil)
                } else if !isAsyncFocusInput {
                    record(.success, nil)
                }
            }
            return true
        }
        let handled = sendAction(nil)
        if !handled {
            let canOpenApp = configured.action.presetApplication != nil || configured.action == .openCustomApplication
            var handlers = ActionFeedbackActionHandlers(retry: retryHandler)
            if canOpenApp {
                handlers.openApplication = retryHandler
            }
            record(.failure(.executionFailed), handlers)
        } else if !isAsyncFocusInput {
            record(.success, nil)
        }
        return handled
    }

    func handleVoiceInputDestinationState(_ state: VoiceInputDestinationState) {
        guard settings.effectiveVoiceFnTapModeEnabled else { return }
        switch state {
        case .waiting:
            voiceShortcutStatus = LocalizedMessage("voice_button.status.waiting_for_input")
        case .ready:
            voiceShortcutStatus = LocalizedMessage("voice_button.status.input_ready")
        case .cancelled:
            voiceShortcutStatus = LocalizedMessage("voice_button.status.input_unavailable")
        }
    }

    static func commonPhraseHIDSource(_ profileID: UUID?) -> String {
        "hid:\(profileID?.uuidString ?? "unassigned")"
    }

    static func commonPhraseProfileID(fromSource source: String) -> UUID? {
        guard source.hasPrefix("hid:") else { return nil }
        return UUID(uuidString: String(source.dropFirst(4)))
    }

    /// The panel source a voice-key press may close: any non-Siri remote's
    /// own panel, and never while long recording owns the microphone.
    static func commonPhraseVoiceKeySource(profile: RemoteDeviceProfile?, longRecordingRequested: Bool) -> String? {
        guard !longRecordingRequested, let profile, !profile.model.isAppleSiriRemote else { return nil }
        return commonPhraseHIDSource(profile.id)
    }

    static func commonPhraseModel(forSource source: String, settings: AppSettings) -> RemoteModel? {
        commonPhraseProfileID(fromSource: source)
            .flatMap { id in settings.remoteDeviceProfiles.first { $0.id == id }?.model }
            ?? settings.selectedRemoteProfile?.model
    }

    func cancelPendingCommonPhraseButtonActions() {
        hidMonitors.values.forEach { $0.cancelPendingButtonActions() }
        discoveryHIDMonitor?.cancelPendingButtonActions()

    }

    @discardableResult
    func performInternalAction(_ action: ButtonAction, source: String = "host_action") -> Bool {
        guard !audio.suspensionState.isSuspended else { return false }
        if action == .openCommonPhrases {
            guard Thread.isMainThread else { return false }
            return MainActor.assumeIsolated {
                commonPhrases.open(
                    source: source,
                    model: Self.commonPhraseModel(forSource: source, settings: settings),
                    localization: LocalizationStore(settings: settings))
            }
        }
        guard action == .toggleLongRecording else { return false }
        return toggleLongRecording()
    }
}
