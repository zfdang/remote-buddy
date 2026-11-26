import SwiftUI

struct G9N9NBluetoothLoggingSection: View {
    @ObservedObject var model: BridgeAppModel
    @ObservedObject var settings: AppSettings
    @EnvironmentObject private var localization: LocalizationStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { settings.g9n9nBluetoothLogRecoveryEnabled },
                set: { model.setG9N9NBluetoothLogRecoveryEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(localization.text("g9n9n.btle_log.toggle"))
                        .font(.system(size: 13, weight: .medium))
                    Text(localization.text("g9n9n.btle_log.subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("g9n9n-btle-log-recovery-toggle")

            if settings.g9n9nBluetoothLogRecoveryEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    statusRow

                    if model.btleServerLogRedactedObserved {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(localization.text("g9n9n.btle_log.redacted_warning"))
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    HStack(spacing: 8) {
                        Button(localization.text("g9n9n.btle_log.action.install_profile")) {
                            _ = BluetoothLoggingProfileService.openBundledProfileForInstallation()
                            BluetoothLoggingProfileService.openDeviceManagementSettings()
                        }
                        .compatibilityButtonStyle(.standard)
                        .controlSize(.small)

                        Button(localization.text("g9n9n.btle_log.action.open_device_management")) {
                            BluetoothLoggingProfileService.openDeviceManagementSettings()
                        }
                        .compatibilityButtonStyle(.standard)
                        .controlSize(.small)

                        Button(localization.text("g9n9n.btle_log.action.recheck")) {
                            model.recheckBluetoothLoggingProfile()
                        }
                        .compatibilityButtonStyle(.standard)
                        .controlSize(.small)
                    }

                    Text(localization.text("g9n9n.btle_log.privacy_note"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 20)
                .onAppear {
                    model.refreshBluetoothLoggingProfileStatus()
                }
            }
        }
    }

    private var statusRow: some View {
        let (icon, tint, key): (String, Color, String) = switch model.bluetoothLoggingProfileStatus {
        case .installed:
            ("checkmark.circle.fill", .green, "g9n9n.btle_log.status.installed")
        case .notInstalled:
            ("exclamationmark.circle.fill", .orange, "g9n9n.btle_log.status.not_installed")
        case .unknown:
            ("questionmark.circle", .secondary, "g9n9n.btle_log.status.unknown")
        }
        return HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(localization.text(key))
                .font(.caption.weight(.medium))
                .foregroundStyle(model.bluetoothLoggingProfileStatus == .installed ? .primary : .secondary)
        }
    }
}
