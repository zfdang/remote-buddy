import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Chooses which application scope the Mapping page edits for the selected remote:
/// either the remote's own default mapping, or overrides for one desktop application.
extension SettingsView {
    var mappingApplicationScopeBar: some View {
        let profiles = settings.sortedApplicationButtonProfiles
        let bundleID = editingApplicationBundleID
        let runningApps = ApplicationButtonProfiles.runningApplications(
            excluding: Set(settings.applicationButtonProfiles.keys)
        )
        return GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    Text(localization.text("button_mapping.app_scope.title"))
                        .font(.system(size: 13, weight: .semibold))
                    Picker("", selection: Binding<String?>(
                        get: { editingApplicationBundleID },
                        set: { selectMappingApplication($0) }
                    )) {
                        Text(localization.text("button_mapping.app_scope.all_apps")).tag(Optional<String>.none)
                        if !profiles.isEmpty { Divider() }
                        ForEach(profiles, id: \.bundleID) { entry in
                            Text(ApplicationButtonProfiles.displayName(
                                bundleID: entry.bundleID,
                                profile: entry.profile
                            ))
                            .tag(Optional(entry.bundleID))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220)
                    .accessibilityIdentifier("mapping.app-scope.picker")

                    Menu {
                        Button {
                            chooseApplicationForMapping()
                        } label: {
                            Label(
                                localization.text("button_mapping.app_scope.choose_other"),
                                systemImage: "folder"
                            )
                        }
                        if !runningApps.isEmpty {
                            Divider()
                            Section(localization.text("button_mapping.app_scope.running_apps")) {
                                ForEach(runningApps, id: \.bundleID) { app in
                                    Button(app.name) {
                                        settings.addApplicationButtonProfile(
                                            bundleID: app.bundleID,
                                            name: app.name
                                        )
                                        selectMappingApplication(app.bundleID)
                                    }
                                }
                            }
                        }
                    } label: {
                        Label(localization.text("button_mapping.app_scope.add"), systemImage: "plus")
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityIdentifier("mapping.app-scope.add")

                    Spacer(minLength: 8)

                    if let bundleID {
                        Button(role: .destructive) {
                            settings.removeApplicationButtonProfile(bundleID: bundleID)
                            selectMappingApplication(nil)
                        } label: {
                            Label(localization.text("button_mapping.app_scope.remove"), systemImage: "trash")
                                .foregroundStyle(.red)
                        }
                        .compatibilityButtonStyle(.standard)
                        .accessibilityIdentifier("mapping.app-scope.remove")
                    }
                }

                if let bundleID {
                    Text(LocalizedMessage(
                        "button_mapping.app_scope.editing_hint",
                        arguments: [ApplicationButtonProfiles.displayName(
                            bundleID: bundleID,
                            profile: settings.applicationButtonProfiles[bundleID]
                        )]
                    ).text(using: localization))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(localization.text("button_mapping.app_scope.all_apps_hint"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    func selectMappingApplication(_ bundleID: String?) {
        mappingApplicationBundleID = bundleID
        mappingEditingTarget = nil
        shortcutCaptureTarget = nil
        applicationShortcutCaptureProfileID = nil
        shortcutCaptureFeedback = nil
        mappingActionFilter = .basicKeys
    }

    private func chooseApplicationForMapping() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = localization.text("button_mapping.app_scope.add")
        guard panel.runModal() == .OK, let url = panel.url,
              let identity = ApplicationButtonProfiles.applicationIdentity(at: url)
        else { return }
        settings.addApplicationButtonProfile(bundleID: identity.bundleID, name: identity.name)
        selectMappingApplication(identity.bundleID)
    }
}
