import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Text of the alert shown after an import.
enum SettingsBackupMessage {
    static let maximumListedItems = 20

    @MainActor
    static func summary(for report: SettingsBackupImportReport, using localization: LocalizationStore) -> String {
        var lines = [format("settings.backup.import.done", report.importedRemoteCount, using: localization)]
        if report.isFromNewerVersion {
            lines.append(localization.text("settings.backup.import.newer_version"))
        }
        if !report.skippedItems.isEmpty {
            lines.append("")
            lines.append(localization.text("settings.backup.import.skipped_header"))
            for item in report.skippedItems.prefix(maximumListedItems) {
                lines.append(String(
                    format: localization.text("settings.backup.import.item"),
                    locale: localization.locale,
                    location(item.location, using: localization),
                    reason(item.reason, using: localization)
                ))
            }
            if report.skippedItems.count > maximumListedItems {
                lines.append(format(
                    "settings.backup.import.more", report.skippedItems.count - maximumListedItems, using: localization
                ))
            }
        }
        if !report.missingApplications.isEmpty {
            lines.append("")
            lines.append(String(
                format: localization.text("settings.backup.import.missing_apps"),
                locale: localization.locale,
                report.missingApplications.joined(separator: ", ")
            ))
        }
        return lines.joined(separator: "\n")
    }

    @MainActor
    private static func format(_ key: String, _ count: Int, using localization: LocalizationStore) -> String {
        String(format: localization.text(key), locale: localization.locale, count)
    }

    @MainActor
    private static func location(_ location: [String], using localization: LocalizationStore) -> String {
        location.enumerated().map { index, segment in
            if index == 0, let model = RemoteModel(rawValue: segment) {
                return localization.text(model.localizationKey)
            }
            if index == 0, segment == "general" {
                return localization.text(SettingsSection.general.titleKey)
            }
            if let button = RemoteButton(rawValue: segment) { return button.displayName(using: localization) }
            if let trigger = ButtonTrigger(rawValue: segment) { return trigger.displayName(using: localization) }
            return segment
        }.joined(separator: " › ")
    }

    @MainActor
    private static func reason(
        _ reason: SettingsBackupImportReport.SkippedItem.Reason,
        using localization: LocalizationStore
    ) -> String {
        switch reason {
        case .unrecognizedValue:
            localization.text("settings.backup.import.reason.unrecognized_value")
        case .remoteModelNotOnThisMac:
            localization.text("settings.backup.import.reason.model_not_on_this_mac")
        case .unknownApplicationReference:
            localization.text("settings.backup.import.reason.unknown_application")
        case .mappingLockedByCompatibilityMode:
            localization.text("settings.backup.import.reason.compatibility_mode")
        }
    }
}

/// The Backup & Restore rows of the General page.
struct SettingsBackupSection: View {
    let settings: AppSettings
    let localization: LocalizationStore
    /// Applies the imported preferences that live outside `AppSettings`, such as the Dock icon.
    let onImported: () -> Void

    @State private var isConfirmingImport = false
    @State private var result: ResultAlert?

    private struct ResultAlert: Identifiable {
        let id = UUID()
        let titleKey: String
        let message: String
    }

    var body: some View {
        VStack(spacing: 0) {
            row(symbol: "square.and.arrow.up", titleKey: "settings.backup.export.title",
                detailKey: "settings.backup.export.help", actionKey: "settings.backup.export.action",
                action: exportSettings)
            Divider()
            row(symbol: "square.and.arrow.down", titleKey: "settings.backup.import.title",
                detailKey: "settings.backup.import.help", actionKey: "settings.backup.import.action") {
                isConfirmingImport = true
            }
            .alert(localization.text("settings.backup.import.confirm_title"), isPresented: $isConfirmingImport) {
                Button(localization.text("settings.backup.import.action")) {
                    // Let the confirmation close before the open panel takes over.
                    DispatchQueue.main.async { importSettings() }
                }
                Button(localization.text("common.action.cancel"), role: .cancel) {}
            } message: {
                Text(localization.text("settings.backup.import.confirm_message"))
            }
        }
        .alert(item: $result) { result in
            Alert(
                title: Text(localization.text(result.titleKey)),
                message: Text(result.message),
                dismissButton: .default(Text(localization.text("common.action.ok")))
            )
        }
    }

    private func row(symbol: String, titleKey: String, detailKey: String, actionKey: String,
                     action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(localization.text(titleKey)).font(.subheadline.weight(.semibold))
                Text(localization.text(detailKey))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 20)
            Button(localization.text(actionKey), action: action)
                .compatibilityButtonStyle(.standard)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()

    private func exportSettings() {
        AppLogger.shared.write("SETTINGS BACKUP EXPORT phase=requested")
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "RemoteBuddy-Settings-\(Self.fileDateFormatter.string(from: Date())).json"
        guard panel.runModal() == .OK, let url = panel.url else {
            AppLogger.shared.write("SETTINGS BACKUP EXPORT phase=completed result=cancelled")
            return
        }
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        do {
            try settings.settingsBackupData(appVersion: appVersion).write(to: url, options: .atomic)
            AppLogger.shared.write("SETTINGS BACKUP EXPORT phase=completed result=written")
        } catch {
            AppLogger.shared.write("SETTINGS BACKUP EXPORT phase=completed result=failed")
            result = ResultAlert(titleKey: "settings.backup.error.title",
                                 message: localization.text("settings.backup.export.failed"))
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let data: Data
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= AppSettings.maximumSettingsBackupBytes else { throw SettingsBackupError.fileTooLarge }
            data = try Data(contentsOf: url)
        } catch SettingsBackupError.fileTooLarge {
            showError("settings.backup.import.too_large")
            return
        } catch {
            showError("settings.backup.import.read_failed")
            return
        }
        do {
            let report = try settings.importSettingsBackup(from: data)
            onImported()
            result = ResultAlert(titleKey: "settings.backup.import.result_title",
                                 message: SettingsBackupMessage.summary(for: report, using: localization))
        } catch SettingsBackupError.fileTooLarge {
            showError("settings.backup.import.too_large")
        } catch {
            showError("settings.backup.import.not_settings_file")
        }
    }

    private func showError(_ messageKey: String) {
        result = ResultAlert(titleKey: "settings.backup.error.title", message: localization.text(messageKey))
    }
}
