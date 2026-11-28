import SwiftUI

extension OnboardingView {
    var microphoneSetupContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(localization.text("onboarding.audio.title")).font(.headline)
            Text(verbatim: localization.text("onboarding.audio.detail"))
                .foregroundStyle(.secondary)
            statusCard(icon: "mic.fill", title: BuddyMicrophoneDevicePolicy.deviceName,
                detail: localization.text(microphoneSetupStatusKey),
                isComplete: onboardingAudioReady)
            if microphoneSetupState == .failed {
                Text(microphoneFailureDetail)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if microphoneSetupState == .missing || microphoneSetupState == .failed {
                HStack {
                    Button(localization.text("onboarding.audio.retry")) { prepareAutomaticDriverCheck() }
                    Button(localization.text("audio.compatibility.open_install_guide")) { model.openVirtualMicrophoneSetupInstructions(using: localization) }
                }.buttonStyle(.bordered)
            }
        }
        .onAppear { prepareAutomaticDriverCheck() }
        .onChange(of: model.audioDevices) { _, _ in prepareAutomaticDriverCheck() }
    }

    enum MicrophoneSetupState: String { case missing, preparing, failed, ready }

    static func microphoneSetupState(installed: Bool, ready: Bool, preparing: Bool) -> MicrophoneSetupState {
        if preparing { return .preparing }
        if !installed { return .missing }
        return ready ? .ready : .failed
    }

    var microphoneSetupState: MicrophoneSetupState {
        Self.microphoneSetupState(installed: microphoneDriverInstalled, ready: onboardingAudioReady,
            preparing: microphonePreparationInProgress || model.audio.startupPending || model.audio.activeConfigurationGeneration != nil)
    }

    private var microphoneSetupStatusKey: String { "onboarding.audio.state.\(microphoneSetupState.rawValue)" }

    private var microphoneFailureDetail: String {
        let key = model.audioStatus.key
        if !["audio.output.none_selected", "audio.output.current_format", "audio.compatibility.checking"].contains(key) {
            return model.audioStatus.text(using: localization)
        }
        return localization.text("onboarding.audio.failure_help")
    }

    var voiceTriggerContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            onboardingTitle("onboarding.voice_trigger.title")
            Text(localization.text("onboarding.voice_tool.selected_trigger_help"))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                VoiceTriggerPicker(
                    selection: settings.selectedVoiceTrigger.voiceKeyMode,
                    onSelect: { settings.selectOnboardingVoiceTrigger($0) }
                )
                onboardingLink(
                    id: "voice-trigger.faq",
                    destination: AppLinks.voiceButtonsFAQ(for: localization.locale)
                ) {
                    Text(localization.text("onboarding.voice_trigger.faq_link"))
                        .font(.system(size: 12))
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Toggle(localization.text("connection.voice_fn_tap.enabled"), isOn: Binding(
                    get: { settings.selectedVoiceTrigger.voiceFnTapModeEnabled },
                    set: { settings.selectOnboardingFnTapMode($0) }
                ))
                Text(localization.text("connection.voice_fn_tap.hint_short"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    }
            }
            Text(localization.text("onboarding.voice_trigger.save_hint"))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func prepareAutomaticDriverCheck() {
        guard interactionProbe == nil, !microphonePreparationInProgress else { return }
        microphonePreparationInProgress = true
        model.refreshAudioDevices()
        model.configureVirtualAudioOutput(reason: "onboarding_driver_check") { _ in
            microphonePreparationInProgress = false
        }
    }
}
