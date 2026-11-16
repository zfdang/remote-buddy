import AppKit
import Combine
import CoreBluetooth
import SwiftUI

extension OnboardingView {
    func copyDiagnosticSummary() {
        guard interactionProbe == nil else { diagnosticCopySucceeded = true; return }
        var diagnosticVoiceAttempt = voiceAttempt
        diagnosticVoiceAttempt.audioDelivery = model.voiceAudioDeliveryDiagnosticSnapshot()
        let snapshot = FirstUseDiagnosticSnapshot(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            systemMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            architecture: FirstUseDiagnosticSnapshot.architecture,
            voiceTool: settings.onboardingVoiceTool,
            voiceKeyMode: settings.effectiveVoiceKeyMode,
            voiceFnTapModeEnabled: settings.effectiveVoiceFnTapModeEnabled,
            context: diagnosticContext,
            voiceAttempt: diagnosticVoiceAttempt,
            bluetoothStatus: model.connectionStatus.key,
            buttonStatus: model.hidStatus.key,
            audioStatus: model.audioStatus.key,
            events: settings.firstUseEvents,
            appLanguage: localization.locale.identifier,
            controlSource: settings.onboardingControlSource,
            voiceBinding: settings.stagedVoiceToolBinding ?? settings.verifiedVoiceToolBinding
        )
        NSPasteboard.general.clearContents()
        diagnosticCopySucceeded = NSPasteboard.general.setString(snapshot.redactedText, forType: .string)
        AppLogger.shared.write(
            "ONBOARDING DIAGNOSTICS copied step=\(settings.onboardingStep.rawValue) " +
                "failure=\(failureReason?.rawValue ?? "none")"
        )
        AppLogger.shared.writeDiagnosticSummary(
            snapshot.redactedText,
            event: "ONBOARDING DIAGNOSTICS"
        )
    }

    func recoverRemoteConnectionIfNeeded() {
        guard settings.onboardingControlMethod == .physicalRemote else { return }
        guard OnboardingFlowPolicy.shouldRequestRemoteReconnect(
            remoteConnected: model.isConnected,
            remoteButtonObserved: !observedRemoteButtons.isEmpty,
            recoveryRequested: requestedRemoteConnectionRecovery
        ) else { return }
        requestedRemoteConnectionRecovery = true
        model.reconnect()
    }

    func recordRemoteVoiceButtonPress() {
        remoteInputDiagnostic.recordVoiceButtonPress()
        AppLogger.shared.write(
            "ONBOARDING REMOTE_INPUT observed=voice " +
                "source=\(model.activeVoiceSource?.rawValue ?? "unknown") " +
                "voice_count=\(remoteInputDiagnostic.voiceButtonPressCount) " +
                "control_count=\(remoteInputDiagnostic.controlButtonObservationCount) " +
                "last_input=\(remoteInputDiagnostic.lastInputKind.rawValue)"
        )
    }

    func recordRemoteControlButtons(_ buttons: Set<RemoteButton>, source: String) {
        let newlyObserved = buttons.subtracting(observedRemoteButtons)
        guard !newlyObserved.isEmpty else { return }
        observedRemoteButtons.formUnion(newlyObserved)
        for _ in newlyObserved {
            remoteInputDiagnostic.recordControlButtonObservation()
        }
        AppLogger.shared.write(
            "ONBOARDING REMOTE_INPUT observed=control source=\(source) " +
                "new_count=\(newlyObserved.count) " +
                "voice_count=\(remoteInputDiagnostic.voiceButtonPressCount) " +
                "control_count=\(remoteInputDiagnostic.controlButtonObservationCount) " +
                "last_input=\(remoteInputDiagnostic.lastInputKind.rawValue)"
        )
    }

    func handleObservedRemoteButtons(_ buttons: Set<RemoteButton>) {
        guard settings.onboardingControlMethod == .physicalRemote,
              selectedPhysicalRemoteProfileMatchesSource,
              !buttons.isEmpty else { return }
        if settings.onboardingControlSource == .chromecastRemote {
            handleChromecastObservedButtons(buttons)
            return
        }
        if settings.onboardingStep == .remote {
            recordRemoteControlButtons(buttons, source: "physical_remote")
            recoverRemoteConnectionIfNeeded()
        } else if settings.onboardingStep == .controls {
            testedControlButtons.formUnion(buttons)
        }
    }

    func handleObservedRemoteButtonPress(_ button: RemoteButton) {
        guard settings.onboardingControlMethod == .physicalRemote,
              selectedPhysicalRemoteProfileMatchesSource else { return }
        // Chromecast uses the simultaneous button-set callback to separate single-key
        // support from two-key combos; ignore individual key fallbacks for multi-key reports.
        if settings.onboardingControlSource == .chromecastRemote {
            guard model.activeRemoteButtons.count <= 1 else { return }
            handleChromecastObservedButtons(Set([button]))
            return
        }
        if settings.onboardingStep == .remote {
            recordRemoteControlButtons(Set([button]), source: "physical_remote")
            recoverRemoteConnectionIfNeeded()
        } else if settings.onboardingStep == .controls {
            testedControlButtons.insert(button)
        }
    }

    private func handleChromecastObservedButtons(_ buttons: Set<RemoteButton>) {
        let outcome = ChromecastCompatibilityDetection.evaluate(
            step: settings.onboardingStep,
            buttons: buttons,
            singleKeyObserved: chromecastSingleKeyObserved,
            compatibilityModeEnabled: isChromecastTwoKeyCompatible
        )
        switch outcome {
        case let .recordFullMode(observed):
            if observed.count == 1 {
                chromecastSingleKeyObserved = true
                chromecastTwoKeyDetectedWithoutSingleKey = false
                pendingChromecastComboButtons.removeAll()
                if isChromecastTwoKeyCompatible {
                    model.setG9N9NInputMode(.full, for: settings.selectedRemoteProfileID)
                }
            }
            recordRemoteControlButtons(observed, source: "physical_remote")
            recoverRemoteConnectionIfNeeded()
        case let .recordCompatibilityMode(observed):
            recordRemoteControlButtons(observed, source: "physical_remote")
            recoverRemoteConnectionIfNeeded()
        case let .awaitCompatibilityOptIn(observed):
            chromecastTwoKeyDetectedWithoutSingleKey = true
            pendingChromecastComboButtons = observed
            AppLogger.shared.write(
                "ONBOARDING REMOTE_INPUT observed=chromecast_combo_awaiting_opt_in count=\(observed.count)"
            )
        case let .controlsChordConfirmed(observed):
            testedControlButtons.formUnion(observed)
            compatibleChordConfirmed = true
        case let .controlsNonChordObserved(observed):
            testedControlButtons.formUnion(observed)
        }
    }

    func setChromecastPartialSupportMode(_ enabled: Bool) {
        let mode: G9N9NInputMode = enabled ? .twoKeyCompatibility : .full
        model.setG9N9NInputMode(mode, for: settings.selectedRemoteProfileID)
        if enabled {
            if !pendingChromecastComboButtons.isEmpty {
                let promoted = pendingChromecastComboButtons
                pendingChromecastComboButtons.removeAll()
                recordRemoteControlButtons(promoted, source: "physical_remote")
                recoverRemoteConnectionIfNeeded()
            }
        } else {
            chromecastSingleKeyObserved = false
            chromecastTwoKeyDetectedWithoutSingleKey = false
            pendingChromecastComboButtons.removeAll()
            observedRemoteButtons.removeAll()
            testedControlButtons.removeAll()
            compatibleChordConfirmed = false
            remoteInputDiagnostic = remoteInputDiagnosticOverride ?? FirstUseRemoteInputDiagnostic()
        }
        DispatchQueue.main.async {
            recordFailureTransition(failureReason)
        }
    }

    func prepareSelectedControlConnection() {
        guard allowsHardwareMonitoring else { return }
        switch settings.onboardingControlSource {
        case .xiaomiRemote, .t1Remote, .chromecastRemote:
            model.refreshRemoteDiscovery()
            model.applyHIDSettings()
        case .siriRemote:
            model.applyHIDSettings()
        case .unselected:
            break
        }
    }

    func routeConnectedPhysicalRemoteIfNeeded() {
        let suppressForUserBack = suppressConnectedPhysicalRemoteAutoRouteOnce
        suppressConnectedPhysicalRemoteAutoRouteOnce = false
        guard !suppressForUserBack,
              settings.onboardingStep == .remoteAvailability,
              settings.onboardingDevice == nil,
              settings.onboardingControlSource == .unselected,
              model.isOnboardingControlSourceConnected(.xiaomiRemote) else { return }
        // Keep the control-device page visible so the user can see and confirm the
        // selected hardware; an existing connection only preselects the card.
        selectControlSource(.xiaomiRemote)
        AppLogger.shared.write(
            "ONBOARDING CONTROL_SOURCE preselected=xiaomi_remote reason=connected_physical_remote"
        )
    }

    func selectedControlAccepts(_ source: RemoteInputSource) -> Bool {
        switch settings.onboardingControlMethod {
        case .physicalRemote, .unselected:
            return false
        }
    }

    func selectedControlAcceptsVoice(_ source: RemoteInputSource?) -> Bool {
        switch settings.onboardingControlSource {
        case .xiaomiRemote, .t1Remote, .siriRemote, .chromecastRemote:
            return source == .bluetoothRemote &&
                (model.activePhysicalVoiceControlSource.map { $0 == settings.onboardingControlSource }
                    ?? selectedPhysicalRemoteProfileMatchesSource)
        case .unselected:
            return false
        }
    }

    var selectedPhysicalRemoteProfileMatchesSource: Bool {
        guard let model = settings.selectedRemoteProfile?.model else { return false }
        switch settings.onboardingControlSource {
        case .xiaomiRemote:
            return !model.usesPrivateAdapter && !model.isATVVRemote
        case .t1Remote:
            return model.isT1Remote
        case .siriRemote:
            guard model.isAppleSiriRemote else { return false }
            guard let generation = settings.onboardingAppleRemoteGeneration else { return true }
            return model == generation.model
        case .chromecastRemote:
            return model.isChromecastRemote
        case .unselected:
            return false
        }
    }
}
