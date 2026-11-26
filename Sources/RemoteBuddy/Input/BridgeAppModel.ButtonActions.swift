import AppKit
import AVFoundation
import Combine
import CoreAudio
import CoreBluetooth
import Foundation

extension BridgeAppModel {
    func performExternalConfiguredAction(_ configured: ConfiguredButtonAction) -> Bool {
        guard !audio.suspensionState.isSuspended else { return false }
        let applicationProfile = settings.customApplicationProfile(
            id: configured.applicationProfileID
        )
        if configured.action == .openCustomApplication {
            guard let profile = applicationProfile,
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: profile.bundleIdentifier) != nil
            else { return false }
        }
        let sendAction: (UInt64?) -> Bool = { [weak self] requestID in
            guard let self else { return false }
            let handled = KeyboardInjector.send(
                configured.action,
                shortcut: configured.shortcut,
                applicationProfile: applicationProfile,
                urlString: configured.urlString,
                focusInputCompletion: { [weak self] succeeded in
                    guard let requestID else { return }
                    if Thread.isMainThread {
                        MainActor.assumeIsolated {
                            self?.voiceInputDestinationCoordinator.completeFocusOperation(
                                requestID: requestID, succeeded: succeeded)
                        }
                    } else {
                        DispatchQueue.main.async { [weak self] in
                            self?.voiceInputDestinationCoordinator.completeFocusOperation(
                                requestID: requestID, succeeded: succeeded)
                        }
                    }
                }
            )
            if !handled, let requestID {
                self.voiceInputDestinationCoordinator.cancel(requestID: requestID, reason: .actionFailed)
            }
            return handled
        }
        if settings.effectiveVoiceFnTapModeEnabled,
           let intent = VoiceInputDestinationIntent.resolve(configured: configured, applicationProfile: applicationProfile) {
            voiceInputDestinationCoordinator.beginTargetSwitch(intent: intent) { requestID in
                _ = sendAction(requestID)
            }
            return true
        }
        return sendAction(nil)
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
