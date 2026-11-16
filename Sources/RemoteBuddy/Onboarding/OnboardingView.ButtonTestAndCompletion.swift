import AppKit
import Combine
import CoreBluetooth
import SwiftUI

extension OnboardingView {

    var controlsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            onboardingTitle("onboarding.controls.title")
            Text(verbatim: localization.text(controlsDetailKey))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if shouldShowSecureInputWarning {
                secureInputWarningCard
            }

            if let buttons = displayedControlButtons {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                    spacing: 8
                ) {
                    ForEach(buttons) { button in
                        let tested = testedControlButtons.contains(button)
                        HStack(spacing: 8) {
                            Image(systemName: tested ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(tested ? Color.green : Color.secondary)
                            Text(button.displayName(using: localization))
                                .font(.system(size: 12, weight: tested ? .semibold : .regular))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 38)
                        .background(
                            tested ? Color.green.opacity(0.10) : Color.primary.opacity(0.035),
                            in: RoundedRectangle(cornerRadius: 9)
                        )
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { index in
                        HStack(spacing: 8) {
                            Image(systemName: testedControlButtons.count > index
                                ? "checkmark.circle.fill"
                                : "circle")
                                .foregroundStyle(testedControlButtons.count > index
                                    ? Color.green
                                    : Color.secondary)
                            Text(LocalizedMessage(
                                "onboarding.controls.mobile_slot",
                                arguments: [String(index + 1)]
                            ).text(using: localization))
                            .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .background(
                            Color.primary.opacity(0.035),
                            in: RoundedRectangle(cornerRadius: 9)
                        )
                    }
                }
            }

            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { index in
                    Image(systemName: testedControlButtons.count > index ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(testedControlButtons.count > index ? Color.green : Color.secondary)
                }
                Text(testedControlButtons.count >= 3
                    ? localization.text("onboarding.controls.ready")
                    : LocalizedMessage("onboarding.controls.progress", arguments: [String(min(3, testedControlButtons.count))]).text(using: localization))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
    }

    var physicalRemotePairingKeys: (
        title: String,
        firstStep: String,
        secondStep: String,
        thirdStep: String?
    ) {
        Self.physicalRemotePairingKeys(for: settings.onboardingControlSource)
    }

    static func physicalRemotePairingKeys(
        for source: OnboardingControlSource
    ) -> (title: String, firstStep: String, secondStep: String, thirdStep: String?) {
        switch source {
        case .siriRemote:
            return (
                "onboarding.remote.siri_pairing.title",
                "onboarding.remote.siri_pairing.first",
                "onboarding.remote.siri_pairing.second",
                "onboarding.remote.siri_pairing.third"
            )
        case .chromecastRemote:
            return (
                "onboarding.remote.chromecast_pairing.title",
                "onboarding.remote.chromecast_pairing.first",
                "onboarding.remote.chromecast_pairing.second",
                "onboarding.remote.chromecast_pairing.third"
            )
        case .t1Remote:
            return (
                "onboarding.remote.t1_pairing.title",
                "onboarding.remote.t1_pairing.first",
                "onboarding.remote.t1_pairing.second",
                "onboarding.remote.t1_pairing.third"
            )
        case .xiaomiRemote, .unselected:
            return (
                "onboarding.remote.first_pairing.title",
                "onboarding.remote.first_pairing.wake",
                "onboarding.remote.first_pairing.pair",
                nil
            )
        }
    }

    var controlsDetailKey: String {
        Self.controlsDetailKey(for: settings.onboardingControlSource)
    }

    static func controlsDetailKey(for source: OnboardingControlSource) -> String {
        switch source {
        case .xiaomiRemote:
            return "onboarding.controls.xiaomi.detail"
        case .t1Remote:
            return "onboarding.controls.t1.detail"
        case .siriRemote:
            return "onboarding.controls.siri.detail"
        case .chromecastRemote:
            return "onboarding.controls.chromecast.detail"
        case .unselected:
            return "onboarding.controls.detail"
        }
    }

    private var displayedControlButtons: [RemoteButton]? {
        Self.displayedControlButtons(for: settings.onboardingControlSource)
    }

    static func displayedControlButtons(
        for source: OnboardingControlSource
    ) -> [RemoteButton]? {
        switch source {
        case .xiaomiRemote:
            return RemoteButton.xiaomiCases
        case .t1Remote:
            return [
                .power, .up, .left, .ok, .right, .down,
                .back, .home, .menu, .mute, .volumeUp, .volumeDown,
            ]
        case .siriRemote:
            return [
                .power, .up, .left, .ok, .right, .down,
                .back, .volumeUp, .volumeDown, .tv, .playPause, .mute,
            ]
        case .chromecastRemote:
            return [
                .power, .up, .left, .ok, .right, .down, .back,
                .home, .volumeUp, .volumeDown, .mute, .youtube, .netflix, .input,
            ]
        case .unselected:
            return nil
        }
    }

    private var completionTitleKey: String {
        switch settings.onboardingPurpose {
        case .initialSetup: return "onboarding.complete.title"
        case .addDevice: return "onboarding.add_device.complete.title"
        case .integration: return "onboarding.integration.complete.title"
        }
    }

    var completionSummary: OnboardingCompletionSummary {
        let profile = settings.selectedRemoteProfile
        let name = profile.flatMap { model.systemDeviceName(for: $0) }
            ?? profile.map { localization.text($0.model.localizationKey) }
            ?? settings.onboardingDevice.map { localization.text($0.titleKey) }
            ?? localization.text("onboarding.summary.remote_missing")
        let lastButtonEvent = settings.firstUseEvents.last { event in
            event.step == .controls && [.entered, .passed, .blocked, .retry].contains(event.kind)
        }
        return OnboardingCompletionSummary(purpose: settings.onboardingPurpose,
            remoteName: name, buttonsVerified: testedControlButtons.count >= 3 || lastButtonEvent?.kind == .passed,
            microphoneReady: onboardingAudioReady, voiceKeyMode: settings.voiceKeyMode,
            tapModeEnabled: settings.voiceFnTapModeEnabled, voiceTool: settings.onboardingVoiceTool,
            binding: settings.verifiedVoiceToolBinding)
    }

    var completeContent: some View {
        let summary = completionSummary
        return VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 46))
                .foregroundStyle(Color.green)
            onboardingTitle(completionTitleKey)
            Text(localization.text("onboarding.summary.detail"))
                .font(.system(size: 14))
                .foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                if let name = summary.remoteName {
                    completionSummaryLine("appletvremote.gen4", "onboarding.summary.remote", value: name)
                }
                if let verified = summary.buttonsVerified {
                    completionSummaryLine("button.programmable", "onboarding.summary.buttons",
                        value: localization.text(verified ? "onboarding.summary.passed" : "onboarding.summary.not_tested"))
                }
                if let ready = summary.microphoneReady {
                    completionSummaryLine("mic.fill", "onboarding.side.microphone",
                        value: localization.text(ready ? "common.status.ready" : "onboarding.summary.not_ready"))
                }
                if let mode = summary.voiceKeyMode {
                    completionSummaryLine("keyboard", "connection.voice_key_mode.title", value: mode.displayName(using: localization))
                }
                if let tap = summary.tapModeEnabled {
                    completionSummaryLine("hand.tap", "connection.voice_fn_tap.enabled",
                        value: localization.text(tap ? "common.status.enabled" : "common.status.disabled"))
                }
                if let tool = summary.voiceTool {
                    completionSummaryLine("waveform", "onboarding.step.voiceTool", value: localization.text(tool.titleKey))
                }
                if let verified = summary.voiceVerified {
                    completionSummaryLine("checkmark.bubble", "onboarding.step.voiceTest",
                        value: localization.text(verified ? "onboarding.summary.passed" : "onboarding.summary.not_tested"))
                }
            }
        }
    }

    private func completionSummaryLine(_ icon: String, _ titleKey: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(Color.accentColor).frame(width: 22)
            Text(localization.text(titleKey)).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 13))
    }

    func buttonTroubleshooting(for failure: FirstUseFailureReason) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            onboardingActionButton(id: "button-help.toggle") {
                buttonHelpExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: buttonHelpExpanded ? "chevron.down" : "chevron.right")
                    Text(localization.text("onboarding.button_help.title"))
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(localization.text(buttonHelpExpanded
                ? "onboarding.button_help.expanded" : "onboarding.button_help.collapsed"))
            if buttonHelpExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    Text(localization.text("onboarding.button_help.steps"))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        onboardingActionButton(id: "recovery.\(failure.rawValue)") {
                            performRecovery(for: failure)
                        } label: {
                            Text(localization.text(recoveryActionKey(for: failure)))
                        }
                        .buttonStyle(.bordered)
                        onboardingActionButton(id: "diagnostics.copy") {
                            copyDiagnosticSummary()
                        } label: {
                            Text(localization.text("onboarding.button_help.copy"))
                        }
                        .buttonStyle(.bordered)
                    }
                    diagnosticCopyFeedback
                    if settings.onboardingStep == .remote,
                       let profile = settings.selectedRemoteProfile, selectedControlConnected,
                       BridgeAppModel.canLearnHIDIdentity(model: profile.model, source: settings.onboardingControlSource) {
                        Button(localization.text("remote.hid_binding.open")) { hidBindingProfile = profile }
                            .buttonStyle(.bordered)
                    }
                }
                .padding(.top, 8)
            }
        }
        .id(settings.onboardingStep)
    }

    func recoveryCard(for failure: FirstUseFailureReason) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.orange)
                    .frame(width: 34, height: 34)
                    .background(Color.orange.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(localization.text(recoveryTitleKey(for: failure)))
                        .font(.system(size: 14, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(recoveryDetailText(for: failure))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                onboardingActionButton(id: "recovery.\(failure.rawValue)") {
                    performRecovery(for: failure)
                } label: {
                    Text(localization.text(recoveryActionKey(for: failure)))
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)

                if failure == .permissionDesynced, canOfferPermissionRelaunch {
                    onboardingActionButton(id: "recovery.\(failure.rawValue).restart") {
                        isPermissionRelaunchConfirmationPresented = true
                    } label: {
                        Text(localization.text("permission.desync.action.restart"))
                    }
                    .buttonStyle(.bordered)
                }

                onboardingActionButton(id: "diagnostics.copy") {
                    copyDiagnosticSummary()
                } label: {
                    Text(verbatim: localization.text("onboarding.diagnostics.copy"))
                }
                .buttonStyle(.bordered)
            }
            diagnosticCopyFeedback
        }
        .padding(14)
        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var diagnosticCopyFeedback: some View {
        if let copied = diagnosticCopySucceeded {
            Text(localization.text(copied ? "onboarding.diagnostics.copied" : "onboarding.diagnostics.copy_failed"))
                .font(.caption).foregroundStyle(copied ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    func shouldShowStandaloneRecoveryCard(_ failure: FirstUseFailureReason) -> Bool {
        // The first page owns inline permission and microphone recovery actions.
        if settings.onboardingStep == .permissions && failure != .permissionDesynced { return false }
        if settings.onboardingStep == .remote,
           settings.onboardingControlMethod == .physicalRemote,
           failure == .remoteNotFound {
            return false
        }
        return true
    }

    private func recoveryTitleKey(for failure: FirstUseFailureReason) -> String {
        if failure == .voiceSessionNotEnded, settings.onboardingControlSource == .t1Remote {
            return "onboarding.recovery.voice.session_not_ended.t1_title"
        }
        return "onboarding.recovery.\(failure.rawValue).title"
    }

    private var canOfferPermissionRelaunch: Bool {
        model.canRelaunchApplication && interactionProbe == nil
    }

    private func recoveryActionKey(for failure: FirstUseFailureReason) -> String {
        if failure == .permissionDesynced {
            return "permission.desync.action.open_settings"
        }
        return "onboarding.recovery.\(failure.rawValue).action"
    }

    private func recoveryDetailKey(for failure: FirstUseFailureReason) -> String {
        if failure == .permissionDesynced {
            return canOfferPermissionRelaunch
                ? "onboarding.recovery.permission.desynced.detail.with_restart"
                : "onboarding.recovery.permission.desynced.detail"
        }
        guard failure == .remoteNotFound else {
            return "onboarding.recovery.\(failure.rawValue).detail"
        }
        return Self.remoteNotFoundRecoveryDetailKey(for: settings.onboardingControlSource)
    }

    private func recoveryDetailText(for failure: FirstUseFailureReason) -> String {
        switch failure {
        case .voiceSessionNotStarted:
            return LocalizedMessage(
                "onboarding.recovery.voice.session_not_started.detail",
                arguments: [recoveryVoiceGestureInstruction]
            ).text(using: localization)
        case .voiceNoSamples:
            return LocalizedMessage(
                "onboarding.recovery.voice.no_samples.detail",
                arguments: [recoveryVoiceGestureInstruction]
            ).text(using: localization)
        case .voiceSessionNotEnded:
            return LocalizedMessage(
                "onboarding.recovery.voice.session_not_ended.detail",
                arguments: [recoveryVoiceFinishInstruction]
            ).text(using: localization)
        default:
            return localization.text(recoveryDetailKey(for: failure))
        }
    }

    private var recoveryVoiceGestureInstruction: String {
        if settings.onboardingControlSource == .t1Remote {
            return localization.text("onboarding.recovery.voice.gesture.t1")
        }
        switch effectivePreferredGesture {
        case .hold:
            return localization.text("onboarding.recovery.voice.gesture.hold")
        case .toggle:
            return localization.text("onboarding.recovery.voice.gesture.toggle")
        }
    }

    private var recoveryVoiceFinishInstruction: String {
        if settings.onboardingControlSource == .t1Remote {
            return localization.text("onboarding.recovery.voice.finish.toggle")
        }
        switch effectivePreferredGesture {
        case .hold:
            return localization.text("onboarding.recovery.voice.finish.hold")
        case .toggle:
            return localization.text("onboarding.recovery.voice.finish.toggle")
        }
    }

    static func remoteNotFoundRecoveryDetailKey(for source: OnboardingControlSource) -> String {
        switch source {
        case .xiaomiRemote, .t1Remote, .siriRemote, .chromecastRemote:
            return "onboarding.recovery.remote.not_found.physical_detail"
        case .unselected:
            return "onboarding.recovery.remote.not_found.detail"
        }
    }
}
