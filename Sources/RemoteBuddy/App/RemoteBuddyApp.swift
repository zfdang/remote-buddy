import AppKit
import Combine
import Darwin
import Sparkle
import SwiftUI
import ServiceManagement

@main
enum RemoteBuddyApp {
    @MainActor
    static func main() {
        if CommonPhraseClipboardPaste.runSnapshotHelperIfRequested() { return }
#if DEBUG
        if LocalizedUpdateUserDriver.runPreviewIfRequested() { return }
#endif

        if CommandLine.arguments.contains("--unregister-login-item") {
            if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                do { try SMAppService.mainApp.unregister() }
                catch { fputs("Could not unregister login item: \(error)\n", stderr); exit(1) }
            }
            return
        }
#if DEBUG
        if let screenshotDirectory = ProcessInfo.processInfo.environment[
            "REMOTE_BUDDY_SETTINGS_SCREENSHOT_DIR"
        ] {
            do {
                try SettingsScreenshotRenderer.renderAll(
                    to: URL(fileURLWithPath: screenshotDirectory, isDirectory: true),
                    sizeValue: ProcessInfo.processInfo.environment[
                        "REMOTE_BUDDY_SETTINGS_SCREENSHOT_SIZE"
                    ],
                    appearanceName: ProcessInfo.processInfo.environment[
                        "REMOTE_BUDDY_SETTINGS_SCREENSHOT_APPEARANCE"
                    ],
                    languageName: ProcessInfo.processInfo.environment[
                        "REMOTE_BUDDY_SETTINGS_SCREENSHOT_LANGUAGE"
                    ]
                )
            } catch {
                fputs("Settings screenshot rendering failed: \(error)\n", stderr)
                exit(EXIT_FAILURE)
            }
            return
        }
        if let screenshotDirectory = ProcessInfo.processInfo.environment[
            "REMOTE_BUDDY_ONBOARDING_SCREENSHOT_DIR"
        ] {
            do {
                try OnboardingScreenshotRenderer.renderAll(
                    to: URL(fileURLWithPath: screenshotDirectory, isDirectory: true),
                    appearanceName: ProcessInfo.processInfo.environment[
                        "REMOTE_BUDDY_ONBOARDING_SCREENSHOT_APPEARANCE"
                    ]
                )
            } catch {
                fputs("Onboarding screenshot rendering failed: \(error)\n", stderr)
                exit(EXIT_FAILURE)
            }
            return
        }
#endif
        let bundleIdentifier = Bundle.main.bundleIdentifier
            ?? ApplicationInstanceGuard.fallbackBundleIdentifier
        var instanceLock: ApplicationInstanceLock?
        if let lockURL = ApplicationInstanceGuard.defaultLockURL() {
            switch ApplicationInstanceLock.acquireForLaunch(at: lockURL, existingInstanceIsRunning: {
                ApplicationInstanceGuard.existingApplication(bundleIdentifier: bundleIdentifier) != nil
            }) {
            case let .acquired(lock):
                instanceLock = lock
            case .alreadyLocked:
                ApplicationInstanceGuard.existingApplication(
                    bundleIdentifier: bundleIdentifier
                )?.activate(options: [.activateAllWindows])
                return
            case let .failed(reason):
                fputs("Single-instance lock unavailable: \(reason)\n", stderr)
                return
            }
        } else {
            fputs("Single-instance lock unavailable: application_support_missing\n", stderr)
            return
        }

        if let existingApplication = ApplicationInstanceGuard.existingApplication(
            bundleIdentifier: bundleIdentifier,
            requiresFinishedLaunch: true
        ) {
            existingApplication.activate(options: [.activateAllWindows])
            return
        }

        let application = NSApplication.shared
        let delegate = RemoteBuddyAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(delegate.activationPolicy)
        withExtendedLifetime(instanceLock) {
            withExtendedLifetime(delegate) {
                application.run()
            }
        }
    }
}

@MainActor
final class RemoteBuddyAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate,
    NSWindowDelegate, SPUUpdaterDelegate, NSMenuItemValidation
{
    let model = BridgeAppModel()
    lazy var appIconController = AppIconController()
    let updateInformation = UpdateInformationStore()
    lazy var localization = LocalizationStore(settings: model.settings)
    let termination = ApplicationTerminationCoordinator()
    let actionFeedbackWindowCoordinator = ActionFeedbackWindowCoordinator()
    var statusItem: NSStatusItem?
    var statusItemPresentation: StatusItemPresentation = .disconnected
    var appliedStatusItemPresentation: StatusItemPresentation?
    var statusItemOperationID: UInt = 0
    var entryPointOperationID: UInt = 0
    var restoreClipboardItem: NSMenuItem?
    var systemMicrophoneSubmenu: NSMenu?
    var statusMenu: NSMenu?
    var settingsWindowController: NSWindowController?
    var isSettingsWindowOpen = false
    let unavailableVoiceToolAlertCoordinator = UnavailableVoiceToolAlertCoordinator()
    var subscriptions = Set<AnyCancellable>()
    var terminationSignalSources: [DispatchSourceSignal] = []
    var applicationShortcutMonitor: Any?
    var workspaceAudioLifecycleObservers: [NSObjectProtocol] = []
    var updateFeedSelection = UpdateFeedSelection(
        stableFeedURLString: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
    )
    var updateCheckTask: Task<Void, Never>?
    var packageFallbackCoordinator = UpdatePackageDownloadCoordinator()
    var updaterStarted = false
    var completedUpdateVersion: String?
    lazy var updateUserDriver = LocalizedUpdateUserDriver(localization: localization)
    lazy var updater = SPUUpdater(hostBundle: .main, applicationBundle: .main,
                                  userDriver: updateUserDriver, delegate: self)

    let connectionItem = NSMenuItem()

    var activationPolicy: NSApplication.ActivationPolicy {
        let baseLaunchDecision = OnboardingLaunchPolicy.shouldShowMainWindow(
            isComplete: model.settings.isOnboardingComplete,
            completedUpdate: false,
            openMainWindowAtLaunch: model.settings.openMainWindowAtLaunch
        )
        let shouldShowMainWindow = AppEntryPointVisibilityPolicy.shouldShowMainWindow(
            baseLaunchDecision: baseLaunchDecision,
            showDockIcon: model.settings.showDockIcon,
            showStatusBarIcon: model.settings.showStatusBarIcon
        )
        return SettingsWindowActivationPolicy.value(
            showDockIcon: model.settings.showDockIcon,
            isSettingsWindowOpen: shouldShowMainWindow
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.onboardingWindowIsActive = { [weak self] in
            (self?.isSettingsWindowOpen ?? false) && NSApp.isActive
        }
        if let environmentEvent = AppEnvironmentSnapshot.current(
            settings: model.settings
        ).publicEvent {
            AppLogger.shared.record(environmentEvent)
        }
        let currentBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let completedUpdate = model.settings.recordLaunchAndDetectCompletedUpdate(
            currentBuild: currentBuild,
            sparkleHadLaunchedBefore: UserDefaults.standard.bool(forKey: "SUHasLaunchedBefore")
        )
        if completedUpdate {
            completedUpdateVersion = UpdateDialogVersion.current().version
        }
        observeUpdatePreferences()
        observeAppIconPreference()
        configureUpdater()
        installTerminationSignalHandlers()
        configureApplicationMenu()
        installApplicationKeyboardShortcuts()
        applyStatusBarIconVisibility(
            model.settings.showStatusBarIcon,
            source: "launch"
        )
        observeModel()
        observeLocalization()
        ActionFeedbackCenter.shared.configureStandardActions(
            openSystemSettings: { [weak self] in
                self?.model.openPrivacyPane("Privacy_Accessibility")
            },
            reselectAction: { [weak self] in
                guard let self else { return }
                self.model.requestedSettingsSection = .mapping
                self.showSettings()
            }
        )
        actionFeedbackWindowCoordinator.start()
        installWorkspaceAudioLifecycleObservers()

        if OnboardingLaunchPolicy.shouldStartRuntime(
            isComplete: model.settings.isOnboardingComplete,
            step: model.settings.onboardingStep
        ) {
            model.startIfNeeded()
        }
        if model.settings.isOnboardingComplete,
           BridgeAppModel.shouldRecoverHIDAfterCompletedUpdate(
            completedUpdate: completedUpdate
        ) {
            model.recoverHIDAfterCompletedUpdate()
        }
        refreshMenuStatus()

        let baseLaunchDecision = OnboardingLaunchPolicy.shouldShowMainWindow(
            isComplete: model.settings.isOnboardingComplete,
            completedUpdate: completedUpdate,
            openMainWindowAtLaunch: model.settings.openMainWindowAtLaunch
        )
        let shouldShowMainWindow = AppEntryPointVisibilityPolicy.shouldShowMainWindow(
            baseLaunchDecision: baseLaunchDecision,
            showDockIcon: model.settings.showDockIcon,
            showStatusBarIcon: model.settings.showStatusBarIcon
        )
        if shouldShowMainWindow {
            if !baseLaunchDecision {
                AppLogger.shared.write(
                    "UI ENTRY_POINT phase=completed result=passed source=launch_recovery " +
                        "show_dock=false show_status_bar=false decision=open_settings"
                )
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.showSettings()
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        termination.request(timeout: model.voiceFnTapSession.terminationTimeout, begin: { complete in
            model.prepareForTermination()
            statusItem?.button?.title = localization.text("common.action.quitting")
            statusItem?.button?.toolTip = localization.text("common.action.quitting")
            model.voiceFnTapSession.setEnabled(false) { _ in
                DispatchQueue.main.async { complete() }
            }
        }, reply: { sender.reply(toApplicationShouldTerminate: true) })
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        actionFeedbackWindowCoordinator.stop()
        model.stop()
        model.settings.discardOnboardingVoiceTrial()
        updateCheckTask?.cancel()
        terminationSignalSources.forEach { $0.cancel() }
        terminationSignalSources.removeAll()
        if let applicationShortcutMonitor {
            NSEvent.removeMonitor(applicationShortcutMonitor)
            self.applicationShortcutMonitor = nil
        }
        let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
        workspaceAudioLifecycleObservers.forEach(workspaceNotificationCenter.removeObserver)
        workspaceAudioLifecycleObservers.removeAll()
        AppLogger.shared.write("SYSTEM AUDIO observers_stopped")
        AppLogger.shared.flush()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.refreshRemoteDeviceNames(reason: .foreground)

        model.refreshHIDAfterPermissionChange()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showSettings()
        AppLogger.shared.write(
            "UI ENTRY_POINT phase=completed result=passed source=application_reopen " +
                "show_dock=\(model.settings.showDockIcon) " +
                "show_status_bar=\(model.settings.showStatusBarIcon) " +
                "decision=open_settings"
        )
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let request = urls.lazy.compactMap(RemoteBuddyDeepLinkRequest.parse).first(where: \.mayActivateSettings) else {
            return
        }
        AppLogger.shared.write(
            "DEEPLINK BUDDY source=\(request.source ?? "unknown") " +
                "status=\(request.status?.rawValue ?? "none") " +
                "reason=\(request.reason ?? "none")"
        )
        NotificationCenter.default.post(
            name: .remoteBuddyDeepLinkReceived,
            object: request
        )
        showSettings()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func installTerminationSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber,
                queue: .main
            )
            source.setEventHandler {
                Task { @MainActor in
                    NSApp.terminate(nil)
                }
            }
            source.resume()
            terminationSignalSources.append(source)
        }
    }

    private func installWorkspaceAudioLifecycleObservers() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, SystemAudioLifecycleEvent)] = [
            (NSWorkspace.screensDidSleepNotification, .screenDidSleep),
            (NSWorkspace.screensDidWakeNotification, .screenDidWake),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionDidResignActive),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionDidBecomeActive),
            (NSWorkspace.willSleepNotification, .systemWillSleep),
            (NSWorkspace.didWakeNotification, .systemDidWake),
        ]
        workspaceAudioLifecycleObservers = events.map { name, event in
            notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.model.handleSystemAudioLifecycle(event)
                }
            }
        }
        workspaceAudioLifecycleObservers.append(
            notificationCenter.addObserver(
                forName: NSWorkspace.didDeactivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let bundleID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                    .bundleIdentifier
                guard bundleID == "com.apple.systempreferences" else { return }
                MainActor.assumeIsolated {
                    self?.model.refreshHIDAfterPermissionChange()
                }
            }
        )
        AppLogger.shared.write(
            "SYSTEM AUDIO observers_started events=\(events.map { $0.1.rawValue }.joined(separator: ","))"
        )
    }

    private func observeModel() {
        StatusItemPresentation.publisher(model: model)
        .receive(on: RunLoop.main)
        .sink { [weak self] presentation in
            // Consume the published snapshot, not properties that @Published has yet to set.
            self?.statusItemPresentation = presentation
            self?.refreshStatusItemPresentation()
        }
        .store(in: &subscriptions)

        Publishers.CombineLatest(
            model.$connectionStatus,
            model.$isStreaming
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            self?.refreshMenuStatus()
        }
        .store(in: &subscriptions)

        model.$unavailableVoiceToolPrompt
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.presentUnavailableVoiceToolAlertIfNeeded()
            }
            .store(in: &subscriptions)
    }

    private func observeLocalization() {
        localization.$locale
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.refreshStatusItemPresentation()
                self.settingsWindowController?.window?.title = self.localization.text("app.name")

                self.configureApplicationMenu()
                if self.statusItem != nil {
                    self.rebuildStatusMenu()
                }
            }
            .store(in: &subscriptions)
    }

    private func observeAppIconPreference() {
        model.settings.$appIconIdentifier
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] identifier in
                self?.applyAppIcon(identifier, source: "preference")
            }
            .store(in: &subscriptions)
    }

    private func applyAppIcon(_ identifier: AppIconIdentifier, source: String) {
        appIconController.apply(identifier, source: source)
    }

    func reapplyCurrentAppIcon(source: String) {
        applyAppIcon(model.settings.appIconIdentifier, source: source)
    }
}
