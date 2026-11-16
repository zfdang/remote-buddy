import AppKit
import Combine
import CoreBluetooth
import SwiftUI

extension OnboardingView {
    @ViewBuilder
    var remoteContent: some View {
        switch settings.onboardingControlMethod {
        case .physicalRemote:
            physicalRemoteContent
        case .unselected:
            remoteAvailabilityContent
        }
    }

    private func learnSelectedHIDIdentity() {
        guard selectedControlConnected, let profile = settings.selectedRemoteProfile,
              BridgeAppModel.canLearnHIDIdentity(model: profile.model, source: settings.onboardingControlSource) else { return }
        if let bridge = model.selectedBluetoothBridge { model.learnSelectedRemoteHIDIdentity(bridge) }
    }

    private var physicalRemoteContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            onboardingTitle("onboarding.remote.title")
            Text(verbatim: localization.text("onboarding.remote.detail"))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            let profiles = model.onboardingRemoteProfiles
            if !profiles.isEmpty {
                Picker(localization.text("onboarding.remote.choose_device"), selection: Binding(
                    get: { profiles.contains(where: { $0.id == settings.selectedRemoteProfileID }) ? settings.selectedRemoteProfileID : nil },
                    set: { if let id = $0 { model.selectRemoteProfile(id) } }
                )) {
                    Text(localization.text("onboarding.remote.choose_device")).tag(Optional<UUID>.none)
                    ForEach(profiles) { profile in
                        Text(model.systemDeviceName(for: profile) ?? localization.text(profile.model.localizationKey))
                            .tag(Optional(profile.id))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(localization.text(physicalRemotePairingKeys.title))
                    .font(.system(size: 14, weight: .semibold))

                Label {
                    Text(localization.text(physicalRemotePairingKeys.firstStep))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "1.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }

                Label {
                    Text(localization.text(physicalRemotePairingKeys.secondStep))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "2.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }

                if let thirdStep = physicalRemotePairingKeys.thirdStep {
                    Label {
                        Text(localization.text(thirdStep))
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "3.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .font(.system(size: 12))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
            }

            let connectionPresentation = physicalRemoteConnectionStatusPresentation
            statusCard(
                icon: connectionPresentation.icon,
                title: connectionPresentation.title,
                detail: connectionPresentation.detail,
                isComplete: selectedControlConnected,
                pendingColor: connectionPresentation.pendingColor,
                compact: true
            )

            statusCard(
                icon: remoteInputDiagnostic.shouldShowVoiceButtonCorrection
                    ? "exclamationmark.triangle.fill"
                    : chromecastTwoKeyDetectedWithoutSingleKey && !isChromecastTwoKeyCompatible
                        ? "exclamationmark.circle.fill"
                        : observedRemoteButtons.isEmpty
                            ? "button.programmable"
                            : "checkmark.circle.fill",
                title: localization.text(
                    remoteInputDiagnostic.shouldShowVoiceButtonCorrection
                        ? "onboarding.remote.voice_button_mistake.title"
                        : chromecastTwoKeyDetectedWithoutSingleKey && !isChromecastTwoKeyCompatible
                            ? "onboarding.remote.chromecast.combo_needs_opt_in.title"
                            : observedRemoteButtons.isEmpty
                                ? "onboarding.remote.button_waiting"
                                : "onboarding.remote.button_received"
                ),
                detail: physicalRemoteButtonStatusDetail,
                isComplete: !observedRemoteButtons.isEmpty,
                pendingColor: (remoteInputDiagnostic.shouldShowVoiceButtonCorrection ||
                    (chromecastTwoKeyDetectedWithoutSingleKey && !isChromecastTwoKeyCompatible))
                    ? .orange : nil,
                compact: true
            )

            if shouldShowChromecastCompatibilityCard {
                chromecastCompatibilityOptInCard
            }

            if shouldShowSecureInputWarning {
                secureInputWarningCard
            }

            if !selectedControlConnected {
                openBluetoothSettingsButton
            }
        }
        .onAppear {
            model.selectOnboardingRemoteIfNeeded()
            learnSelectedHIDIdentity()
        }
        .onChange(of: settings.selectedRemoteProfileID) { _, _ in learnSelectedHIDIdentity() }
        .onChange(of: selectedControlConnected) { _, connected in
            if connected { learnSelectedHIDIdentity() }
        }
        .onChange(of: model.onboardingRemoteProfiles.map(\.id)) { _, _ in
            model.selectOnboardingRemoteIfNeeded()
        }
    }

    private var physicalRemoteConnectionStatusPresentation: (
        icon: String,
        title: String,
        detail: String,
        pendingColor: Color?
    ) {
        if selectedControlConnected {
            return (
                "checkmark.circle.fill",
                localization.text("onboarding.remote.connected"),
                localization.text("onboarding.remote.connected_detail"),
                nil
            )
        }
        if !observedRemoteButtons.isEmpty {
            return (
                "dot.radiowaves.left.and.right",
                localization.text("onboarding.remote.hid_connected"),
                localization.text("onboarding.remote.hid_connected_detail"),
                nil
            )
        }
        switch model.runtimePermissionIssue {
        case .permissionDesynced:
            let canOfferRelaunch = model.canRelaunchApplication && interactionProbe == nil
            return (
                "exclamationmark.triangle.fill",
                localization.text("onboarding.remote.permission_desync.title"),
                localization.text(
                    canOfferRelaunch
                        ? "onboarding.remote.permission_desync.detail.with_restart"
                        : "onboarding.remote.permission_desync.detail"
                ),
                .orange
            )
        case .bluetoothPermissionDenied:
            return (
                "exclamationmark.triangle.fill",
                localization.text("onboarding.remote.bluetooth_denied.title"),
                localization.text("onboarding.remote.bluetooth_denied.detail"),
                .orange
            )
        case .inputMonitoringPermissionDenied:
            return (
                "exclamationmark.triangle.fill",
                localization.text("onboarding.remote.input_not_permitted.title"),
                localization.text("onboarding.remote.input_not_permitted.detail"),
                .orange
            )
        case let .bluetoothUnavailable(statusKey):
            return (
                "exclamationmark.triangle.fill",
                LocalizedMessage(statusKey).text(using: localization),
                localization.text("onboarding.remote.bluetooth_unavailable.detail"),
                .orange
            )
        case nil:
            return (
                "dot.radiowaves.left.and.right",
                localization.text("onboarding.remote.searching"),
                localization.text("onboarding.remote.searching_detail"),
                nil
            )
        }
    }

    private var physicalRemoteButtonStatusDetail: String {
        if settings.onboardingControlSource == .chromecastRemote {
            if chromecastTwoKeyDetectedWithoutSingleKey && !isChromecastTwoKeyCompatible {
                return localization.text("onboarding.remote.chromecast.combo_needs_opt_in.detail")
            }
            if isChromecastTwoKeyCompatible {
                return localization.text(
                    observedRemoteButtons.isEmpty
                        ? "onboarding.remote.chromecast.compat_waiting_detail"
                        : "onboarding.remote.chromecast.compat_ready_detail"
                )
            }
            if chromecastSingleKeyObserved {
                return localization.text("onboarding.remote.chromecast.full_ready_detail")
            }
            if observedRemoteButtons.isEmpty && !remoteInputDiagnostic.shouldShowVoiceButtonCorrection {
                return localization.text("onboarding.remote.chromecast.single_waiting_detail")
            }
        }
        let instructionKey = remoteInputDiagnostic.shouldShowVoiceButtonCorrection
            ? "onboarding.remote.voice_button_mistake.detail"
            : observedRemoteButtons.isEmpty
                ? "onboarding.remote.button_waiting_detail"
                : "onboarding.remote.button_detail"
        return localization.text(instructionKey)
    }

    private var shouldShowChromecastCompatibilityCard: Bool {
        ChromecastCompatibilityDetection.shouldShowCompatibilityOptInCard(
            step: settings.onboardingStep,
            source: settings.onboardingControlSource,
            singleKeyObserved: chromecastSingleKeyObserved
        )
    }

    private var chromecastCompatibilityOptInCard: some View {
        let highlighted = chromecastTwoKeyDetectedWithoutSingleKey && !isChromecastTwoKeyCompatible
        let tint: Color = highlighted ? .orange : (isChromecastTwoKeyCompatible ? .blue : .secondary)
        return VStack(alignment: .leading, spacing: 10) {
            Text(localization.text(
                highlighted
                    ? "onboarding.remote.chromecast.compat_prompt_highlighted"
                    : "onboarding.remote.chromecast.compat_prompt"
            ))
            .font(.system(size: 12))
            .foregroundStyle(highlighted ? .primary : .secondary)
            .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: Binding(
                get: { isChromecastTwoKeyCompatible },
                set: { setChromecastPartialSupportMode($0) }
            )) {
                Text(localization.text("onboarding.remote.chromecast.compat_checkbox"))
                    .font(.system(size: 13, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("g9n9n-partial-support-toggle")

            if isChromecastTwoKeyCompatible {
                Text(localization.text("onboarding.remote.chromecast.compat_scope_summary"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(localization.text("onboarding.chromecast.replace_hardware_advice"))
                        .foregroundStyle(.secondary)
                    Link(localization.text("onboarding.chromecast.replace_hardware_link"),
                         destination: AppLinks.devices(for: localization.locale))
                }
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            highlighted ? Color.orange.opacity(0.08) : Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(tint.opacity(highlighted ? 0.45 : 0.16), lineWidth: 1)
        }
    }

    var shouldShowSecureInputWarning: Bool {
        OnboardingSecureInputPolicy.shouldShowWarning(
            step: settings.onboardingStep,
            source: settings.onboardingControlSource,
            remoteConnected: selectedControlConnected,
            remoteButtonObserved: settings.onboardingStep == .controls
                ? !testedControlButtons.isEmpty
                : !observedRemoteButtons.isEmpty,
            secureInputActive: secureInputActive,
            waitStartedAtUptime: secureInputWaitStartedAtUptime,
            nowUptime: ProcessInfo.processInfo.systemUptime
        )
    }

    var secureInputWarningCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.orange)
                    .frame(width: 32, height: 32)
                    .background(Color.orange.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: localization.text("onboarding.secure_input.title"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(verbatim: localization.text("onboarding.secure_input.detail"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                onboardingActionButton(id: "secure-input.recheck") {
                    recheckSecureInput()
                } label: {
                    Text(verbatim: localization.text("onboarding.secure_input.recheck"))
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)

                Text(verbatim: localization.text("onboarding.secure_input.help"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
        }
    }

    private var openBluetoothSettingsButton: some View {
        onboardingActionButton(id: "bluetooth.settings.open") {
            openBluetoothSettings()
        } label: {
            Text(verbatim: localization.text("onboarding.remote.open_bluetooth"))
        }
            .buttonStyle(.bordered)
    }
}
