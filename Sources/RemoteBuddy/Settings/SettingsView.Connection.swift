import AppKit
import Combine
import CoreBluetooth
import SwiftUI
import UniformTypeIdentifiers

extension SettingsView {
    var connectionPage: some View {
        settingsPage {
            HStack(spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    PageHeader(title: localization.text("connection.page.title"))
                    Link(destination: AppLinks.devices(for: localization.locale)) {
                        Text(localization.text("connection.action.device_comparison"))
                            .font(.system(size: 13))
                    }
                    .accessibilityIdentifier("connection.device-comparison-link")
                }
                Spacer()
                Button {
                    SettingsPageBehavior.beginDeviceSetup(settings: settings)
                } label: {
                    Label(localization.text("connection.action.add_device"), systemImage: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                }
                .compatibilityButtonStyle(.prominent)
                .controlSize(.large)
                .disabled(model.isStreaming)
            }
        } content: {
            CompatibilityGlassContainer(spacing: 14) {
                let profiles = RemoteDeviceNamePolicy.sortedForCards(settings.remoteDeviceProfiles,
                    modelName: remoteModelName, systemName: { model.systemDeviceName(for: $0) })
                VStack(spacing: 16) {
                    if let runtimeIssue = model.runtimePermissionIssue {
                        runtimePermissionIssuePanel(runtimeIssue)
                    }
                    if profiles.isEmpty {
                        ContentUnavailableView(
                            localization.text("connection.empty.title"),
                            systemImage: "appletvremote.gen4",
                            description: Text(localization.text("connection.empty.detail"))
                        )
                        .frame(maxWidth: .infinity, minHeight: 240)
                    }
                    ForEach(profiles) { profile in
                        connectionDeviceGroup(profile)
                    }
                }
            }
        }
        .confirmationDialog(localization.text("remote.remove.confirm_title"),
                            isPresented: $isRemoteRemovalPresented,
                            presenting: remoteRemovalProfile) { profile in
            Button(localization.text("remote.remove.action"), role: .destructive) {
                _ = model.removeRemoteDevice(profile.id)
                remoteRemovalProfile = nil
            }
            Button(localization.text("common.action.cancel"), role: .cancel) {
                remoteRemovalProfile = nil
            }
        } message: { profile in
            Text(LocalizedMessage("remote.remove.confirm_detail", arguments: [remoteModelName(profile)]).text(using: localization))
        }
        .onAppear {
            model.refreshVoiceKeyCompatibilityWarning()
            if permissionOverrides == nil {
                model.refreshRuntimePermissionDiagnosis(trigger: "settings_connection_appear")
            }
        }
    }

    func voiceKeyCompatibilityWarningPanel(
        _ warning: VoiceKeyCompatibilityWarning
    ) -> some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text(localization.text("connection.voice_key_compatibility.title"))
                        .font(.system(size: 13, weight: .semibold))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }

                Text(LocalizedMessage(warning.messageKey).text(using: localization))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(localization.text("connection.voice_key_compatibility.recheck")) {
                    model.recheckRemoteInput()
                }
                .compatibilityButtonStyle(.standard)
            }
        }
    }

    func runtimePermissionIssuePanel(_ issue: RuntimePermissionIssue) -> some View {
        let canRelaunch = model.canRelaunchApplication
        let titleText: String
        let detailText: String
        switch issue {
        case .permissionDesynced:
            titleText = localization.text("permission.desync.banner.title")
            detailText = localization.text(
                canRelaunch ? "permission.desync.banner.detail.with_restart" : "permission.desync.banner.detail"
            )
        case .bluetoothPermissionDenied:
            titleText = localization.text("onboarding.remote.bluetooth_denied.title")
            detailText = localization.text("onboarding.remote.bluetooth_denied.detail")
        case .inputMonitoringPermissionDenied:
            titleText = localization.text("onboarding.remote.input_not_permitted.title")
            detailText = localization.text("onboarding.remote.input_not_permitted.detail")
        case let .bluetoothUnavailable(statusKey):
            titleText = LocalizedMessage(statusKey).text(using: localization)
            detailText = localization.text("onboarding.remote.bluetooth_unavailable.detail")
        }

        return GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text(titleText)
                        .font(.system(size: 13, weight: .semibold))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }

                Text(detailText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    switch issue {
                    case .permissionDesynced:
                        Button(localization.text("permission.desync.action.open_settings")) {
                            openSettingsURL(issue.preferredPrivacySettingsURLString)
                        }
                        .compatibilityButtonStyle(.prominent)
                        if canRelaunch {
                            Button(localization.text("permission.desync.action.restart")) {
                                isPermissionRelaunchConfirmationPresented = true
                            }
                            .compatibilityButtonStyle(.standard)
                        }
                    case .bluetoothPermissionDenied, .inputMonitoringPermissionDenied:
                        Button(localization.text("permission.action.open_settings")) {
                            openSettingsURL(issue.preferredPrivacySettingsURLString)
                        }
                        .compatibilityButtonStyle(.standard)
                    case .bluetoothUnavailable:
                        Button(localization.text("onboarding.remote.open_bluetooth")) {
                            openSettingsURL(issue.preferredPrivacySettingsURLString)
                        }
                        .compatibilityButtonStyle(.standard)
                    }

                    Button(localization.text("connection.voice_key_compatibility.recheck")) {
                        model.recheckRemoteInput()
                    }
                    .compatibilityButtonStyle(.standard)
                }
            }
        }
    }

    private func connectionDeviceGroup(_ profile: RemoteDeviceProfile) -> some View {
        GlassPanel {
            HStack(alignment: .top, spacing: 24) {
                VStack(spacing: 14) {
                    remoteDeviceCard(profile, fillsWidth: true)
                    connectionRemotePhoto(profile)
                    connectionDeviceActions(profile)
                }.frame(width: 248)
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(localization.text("audio.gain.title")).font(.headline)
                        HStack(spacing: 12) {
                            Slider(value: Binding(get: { settings.gainDB(for: profile.id) },
                                set: { settings.setGainDB($0, for: profile.id) }), in: 0...24, step: 1)
                                .disabled(model.isStreaming)
                            Text("\(Int(settings.gainDB(for: profile.id))) dB")
                                .font(.system(.body, design: .monospaced)).frame(width: 54, alignment: .trailing)
                        }
                        Text(localization.text("audio.gain.help"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if profile.model.isChromecastRemote {
                        let voiceMode = profile.effectiveG9N9NVoiceButtonMode
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .center, spacing: 8) {
                                Text(localization.text("connection.g9n9n.voice_button_mode.title"))
                                    .font(.headline)
                                Spacer(minLength: 12)
                                G9N9NVoiceButtonModeSelector(
                                    selection: settings.g9n9nVoiceButtonMode(for: profile.id),
                                    isDisabled: model.isVoiceConfigurationBusy
                                ) { selectedMode in
                                    settings.setG9N9NVoiceButtonMode(selectedMode, for: profile.id)
                                }
                            }
                            Text(localization.text(
                                voiceMode == .smartToggle
                                    ? "connection.g9n9n.voice_button_mode.smart_toggle_help"
                                    : "connection.g9n9n.voice_button_mode.hold_help"
                            ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    let hardwareInformation = profile.bluetoothIdentifier.flatMap { identifier in
                        let info = model.remoteDeviceInformation[identifier]
                        return (info != nil && info != RemoteDeviceInformation()) ? info : nil
                    }
                    let chromecastSupportMode = profile.model.isChromecastRemote ? profile.effectiveG9N9NInputMode : nil
                    if hardwareInformation != nil || chromecastSupportMode != nil {
                        connectionHardwareCard(
                            information: hardwareInformation,
                            chromecastSupportMode: chromecastSupportMode
                        )
                    }
                    if let usageGuide = ConnectionDeviceUsageGuide.make(for: profile) {
                        ConnectionDeviceUsageSection(guide: usageGuide)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
            }
        }
    }

    private func connectionHardwareCard(
        information: RemoteDeviceInformation?,
        chromecastSupportMode: G9N9NInputMode?
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let information {
                connectionDeviceInformation(information)
            }
            if let information, chromecastSupportMode != nil, !connectionDeviceReadings(information).isEmpty {
                Divider()
            }
            if let chromecastSupportMode {
                g9n9nHardwareSupportSection(for: chromecastSupportMode)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        }
    }

    private func connectionDeviceReadings(_ information: RemoteDeviceInformation) -> [(String, String)] {
        let protocolSummary: String? = switch (information.protocolVersion, information.capabilities) {
        case let (.some(version), .some(capabilities)):
            "\(version) · \(LocalizedMessage("connection.device.frame_bytes", arguments: [String(capabilities.frameSize)]).text(using: localization))"
        case let (.some(version), .none):
            version
        case let (.none, .some(capabilities)):
            LocalizedMessage("connection.device.frame_bytes", arguments: [String(capabilities.frameSize)]).text(using: localization)
        case (.none, .none):
            nil
        }
        let readings: [(String, String?)] = [
            ("connection.device.model", information.modelNumber),
            ("connection.device.identity", information.identityValue),
            ("connection.device.hid_version", information.hidVersionValue),
            ("connection.device.firmware", information.firmwareRevision),
            ("connection.device.protocol", protocolSummary),
            ("connection.device.audio", information.audioFormat),
        ]
        return readings.compactMap { key, value in
            value.map { (key, $0) }
        }
    }

    private func connectionDeviceInformation(_ information: RemoteDeviceInformation) -> some View {
        let available = connectionDeviceReadings(information)
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3),
            alignment: .leading,
            spacing: 10
        ) {
            ForEach(available, id: \.0) { key, value in
                VStack(alignment: .leading, spacing: 2) {
                    Text(localization.text(key))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(value)
                        .font(.system(size: 12, weight: .medium))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .help(value)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func g9n9nHardwareSupportSection(for mode: G9N9NInputMode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                g9n9nSupportBadge(for: mode)
                    .fixedSize()
                Text(localization.text(
                    mode == .twoKeyCompatibility
                        ? "connection.g9n9n.partial_support_notice"
                        : "connection.g9n9n.full_support_notice"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if mode == .twoKeyCompatibility {
                HStack(spacing: 12) {
                    Link(
                        localization.text("connection.g9n9n.compatibility_doc_link"),
                        destination: AppLinks.g9n9nCompatibilityGuide(for: localization.locale)
                    )
                    Link(
                        localization.text("onboarding.chromecast.replace_hardware_link"),
                        destination: AppLinks.devices(for: localization.locale)
                    )
                }
                .font(.caption)
            }
        }
    }

    @ViewBuilder
    private func connectionDeviceActions(_ profile: RemoteDeviceProfile) -> some View {
        VStack(spacing: 8) {
            if SettingsPageBehavior.showsReconnectAction(for: profile) {
                ConnectionActionChipButton(
                    title: localization.text("connection.action.reconnect"),
                    systemImage: "arrow.clockwise",
                    tint: .accentColor,
                    isDisabled: model.isStreaming
                ) {
                    model.selectRemoteProfile(profile.id)
                    model.reconnect()
                }
            }
            ConnectionSubtleDestructiveButton(
                title: localization.text("remote.remove.action"),
                systemImage: "trash",
                isDisabled: model.isVoiceConfigurationBusy
            ) {
                remoteRemovalProfile = profile
                isRemoteRemovalPresented = true
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func connectionRemotePhoto(_ profile: RemoteDeviceProfile) -> some View {
        if let resource = XiaomiRemoteCatalog.photoResource(for: profile.model) {
            RemoteCatalogPhoto(resourceName: resource).frame(width: 82, height: 166)
        } else {
            UnrecognizedRemotePhoto().frame(width: 82, height: 166)
        }
    }

}

private struct ConnectionActionChipButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let isDisabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        let activeHover = isHovered && !isDisabled
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(
                tint.opacity(activeHover ? 0.16 : 0.09),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(tint.opacity(activeHover ? 0.42 : 0.24), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(isDisabled ? 0.45 : 1)
        .disabled(isDisabled)
        .onHover { isHovered = $0 }
    }
}

private struct ConnectionSubtleDestructiveButton: View {
    let title: String
    let systemImage: String
    let isDisabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        let activeHover = isHovered && !isDisabled
        Button(role: .destructive, action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 11))
                Text(title)
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
            .foregroundStyle(activeHover ? Color.red : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                activeHover ? Color.red.opacity(0.08) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(isDisabled ? 0.45 : 1)
        .disabled(isDisabled)
        .onHover { isHovered = $0 }
    }
}
