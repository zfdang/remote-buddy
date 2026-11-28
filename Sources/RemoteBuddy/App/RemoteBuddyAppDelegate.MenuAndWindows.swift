import AppKit
import SwiftUI

extension RemoteBuddyAppDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === systemMicrophoneSubmenu {
            refreshSystemMicrophoneSubmenu()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        refreshMenuStatus()
    }

    @discardableResult
    func configureStatusItem() -> Bool {
        guard statusItem == nil else {
            rebuildStatusMenu()
            refreshStatusItemPresentation()
            return false
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        connectionItem.isEnabled = false

        statusItem = item
        appliedStatusItemPresentation = nil
        statusItemPresentation = .resolve(
            physicalConnected: model.isConnected,
            isStreaming: model.isStreaming
        )
        refreshStatusItemPresentation()
        rebuildStatusMenu()
        return true
    }

    @discardableResult
    func removeStatusItem() -> Bool {
        guard let statusItem else { return false }
        statusMenu?.removeItem(connectionItem)
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
        statusMenu = nil
        systemMicrophoneSubmenu = nil
        appliedStatusItemPresentation = nil
        return true
    }

    func applyStatusBarIconVisibility(_ isVisible: Bool, source: String) {
        entryPointOperationID &+= 1
        let operationID = entryPointOperationID
        AppLogger.shared.write(
            "UI ENTRY_POINT operation_id=\(operationID) phase=requested source=\(source) " +
                "show_dock=\(model.settings.showDockIcon) show_status_bar=\(isVisible)"
        )
        let changed = isVisible ? configureStatusItem() : removeStatusItem()
        AppLogger.shared.write(
            "UI ENTRY_POINT operation_id=\(operationID) phase=completed result=passed " +
                "source=\(source) show_dock=\(model.settings.showDockIcon) " +
                "show_status_bar=\(isVisible) " +
                "both_hidden=\(!model.settings.showDockIcon && !isVisible) " +
                "change=\(changed ? (isVisible ? "created" : "removed") : "none")"
        )
    }

    func rebuildStatusMenu() {
        statusMenu?.removeItem(connectionItem)

        let built = Self.buildStatusMenu(
            connectionItem: connectionItem,
            localization: localization,
            target: self,
            delegate: self,
            includesCheckForUpdates: updateFeedSelection.validatedStableFeedURL != nil,
            canRestoreClipboard: CommonPhraseClipboardPaste.shared.canRestoreClipboard,
            supportItem: supportMenuItem(),
            versionItem: versionMenuItem()
        )
        systemMicrophoneSubmenu = built.systemMicrophoneSubmenu
        restoreClipboardItem = built.restoreClipboardItem
        statusMenu = built.menu
        refreshMenuStatus()
        refreshSystemMicrophoneSubmenu()
    }

    static func buildStatusMenu(
        connectionItem: NSMenuItem,
        localization: LocalizationStore,
        target: AnyObject?,
        delegate: NSMenuDelegate?,
        includesCheckForUpdates: Bool,
        canRestoreClipboard: Bool,
        supportItem: NSMenuItem,
        versionItem: NSMenuItem
    ) -> (menu: NSMenu, systemMicrophoneSubmenu: NSMenu, restoreClipboardItem: NSMenuItem) {
        let menu = NSMenu()
        menu.delegate = delegate
        menu.addItem(connectionItem)
        menu.addItem(makeMenuItem(
            title: localization.text("connection.action.reconnect"),
            action: #selector(reconnect),
            target: target
        ))
        menu.addItem(.separator())

        let settingsItem = makeMenuItem(
            title: localization.text("menu.open_settings"),
            action: #selector(showSettingsFromStatusItem),
            target: target
        )
        settingsItem.keyEquivalent = ","
        settingsItem.keyEquivalentModifierMask = .command
        menu.addItem(settingsItem)

        let microphoneItem = NSMenuItem(
            title: localization.text("menu.system_microphone"),
            action: nil,
            keyEquivalent: ""
        )
        let microphoneSubmenu = NSMenu()
        microphoneSubmenu.delegate = delegate
        microphoneItem.submenu = microphoneSubmenu
        menu.addItem(microphoneItem)

        menu.addItem(.separator())
        if includesCheckForUpdates {
            menu.addItem(makeMenuItem(
                title: localization.text("menu.check_for_updates"),
                action: #selector(checkForUpdates),
                target: target
            ))
        }
        menu.addItem(supportItem)
        menu.addItem(makeMenuItem(
            title: localization.text("menu.about"),
            action: #selector(showAbout),
            target: target
        ))
        menu.addItem(versionItem)
        menu.addItem(.separator())

        let restoreItem = makeMenuItem(
            title: localization.text("common_phrases.restore_clipboard"),
            action: #selector(restorePhraseClipboard),
            target: target
        )
        restoreItem.isHidden = !canRestoreClipboard
        menu.addItem(restoreItem)
        menu.addItem(makeMenuItem(
            title: localization.text("common.action.quit"),
            action: #selector(quit),
            target: target
        ))
        return (menu, microphoneSubmenu, restoreItem)
    }

    private static func makeMenuItem(title: String, action: Selector, target: AnyObject?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        return item
    }

    func configureApplicationMenu() {
        let mainMenu = NSMenu()

        let applicationMenuItem = NSMenuItem()
        let applicationMenu = NSMenu(title: localization.text("app.name"))
        applicationMenu.addItem(menuItem("menu.about", action: #selector(showAbout)))
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(responderMenuItem(
            "common.action.hide",
            action: "hide:",
            keyEquivalent: "h"
        ))
        applicationMenu.addItem(responderMenuItem(
            "common.action.hide_others",
            action: "hideOtherApplications:",
            keyEquivalent: "h",
            modifierMask: [.command, .option]
        ))
        applicationMenu.addItem(responderMenuItem(
            "common.action.show_all",
            action: "unhideAllApplications:",
            keyEquivalent: ""
        ))
        applicationMenu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: localization.text("common.action.quit"),
            action: #selector(quit),
            keyEquivalent: ""
        )
        quitItem.target = self
        applicationMenu.addItem(quitItem)
        applicationMenuItem.submenu = applicationMenu
        mainMenu.addItem(applicationMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: localization.text("menu.file"))
        let closeItem = NSMenuItem(
            title: localization.text("common.action.close"),
            action: #selector(closeKeyWindow),
            keyEquivalent: "w"
        )
        closeItem.keyEquivalentModifierMask = .command
        closeItem.target = self
        fileMenu.addItem(menuItem("menu.open_log_folder", action: #selector(showLog)))
        fileMenu.addItem(.separator())
        fileMenu.addItem(closeItem)
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: localization.text("menu.edit"))
        editMenu.addItem(responderMenuItem("common.action.undo", action: "undo:", keyEquivalent: "z"))
        editMenu.addItem(responderMenuItem("common.action.redo", action: "redo:", keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(responderMenuItem("common.action.cut", action: "cut:", keyEquivalent: "x"))
        editMenu.addItem(responderMenuItem("common.action.copy", action: "copy:", keyEquivalent: "c"))
        editMenu.addItem(responderMenuItem("common.action.paste", action: "paste:", keyEquivalent: "v"))
        editMenu.addItem(.separator())
        editMenu.addItem(responderMenuItem("common.action.select_all", action: "selectAll:", keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: localization.text("menu.window"))
        windowMenu.addItem(responderMenuItem(
            "common.action.minimize",
            action: "performMiniaturize:",
            keyEquivalent: "m"
        ))
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    private func responderMenuItem(
        _ titleKey: String,
        action: String,
        keyEquivalent: String,
        modifierMask: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: localization.text(titleKey),
            action: Selector(action),
            keyEquivalent: keyEquivalent
        )
        item.keyEquivalentModifierMask = modifierMask
        // A nil target lets AppKit route the standard editing action to the focused text field.
        item.target = nil
        return item
    }

    func installApplicationKeyboardShortcuts() {
        applicationShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            switch ApplicationShortcutResolver.resolve(
                modifierFlags: event.modifierFlags,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers
            ) {
            case .closeWindow:
                self?.closeKeyWindow()
                return nil
            case .passThrough:
                return event
            }
        }
    }

    private func menuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: localization.text(title), action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func supportMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: localization.text("menu.help_and_support"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(menuItem("about.support.website", action: #selector(openWebsite)))
        submenu.addItem(menuItem("about.support.github", action: #selector(openGitHub)))
        submenu.addItem(menuItem("menu.show_logs", action: #selector(showLog)))
        item.submenu = submenu
        return item
    }

    private func versionMenuItem() -> NSMenuItem {
        let version = (Bundle.main.object(forInfoDictionaryKey: "BuddyReleaseVersion") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? localization.text("common.value.unknown")
        let title = String(
            format: localization.text("app.version"),
            locale: localization.locale,
            arguments: [version]
        )
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    func presentUnavailableVoiceToolAlertIfNeeded() {
        unavailableVoiceToolAlertCoordinator.presentIfIdle(
            model: model,
            localization: localization,
            runModal: { content in
                NSSound.beep()
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = content.title
                alert.informativeText = content.message
                alert.addButton(withTitle: content.openSettingsTitle)
                alert.addButton(withTitle: content.cancelTitle)
                return alert.runModal()
            },
            openSettings: { [weak self] in
                self?.showSettings()
            }
        )
    }

    func refreshMenuStatus() {
        connectionItem.title = model.connectionStatus.text(using: localization)
    }

    func refreshSystemMicrophoneSubmenu() {
        guard let systemMicrophoneSubmenu else { return }
        SystemMicrophoneMenuBuilder.populate(
            systemMicrophoneSubmenu,
            devices: CoreAudioDeviceCatalog.inputDevices(),
            defaultInputUID: CoreAudioDeviceCatalog.defaultInputDevice()?.uid,
            noteTitle: localization.text("menu.system_microphone.note"),
            emptyTitle: localization.text("menu.system_microphone.none"),
            target: self,
            action: #selector(selectSystemMicrophone(_:))
        )
    }

    @objc private func selectSystemMicrophone(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        let devices = CoreAudioDeviceCatalog.inputDevices()
        let targetDevice = devices.first { $0.uid == uid }
        let applied = CoreAudioDeviceCatalog.setDefaultInputDevice(
            uid: uid,
            availableInputDevices: { devices }
        )
        AppLogger.shared.write(
            "AUDIO DEFAULT_INPUT_SWITCH phase=completed result=\(applied ? "applied" : "failed") " +
                "target={\(CoreAudioDeviceCatalog.deviceDiagnostic(targetDevice))}"
        )
    }

    func refreshStatusItemPresentation() {
        guard let button = statusItem?.button else { return }
        let description = LocalizedMessage(
            statusItemPresentation.descriptionKey,
            arguments: [localization.text("app.name")]
        ).text(using: localization)
        statusItemPresentation.apply(to: button, description: description)
        button.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(
                name: localization.text("status_item.accessibility.show_menu"),
                target: self,
                selector: #selector(showStatusMenuAction)
            )
        ])
        guard appliedStatusItemPresentation != statusItemPresentation else { return }
        statusItemOperationID &+= 1
        AppLogger.shared.write(
            "UI STATUS_ITEM operation_id=\(statusItemOperationID) phase=completed result=applied " +
                "from=\(appliedStatusItemPresentation?.rawValue ?? "none") " +
                "to=\(statusItemPresentation.rawValue) " +
                "rendering=\(button.image == nil ? "text" : "image")"
        )
        appliedStatusItemPresentation = statusItemPresentation
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if StatusItemActionResolver.shouldShowMenu(
            eventType: event?.type,
            modifierFlags: event?.modifierFlags
        ) {
            showStatusMenu()
        } else {
            showSettingsFromStatusItem()
        }
    }

    @objc @discardableResult
    private func showStatusMenuAction() -> Bool {
        showStatusMenu()
        return true
    }

    private func showStatusMenu() {
        let canRestore = CommonPhraseClipboardPaste.shared.canRestoreClipboard
        restoreClipboardItem?.isHidden = !canRestore
        restoreClipboardItem?.isEnabled = canRestore
        guard let statusItem, let statusMenu else { return }
        refreshMenuStatus()
        refreshSystemMicrophoneSubmenu()
        statusItem.menu = statusMenu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(restorePhraseClipboard) {
            let canRestore = CommonPhraseClipboardPaste.shared.canRestoreClipboard
            menuItem.isHidden = !canRestore
            return canRestore
        }
        return true
    }

    @objc private func restorePhraseClipboard() {
        CommonPhraseClipboardPaste.shared.restorePreviousClipboard()
    }

    @objc private func reconnect() {
        model.reconnect()
    }

    @objc func showSettings() {
        showSettingsWindow()
    }

    @objc private func showSettingsFromStatusItem() {
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(point) }
        showSettingsWindow(targetScreen: screen)
    }

    private func showSettingsWindow(targetScreen: NSScreen? = nil) {
        if settingsWindowController == nil {
            settingsWindowController = makeSettingsWindowController()
        }
        guard let windowController = settingsWindowController,
              let window = windowController.window else { return }
        if let targetScreen, SettingsWindowDisplayPolicy.shouldMove(
            isOpen: isSettingsWindowOpen,
            currentScreen: window.screen.flatMap { NSScreen.screens.firstIndex(of: $0) },
            targetScreen: NSScreen.screens.firstIndex(of: targetScreen)
        ) {
            let visibleFrame = targetScreen.visibleFrame
            var frame = window.frame
            frame.origin = NSPoint(x: visibleFrame.midX - frame.width / 2, y: visibleFrame.midY - frame.height / 2)
            window.setFrame(SettingsWindowLayout.fittedFrame(frame, in: visibleFrame), display: false)
        }
        isSettingsWindowOpen = true
        updateDockActivationPolicy()
        fitSettingsWindowToScreen(window)
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeSettingsWindowController() -> NSWindowController {
        let hostingController = NSHostingController(
            rootView: RemoteBuddyRootView(
                model: model,
                updateInformation: updateInformation,
                installAvailableUpdate: { [weak self] update in
                    self?.installAvailableUpdate(update)
                },
                refreshUpdateInformation: { [weak self] in
                    self?.refreshUpdateInformation()
                },
                setDockIconVisible: { [weak self] isVisible in
                    self?.setDockIconVisible(isVisible)
                },
                setStatusBarIconVisible: { [weak self] isVisible in
                    self?.setStatusBarIconVisible(isVisible)
                },
                completedUpdateVersion: completedUpdateVersion
            )
            .environmentObject(localization)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1020, height: 772),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = localization.text("app.name")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = false
        // A settings window must remain visible when the user switches to another app.
        // Closing it remains an explicit red-button or Command-W action.
        window.hidesOnDeactivate = false
        window.delegate = self
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.setContentSize(SettingsWindowLayout.preferredContentSize)
        let restored = window.setFrameUsingName("RemoteBuddySettings")
        window.setFrameAutosaveName("RemoteBuddySettings")
        if !restored { window.center() }
        fitSettingsWindowToScreen(window)
        return NSWindowController(window: window)
    }

    private func fitSettingsWindowToScreen(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        window.minSize = SettingsWindowLayout.minimumWindowSize(in: screen.visibleFrame)
        window.setFrame(SettingsWindowLayout.fittedFrame(window.frame, in: screen.visibleFrame), display: true)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === settingsWindowController?.window else { return }
        fitSettingsWindowToScreen(window)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === settingsWindowController?.window
        else { return }

        isSettingsWindowOpen = false
        updateDockActivationPolicy()
        if SettingsWindowActivationPolicy.shouldDeactivateOnClose(
            showDockIcon: model.settings.showDockIcon
        ) {
            NSApp.deactivate()
        }
    }

    func windowDidMiniaturize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === settingsWindowController?.window
        else { return }
        DispatchQueue.main.async { [weak self] in
            self?.reapplyCurrentAppIcon(source: "window_miniaturized")
        }
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === settingsWindowController?.window
        else { return }
        DispatchQueue.main.async { [weak self] in
            self?.reapplyCurrentAppIcon(source: "window_deminiaturized")
        }
    }

    @objc private func showLog() {
        model.openLogFolder()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let shortVersion = (Bundle.main.object(forInfoDictionaryKey: "BuddyReleaseVersion") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? localization.text("common.value.unknown")
        let alert = NSAlert()
        alert.messageText = localization.text("app.name")
        alert.informativeText = String(
            format: localization.text("about.alert.description_with_version"),
            locale: localization.locale,
            arguments: [shortVersion]
        )
        alert.addButton(withTitle: localization.text("common.action.ok"))
        alert.runModal()
    }

    private func setDockIconVisible(_ isVisible: Bool) {
        model.settings.showDockIcon = isVisible
        updateDockActivationPolicy()
        AppLogger.shared.write(
            "UI ENTRY_POINT phase=completed result=passed source=dock_toggle " +
                "show_dock=\(isVisible) show_status_bar=\(model.settings.showStatusBarIcon) " +
                "both_hidden=\(!isVisible && !model.settings.showStatusBarIcon)"
        )
    }

    private func setStatusBarIconVisible(_ isVisible: Bool) {
        model.settings.showStatusBarIcon = isVisible
        applyStatusBarIconVisibility(isVisible, source: "status_bar_toggle")
    }

    private func updateDockActivationPolicy() {
        NSApp.setActivationPolicy(SettingsWindowActivationPolicy.value(
            showDockIcon: model.settings.showDockIcon,
            isSettingsWindowOpen: isSettingsWindowOpen
        ))
        reapplyCurrentAppIcon(source: "activation_policy")
    }

    @objc private func openGitHub() {
        NSWorkspace.shared.open(AppLinks.githubRepository)
    }

    @objc private func openWebsite() {
        NSWorkspace.shared.open(localization.localizedWebsiteURL)
    }

    @objc private func closeKeyWindow() {
        if let keyWindow = NSApp.keyWindow {
            keyWindow.performClose(nil)
        } else if let window = settingsWindowController?.window, window.isVisible {
            window.performClose(nil)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

@MainActor
enum SystemMicrophoneMenuBuilder {
    static func populate(
        _ menu: NSMenu,
        devices: [AudioDeviceInfo],
        defaultInputUID: String?,
        noteTitle: String,
        emptyTitle: String,
        target: AnyObject?,
        action: Selector
    ) {
        menu.removeAllItems()
        let noteItem = NSMenuItem(title: noteTitle, action: nil, keyEquivalent: "")
        noteItem.isEnabled = false
        noteItem.view = makeNoteView(title: noteTitle)
        menu.addItem(noteItem)
        menu.addItem(.separator())
        guard !devices.isEmpty else {
            let emptyItem = NSMenuItem(title: emptyTitle, action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
            return
        }
        for device in devices {
            let item = NSMenuItem(title: device.name, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = device.uid
            item.state = device.uid == defaultInputUID ? .on : .off
            menu.addItem(item)
        }
    }

    private static func makeNoteView(title: String) -> NSView {
        let container = NSView()
        container.autoresizingMask = [.width]

        let label = NSTextField(wrappingLabelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.menuFont(ofSize: 12)
        label.textColor = .labelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 280
        label.isEditable = false
        label.isSelectable = false
        label.isBezeled = false
        label.drawsBackground = false
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        container.addSubview(label)

        var constraints: [NSLayoutConstraint] = [
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
        ]

        if let symbol = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil) {
            let iconView = NSImageView(image: symbol)
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            iconView.contentTintColor = .secondaryLabelColor
            iconView.setContentHuggingPriority(.required, for: .horizontal)
            iconView.setContentCompressionResistancePriority(.required, for: .horizontal)
            container.addSubview(iconView)

            constraints.append(contentsOf: [
                iconView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
                iconView.topAnchor.constraint(equalTo: label.topAnchor, constant: 1),
                iconView.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -6),
                label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            ])
        } else {
            constraints.append(label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14))
        }

        NSLayoutConstraint.activate(constraints)
        container.layoutSubtreeIfNeeded()
        let fitted = container.fittingSize
        container.frame = NSRect(origin: .zero, size: NSSize(width: ceil(fitted.width), height: ceil(fitted.height)))
        return container
    }
}
