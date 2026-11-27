import AppKit
import Combine
import CoreBluetooth
import SwiftUI
import UniformTypeIdentifiers

extension SettingsView {
    /// Bundle identifier of the application whose per-app overrides are being edited on the
    /// selected remote, or `nil` when editing the selected remote's default mapping.
    var editingApplicationBundleID: String? {
        guard let bundleID = mappingApplicationBundleID,
              settings.applicationButtonProfiles[bundleID] != nil
        else { return nil }
        return bundleID
    }

    func mappingConfiguration(for button: RemoteButton, trigger: ButtonTrigger) -> ConfiguredButtonAction {
        if let bundleID = editingApplicationBundleID {
            return settings.applicationScopedAction(bundleID: bundleID, button: button, trigger: trigger)
        }
        return settings.configuredBaseAction(for: button, trigger: trigger)
    }

    private func saveMappingBinding(_ configured: ConfiguredButtonAction, button: RemoteButton, trigger: ButtonTrigger) {
        if let bundleID = editingApplicationBundleID {
            settings.setApplicationScopedAction(configured, bundleID: bundleID, button: button, trigger: trigger)
            return
        }
        settings.setBaseBinding(configured, for: button, trigger: trigger, profileID: settings.selectedRemoteProfileID)
    }

    func setMappingAction(_ action: ButtonAction, for button: RemoteButton, trigger: ButtonTrigger) {
        var configured = mappingConfiguration(for: button, trigger: trigger)
        configured.action = action
        saveMappingBinding(configured, button: button, trigger: trigger)
    }

    func setMappingShortcut(_ shortcut: CustomKeyboardShortcut?, for button: RemoteButton, trigger: ButtonTrigger) {
        var configured = mappingConfiguration(for: button, trigger: trigger)
        configured.shortcut = shortcut
        if shortcut != nil { configured.action = .customShortcut }
        saveMappingBinding(configured, button: button, trigger: trigger)
    }

    func setMappingApplicationProfileID(_ id: UUID?, for button: RemoteButton, trigger: ButtonTrigger) {
        var configured = mappingConfiguration(for: button, trigger: trigger)
        configured.applicationProfileID = id
        saveMappingBinding(configured, button: button, trigger: trigger)
    }

    func setMappingURLString(_ urlString: String?, for button: RemoteButton, trigger: ButtonTrigger) {
        var configured = mappingConfiguration(for: button, trigger: trigger)
        configured.urlString = CustomActionURLPolicy.normalizedInput(urlString)
        saveMappingBinding(configured, button: button, trigger: trigger)
    }

    private var isSelectedChromecastBluetoothLogRecovery: Bool {
        settings.selectedRemoteProfile?.model.isChromecastRemote == true &&
            settings.g9n9nInputMode(for: settings.selectedRemoteProfileID) == .bluetoothLogRecovery
    }

    private var mappingPageHeader: some View {
        let model = settings.selectedRemoteProfile?.model
        let subtitleKey = if isSelectedChromecastBluetoothLogRecovery {
            "button_mapping.google.btle_log_subtitle"
        } else if model?.isChromecastRemote == true {
            "button_mapping.google.subtitle"
        } else if model?.isT1Remote == true {
            "button_mapping.t1.subtitle"
        } else {
            "button_mapping.page.subtitle"
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 14) {
                PageHeader(title: localization.text("button_mapping.page.title"))
                mappingHeaderToggle
            }
            Text(localization.text(subtitleKey))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var mappingPage: some View {
        hardwareMappingPage {
            if settings.selectedRemoteProfile?.model.isChromecastRemote == true {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(localization.text("button_mapping.google.version_notice"))
                        .foregroundStyle(.secondary)
                    Link(localization.text("button_mapping.google.device_guide"),
                         destination: AppLinks.devices(for: localization.locale))
                }
                .font(.caption)
            } else if settings.selectedRemoteProfile?.model.isT1Remote == true {
                Text(localization.text("t1.remote.keyboard_airmouse_note"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            RemoteMappingCanvas(
                selectedButton: $selectedRemoteButton,
                activeButtons: model.activeRemoteButtons,
                voiceActive: model.isStreaming,
                actionSummary: { button, trigger in mappingActionSummary(for: button, trigger: trigger) },
                actionHelpSummary: { button, trigger in mappingActionSummary(for: button, trigger: trigger, detailed: true) },
                onEdit: { button, trigger in
                    selectedRemoteButton = button
                    let current = mappingConfiguration(for: button, trigger: trigger).action
                    let validFilters = MappingActionFilter.visibleCases(for: button, trigger: trigger)
                    let targetFilter = MappingActionFilter(category: current.category)
                    mappingActionFilter = (current == .disabled || current == .repeatSingleClick)
                        ? (validFilters.contains(.directPassthrough) && current == .directPassthrough ? .directPassthrough : .basicKeys)
                        : (validFilters.contains(targetFilter) ? targetFilter : .basicKeys)
                    mappingEditingTarget = ShortcutEditingTarget(
                        button: button,
                        trigger: trigger
                    )
                },
                onVoiceSettings: { selectSection(.integration) },
                remoteModel: settings.selectedRemoteProfile?.model ?? .unknown,
                isOverridden: { button, trigger in
                    guard let bundleID = editingApplicationBundleID else { return false }
                    return settings.isApplicationOverride(bundleID: bundleID, button: button, trigger: trigger)
                }
            )
            .onReceive(model.$activeRemoteButtons) { buttons in
                selectedRemoteButton = MappingSelectionPolicy.selection(
                    current: selectedRemoteButton,
                    activeButtons: buttons,
                    isLocked: isMappingSelectionLocked
                )
            }
        }
    }


    private func hardwareMappingPage<HardwareCanvas: View>(
        @ViewBuilder hardwareCanvas: @escaping () -> HardwareCanvas
    ) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                mappingPageHeader
                    .fixedSize(horizontal: true, vertical: false)
                mappingDevicePicker
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 22)
            .padding(.top, 12)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            ScrollViewReader { proxy in
                Group {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 16) {
                            Color.clear
                                .frame(height: 0)
                                .id("mapping-page-top")
                            corruptedSettingsBanner

                            mappingApplicationScopeBar

                            hardwareCanvas()

                            if let target = mappingEditingTarget {
                                mappingEditorPanel(target)
                                    .id("mapping-action-editor")
                            }

                            mappingFooter()
                            if editingApplicationBundleID == nil {
                                mappingResetAllDefaultsSection
                            }
                            Color.clear.frame(height: 1).id("mapping-page-bottom")
                        }
                        .padding(22)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .id(settings.selectedRemoteProfileID)
                    .compatibilityScrollEdgeEffect()
                }
                .onChange(of: settings.selectedRemoteProfileID) { _, _ in
                    // 编辑器与适用应用作用域都属于上一只遥控器；切换设备后重回默认作用域。
                    mappingApplicationBundleID = nil
                    mappingEditingTarget = nil
                    shortcutCaptureTarget = nil
                    applicationShortcutCaptureProfileID = nil
                    shortcutCaptureFeedback = nil
                    mappingActionFilter = .basicKeys
                    DispatchQueue.main.async {
                        proxy.scrollTo("mapping-page-top", anchor: .top)
                    }
                }
                .onAppear {
                    guard mappingEditingTarget != nil else { return }
                    DispatchQueue.main.async {
                        proxy.scrollTo("mapping-action-editor", anchor: .top)
                    }
                }
                .onChange(of: mappingEditingTarget?.id) { _, targetID in
                    guard targetID != nil else { return }
                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo("mapping-action-editor", anchor: .top)
                        }
                    }
                }
            }
        }
    }

    /// Inline on purpose: a sheet or alert here would be dismissed once and never seen again,
    /// and the repository's interface rules keep page-level notices flat inside the page.
    /// Renders nothing at all when no key failed to decode, so a healthy launch keeps its layout.
    @ViewBuilder
    private var corruptedSettingsBanner: some View {
        if let summary = CorruptedSettingsNotice.summary(
            for: settings.corruptedSettingKeys,
            localize: localization.text
        ) {
            GlassPanel {
                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.orange)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(localization.text(CorruptedSettingsNotice.titleKey))
                            .font(.system(size: 12, weight: .semibold))
                        Text(summary)
                            .font(.system(size: 12))
                        Text(localization.text(CorruptedSettingsNotice.recoveryKey))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text(localization.text(CorruptedSettingsNotice.nextStepKey))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var mappingHeaderToggle: some View {
        Toggle(localization.text("button_mapping.toggle.enabled"), isOn: Binding(
            get: { settings.customMappingEnabled },
            set: { setCustomMappingEnabled($0) }
        ))
        .font(.system(size: 14, weight: .medium))
        .toggleStyle(.switch)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func mappingEditorPanel(_ target: ShortcutEditingTarget) -> some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(target.button.displayName(using: localization))
                        .font(.system(size: 18, weight: .semibold))
                    Text(target.trigger.displayName(using: localization))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                    Spacer()
                    if target.trigger != .doubleClick || editingApplicationBundleID != nil {
                        Button {
                            restoreDefaultAction(for: target.button, trigger: target.trigger)
                        } label: {
                            Text(localization.text("button_mapping.action.restore_default"))
                        }
                        .compatibilityButtonStyle(.standard)
                        .help(localization.text("button_mapping.action.restore_default_help"))
                    }

                    Button {
                        saveMappingBinding(.disabled, button: target.button, trigger: target.trigger)
                        shortcutCaptureTarget = nil
                        applicationShortcutCaptureProfileID = nil
                    } label: {
                        Label(localization.text("button_mapping.action.clear"), systemImage:
                            mappingConfiguration(for: target.button, trigger: target.trigger).action == .disabled
                                ? "checkmark.circle.fill" : "circle")
                    }
                    .compatibilityButtonStyle(.standard)
                    .help(localization.text("button_mapping.action.not_set_help"))
                    Button(localization.text("button_mapping.editor.confirm")) {
                        mappingEditingTarget = nil
                        shortcutCaptureTarget = nil
                        applicationShortcutCaptureProfileID = nil
                    }
                    .compatibilityButtonStyle(.standard)
                }

                if mappingConfiguration(for: target.button, trigger: target.trigger).action == .disabled {
                    Text(localization.text("button_mapping.action.not_set_help"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                mappingTriggerEditor(target.button, trigger: target.trigger)
            }
        }
    }

    private func restoreDefaultAction(for button: RemoteButton, trigger: ButtonTrigger) {
        let defaultAction: ConfiguredButtonAction
        if let bundleID = editingApplicationBundleID {
            settings.clearApplicationOverride(bundleID: bundleID, button: button, trigger: trigger)
            defaultAction = settings.configuredBaseAction(for: button, trigger: trigger)
        } else {
            defaultAction = settings.defaultAction(for: button, trigger: trigger)
            saveMappingBinding(defaultAction, button: button, trigger: trigger)
        }
        shortcutCaptureTarget = nil
        applicationShortcutCaptureProfileID = nil
        mappingActionFilter = (defaultAction.action == .disabled || defaultAction.action == .repeatSingleClick)
            ? .basicKeys
            : MappingActionFilter(category: defaultAction.action.category)
    }

    private func mappingFooter() -> some View {
        // 能力一律取自「链路自报优先、型号默认兜底」的判定结果（见 RemoteVoiceCapabilities）。
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                mappingHIDStatus
                Divider()
                HStack {
                    mappingSelectionLockControl
                    Spacer()
                    Button {
                        selectSection(.commonPhrases)
                    } label: {
                        Label(localization.text("common_phrases.adjust"), systemImage: "text.quote")
                    }
                    .compatibilityButtonStyle(.standard)
                    .font(.system(size: 12))
                }
            }
        }
    }

    private var mappingHIDStatus: some View {
        Label(
            model.hidStatus.text(using: localization),
            systemImage: "keyboard"
        )
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }

    private var mappingSelectionLockControl: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(localization.text("button_mapping.selection_lock"), isOn: $isMappingSelectionLocked)
                .font(.system(size: 12, weight: .medium))
                .toggleStyle(.switch)
            Text(localization.text("button_mapping.selection_lock_hint_short"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .help(localization.text("button_mapping.selection_lock_help"))
    }

    var voiceTriggerStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(settings.voiceKeyMode.displayName(using: localization), systemImage: "keyboard")
            Label(localization.text(settings.voiceFnTapModeEnabled
                ? "settings.integration.tap_enabled" : "settings.integration.tap_disabled"),
                systemImage: "hand.tap")
        }
    }

    private var mappingResetAllDefaultsSection: some View {
        GlassPanel {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(localization.text("button_mapping.restore_all.title"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(localization.text("button_mapping.restore_all.hint"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Button(role: .destructive) {
                    isShowingRestoreAllDefaultsAlert = true
                } label: {
                    Label(
                        localization.text("button_mapping.action.restore_all_defaults"),
                        systemImage: "arrow.counterclockwise"
                    )
                    .foregroundStyle(.red)
                }
                .compatibilityButtonStyle(.standard)
            }
        }
        .alert(
            localization.text("button_mapping.restore_all.confirm_title"),
            isPresented: $isShowingRestoreAllDefaultsAlert
        ) {
            Button(
                localization.text("button_mapping.restore_all.confirm_action"),
                role: .destructive
            ) {
                settings.resetBindings()
                selectedRemoteButton = .ok
                mappingEditingTarget = nil
                shortcutCaptureTarget = nil
                applicationShortcutCaptureProfileID = nil
                shortcutCaptureFeedback = nil
                mappingActionFilter = .basicKeys
            }
            Button(localization.text("common.action.cancel"), role: .cancel) {}
        } message: {
            Text(localization.text("button_mapping.restore_all.confirm_message"))
        }
    }

    private var mappingDevicePicker: some View {
        let profiles = RemoteDeviceNamePolicy.sortedForCards(
            settings.remoteDeviceProfiles,
            modelName: remoteModelName,
            systemName: { model.systemDeviceName(for: $0) }
        )
        return Picker(localization.text("remote.device.selector"), selection: Binding<UUID?>(
            get: { settings.selectedRemoteProfileID },
            set: { if let id = $0 { model.selectRemoteProfile(id) } }
        )) {
            if profiles.isEmpty || settings.selectedRemoteProfileID == nil {
                Text(localization.text("remote.device.select_placeholder")).tag(Optional<UUID>.none)
            }
            ForEach(profiles) { profile in
                Text(remoteModelName(profile)).tag(Optional(profile.id))
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 310)
        .disabled(profiles.isEmpty)
    }
}
