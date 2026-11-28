import AppKit
import Combine
import CoreBluetooth
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var model: BridgeAppModel
    @ObservedObject var settings: AppSettings

    @ObservedObject var loginItemService: LoginItemService
    @ObservedObject var updateInformation: UpdateInformationStore
    @EnvironmentObject var localization: LocalizationStore

    let installAvailableUpdate: (AvailableUpdateInformation) -> Void
    let refreshUpdateInformation: () -> Void
    let setDockIconVisible: (Bool) -> Void
    let setStatusBarIconVisible: (Bool) -> Void
    let appIconCatalog: AppIconCatalog
    private let minimumContentSize: CGSize
    let permissionOverrides: SystemPermissionOverrides?

    @State var remoteRemovalProfile: RemoteDeviceProfile?
    @State var isRemoteRemovalPresented = false
    @State var selectedSection: SettingsSection
    @State var selectedRemoteButton: RemoteButton = .ok
    @State private var selectedSiriRemoteControlID = "select"
    @State private var selectedChromecastControlID = "select"
    @State var isMappingSelectionLocked = true
    @State var mappingEditingTarget: ShortcutEditingTarget?
    @State var mappingActionFilter: MappingActionFilter = .basicKeys
    /// nil edits the selected remote's default mapping; a bundle ID edits that app's overrides.
    @State var mappingApplicationBundleID: String?
    @State var shortcutCaptureTarget: ShortcutEditingTarget?
    @State var applicationShortcutCaptureProfileID: UUID?
    @State var shortcutCaptureFeedback: ShortcutCaptureFeedback?
    @State var openURLTestFeedback: OpenURLTestFeedback?
    @State var customApplicationLearningStates: [UUID: CustomApplicationLearningState] = [:]
    @State var bluetoothAuthorization: CBManagerAuthorization
    @State var inputMonitoringGranted: Bool
    @State var accessibilityGranted: Bool
    @State var integrationToolAvailability: OnboardingVoiceToolAvailability
    @State var isRepositoryLinkCopied = false
    @State var isShowingRestoreAllDefaultsAlert = false
    @State var isPermissionRelaunchConfirmationPresented = false

    init(
        model: BridgeAppModel,
        updateInformation: UpdateInformationStore,
        installAvailableUpdate: @escaping (AvailableUpdateInformation) -> Void = { _ in },
        refreshUpdateInformation: @escaping () -> Void = {},
        setDockIconVisible: @escaping (Bool) -> Void = { _ in },
        setStatusBarIconVisible: @escaping (Bool) -> Void = { _ in },
        appIconCatalog: AppIconCatalog? = nil,
        initialSection: SettingsSection? = nil,
        initialMappingEditingButton: RemoteButton? = nil,
        initialMappingEditingTrigger: ButtonTrigger = .singleClick,
        minimumContentSize: CGSize = SettingsWindowLayout.minimumCanvasSize,
        permissionOverrides: SystemPermissionOverrides? = nil
    ) {
        self.model = model
        settings = model.settings

        loginItemService = model.loginItemService
        self.updateInformation = updateInformation
        self.installAvailableUpdate = installAvailableUpdate
        self.refreshUpdateInformation = refreshUpdateInformation
        self.setDockIconVisible = setDockIconVisible
        self.setStatusBarIconVisible = setStatusBarIconVisible
        self.appIconCatalog = appIconCatalog ?? .live()
        self.minimumContentSize = minimumContentSize
        self.permissionOverrides = permissionOverrides
        _selectedSection = State(initialValue: SettingsPageBehavior.initialSection(
            requestedSection: initialSection
        ))
        _selectedRemoteButton = State(initialValue: initialMappingEditingButton ?? .ok)
        _mappingEditingTarget = State(
            initialValue: initialMappingEditingButton.map {
                ShortcutEditingTarget(button: $0, trigger: initialMappingEditingTrigger)
            }
        )
        _bluetoothAuthorization = State(initialValue: permissionOverrides?.bluetooth ?? CBManager.authorization)
        _inputMonitoringGranted = State(initialValue: permissionOverrides?.inputMonitoring ?? HIDRemoteMonitor.isInputMonitoringGranted)
        _accessibilityGranted = State(initialValue: permissionOverrides?.accessibility ?? KeyboardInjector.isAccessibilityTrusted)
        _integrationToolAvailability = State(initialValue: permissionOverrides == nil
            ? OnboardingInputSourceSwitcher.integrationAvailability(for: model.settings.onboardingVoiceTool)
            : .available)
    }

    var body: some View {
        AdaptiveSettingsViewport(minimumSize: minimumContentSize) {
            settingsContent
        }
    }

    private var settingsContent: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: SettingsPageBehavior.sidebarWidth)
            Color(nsColor: .separatorColor)
                .frame(width: SettingsPageBehavior.sidebarDividerWidth)
                .frame(maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: .top)
            selectedPage
        }
        .background(Color(nsColor: .controlBackgroundColor).ignoresSafeArea())
        .environment(\.locale, localization.locale)
        .onAppear {
            if selectedSection == .mapping {
                model.selectDefaultMappingRemoteIfAvailable()
            }
            model.refreshRemoteDeviceNames(reason: .page)
            refreshPermissionStates()
            loginItemService.refresh()
            if let requestedSection = model.requestedSettingsSection {
                selectSection(requestedSection)
                model.requestedSettingsSection = nil
            }

        }
        .onChange(of: selectedSection) { _, section in
            if section == .mapping {
                model.selectDefaultMappingRemoteIfAvailable()
            }
            if section == .connection || section == .mapping {
                model.refreshRemoteDeviceNames(reason: .page)
            }
        }
        .onChange(of: settings.onboardingVoiceTool) { _, _ in
            refreshPermissionStates()
        }
        .onReceive(model.$requestedSettingsSection.compactMap { $0 }) { section in
            selectSection(section)
            model.requestedSettingsSection = nil
        }
        .task(id: selectedSection) { @MainActor in
            guard selectedSection == .general ||
                    selectedSection == .connection ||
                    selectedSection == .permissions ||
                    selectedSection == .applicationIntegration,
                  !SettingsVisualRenderingPolicy.isScreenshotHarness else { return }
            model.refreshAudioDevices()
            while !Task.isCancelled {
                refreshPermissionStates()
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionStates()
            loginItemService.refresh()
            if settings.g9n9nBluetoothLogRecoveryEnabled {
                model.refreshBluetoothLoggingProfileStatus()
            }
        }
        .confirmationDialog(
            localization.text("permission.desync.restart_confirm.title"),
            isPresented: $isPermissionRelaunchConfirmationPresented
        ) {
            Button(localization.text("permission.desync.action.restart"), role: .destructive) {
                _ = model.relaunchApplication()
            }
            Button(localization.text("common.action.cancel"), role: .cancel) {}
        } message: {
            Text(localization.text("permission.desync.restart_confirm.message"))
        }
    }
}
