import CoreGraphics
import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Application button profiles")
@MainActor
struct ApplicationButtonProfileTests {
    private let claude = "com.anthropic.claudefordesktop"
    private let codex = "com.openai.codex"
    private let notes = "com.apple.Notes"
    private let nextSession = CustomKeyboardShortcut(keyCode: 125, modifierFlags: .option, keyLabel: "↓")
    private let nextChat = CustomKeyboardShortcut(keyCode: 30, modifierFlags: [.command, .option], keyLabel: "]")

    private func makeSettings() -> (settings: AppSettings, defaults: UserDefaults) {
        let defaults = EphemeralUserDefaults()
        return (AppSettings(defaults: defaults), defaults)
    }

    @Test func frontmostAppOverrideAppliesPerTriggerAndLeavesOtherButtonsDefault() throws {
        let (settings, _) = makeSettings()

        let remoteID = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        settings.selectRemoteProfile(remoteID)

        var front: String? = notes
        settings.frontmostApplicationBundleIdentifier = { front }

        settings.addApplicationButtonProfile(bundleID: claude, name: "Claude")
        settings.setApplicationScopedAction(
            ConfiguredButtonAction(action: .customShortcut, shortcut: nextSession),
            bundleID: claude, button: .volumeDown, trigger: .singleClick
        )
        settings.setApplicationScopedAction(
            ConfiguredButtonAction(action: .commandUndo, shortcut: nil),
            bundleID: claude, button: .ok, trigger: .doubleClick
        )
        settings.setApplicationScopedAction(
            ConfiguredButtonAction(action: .escape, shortcut: nil),
            bundleID: claude, button: .home, trigger: .longPress
        )

        settings.addApplicationButtonProfile(bundleID: codex, name: "Codex")
        settings.setApplicationScopedAction(
            ConfiguredButtonAction(action: .customShortcut, shortcut: nextChat),
            bundleID: codex, button: .volumeDown, trigger: .singleClick
        )

        front = claude
        #expect(settings.configuredAction(for: .volumeDown, trigger: .singleClick, profileID: remoteID).shortcut == nextSession)
        #expect(settings.configuredAction(for: .ok, trigger: .doubleClick, profileID: remoteID).action == .commandUndo)
        #expect(settings.configuredAction(for: .home, trigger: .longPress, profileID: remoteID).action == .escape)
        // Unlisted buttons keep the remote's base mapping.
        #expect(settings.configuredAction(for: .ok, trigger: .singleClick, profileID: remoteID)
            == settings.configuredBaseAction(for: .ok, trigger: .singleClick))

        front = codex
        #expect(settings.configuredAction(for: .volumeDown, trigger: .singleClick, profileID: remoteID).shortcut == nextChat)
        #expect(settings.configuredAction(for: .ok, trigger: .doubleClick, profileID: remoteID)
            == settings.configuredBaseAction(for: .ok, trigger: .doubleClick))

        front = notes
        #expect(settings.configuredAction(for: .volumeDown, trigger: .singleClick, profileID: remoteID).action == .volumeDown)
    }

    @Test func perRemotePerAppProfilesStayIsolatedAcrossRemotesAndReload() throws {
        let (settings, defaults) = makeSettings()

        let xiaomiID = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        let g9n9nID = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)

        var front: String? = claude
        settings.frontmostApplicationBundleIdentifier = { front }

        // Configure Claude override on Xiaomi remote.
        settings.selectRemoteProfile(xiaomiID)
        settings.addApplicationButtonProfile(bundleID: claude, name: "Claude")
        settings.setApplicationScopedAction(
            ConfiguredButtonAction(action: .commandUndo, shortcut: nil),
            bundleID: claude, button: .back, trigger: .singleClick
        )

        // Switch to G9N9N remote: Xiaomi's Claude profile must not bleed over (only G9N9N's default Safari profile exists).
        settings.selectRemoteProfile(g9n9nID)
        #expect(Set(settings.applicationButtonProfiles.keys) == [AppSettings.defaultChromecastSafariBundleID])
        #expect(settings.applicationButtonProfiles[claude] == nil)

        // Configure a different Claude override on G9N9N remote.
        settings.addApplicationButtonProfile(bundleID: claude, name: "Claude")
        settings.setApplicationScopedAction(
            ConfiguredButtonAction(action: .commandCopy, shortcut: nil),
            bundleID: claude, button: .back, trigger: .singleClick
        )

        // Even while G9N9N is selected, resolving presses for each remote uses its own app overrides,
        // and an unregistered remote profileID never borrows G9N9N's overrides.
        front = claude
        #expect(settings.configuredAction(for: .back, trigger: .singleClick, profileID: g9n9nID).action == .commandCopy)
        #expect(settings.configuredAction(for: .back, trigger: .singleClick, profileID: xiaomiID).action == .commandUndo)
        #expect(settings.applicationButtonProfiles(for: UUID()).isEmpty)

        // Editing a non-selected remote's base binding preserves its per-app overrides.
        settings.setBaseBinding(
            ConfiguredButtonAction(action: .escape, shortcut: nil),
            for: .home, trigger: .singleClick, profileID: xiaomiID
        )
        #expect(settings.configuredAction(for: .back, trigger: .singleClick, profileID: xiaomiID).action == .commandUndo)

        // Reloading from UserDefaults preserves both remotes' per-app overrides.
        let reloaded = AppSettings(defaults: defaults)
        reloaded.frontmostApplicationBundleIdentifier = { claude }
        #expect(reloaded.selectedRemoteProfileID == g9n9nID)
        #expect(reloaded.configuredAction(for: .back, trigger: .singleClick, profileID: g9n9nID).action == .commandCopy)
        #expect(reloaded.configuredAction(for: .back, trigger: .singleClick, profileID: xiaomiID).action == .commandUndo)

        // Selecting Xiaomi in settings restores Xiaomi's app profile dictionary for editing.
        reloaded.selectRemoteProfile(xiaomiID)
        #expect(reloaded.isApplicationOverride(bundleID: claude, button: .back, trigger: .singleClick))
        #expect(reloaded.applicationScopedAction(bundleID: claude, button: .back, trigger: .singleClick).action == .commandUndo)

        // Switching to a third app falls back to each remote's base action.
        reloaded.frontmostApplicationBundleIdentifier = { notes }
        #expect(reloaded.configuredAction(for: .back, trigger: .singleClick, profileID: g9n9nID)
            == reloaded.configuredAction(for: .back, trigger: .singleClick))

        // Removing the non-selected or last remote resets cleanly without leaking profiles.
        #expect(reloaded.removeRemoteProfile(g9n9nID, rememberAsForgotten: false))
        #expect(reloaded.removeRemoteProfile(xiaomiID, rememberAsForgotten: false))
        #expect(reloaded.applicationButtonProfiles.isEmpty)
    }

    @Test func mappingPageLookupsIgnoreFrontmostApplicationOverrides() throws {
        let (settings, _) = makeSettings()

        let remoteID = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        settings.selectRemoteProfile(remoteID)
        settings.frontmostApplicationBundleIdentifier = { claude }

        let baseOK = settings.configuredBaseAction(for: .ok, trigger: .singleClick)
        settings.addApplicationButtonProfile(bundleID: claude, name: "Claude")
        settings.setApplicationScopedAction(
            ConfiguredButtonAction(action: .commandUndo, shortcut: nil),
            bundleID: claude, button: .ok, trigger: .singleClick
        )

        #expect(settings.configuredBaseAction(for: .ok, trigger: .singleClick) == baseOK)
        #expect(settings.configuredAction(for: .ok, trigger: .singleClick) == baseOK)
        #expect(settings.configuredAction(for: .ok, trigger: .singleClick, profileID: remoteID).action == .commandUndo)
    }

    @Test func hidRemoteMonitorDispatchesActionsByFrontmostApplication() throws {
        let (settings, _) = makeSettings()

        settings.onboardingStep = .complete
        let profileID = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        settings.selectRemoteProfile(profileID)

        var front: String? = claude
        settings.frontmostApplicationBundleIdentifier = { front }

        settings.addApplicationButtonProfile(bundleID: claude, name: "Claude")
        settings.setApplicationScopedAction(
            ConfiguredButtonAction(action: .customShortcut, shortcut: nextSession),
            bundleID: claude, button: .ok, trigger: .singleClick
        )
        settings.addApplicationButtonProfile(bundleID: codex, name: "Codex")
        settings.setApplicationScopedAction(
            ConfiguredButtonAction(action: .customShortcut, shortcut: nextChat),
            bundleID: codex, button: .ok, trigger: .singleClick
        )

        let baseOK = settings.configuredBaseAction(for: .ok, trigger: .singleClick).action
        let clock = ControlledTestScheduler()
        var performed: [ConfiguredButtonAction] = []
        let monitor = HIDRemoteMonitor(
            settings: settings,
            profileID: profileID,
            scheduler: clock,
            runtimePermissions: { true },
            actionPerformer: { _, _, configured in
                performed.append(configured)
                return true
            },
            diagnosticLogger: { _ in }
        )
        monitor.connectSimulatedDevice(fingerprint: "google", profileID: profileID)
        defer { monitor.disconnectSimulatedDevice() }

        func tapOK() {
            monitor.handleSimulatedGoogleReport(
                reportID: 1,
                data: Data([1, 7, 0]),
                descriptor: G9N9NProtocol.indexedConsumerDescriptor
            )
            monitor.handleSimulatedGoogleReport(
                reportID: 1,
                data: Data([1, 0, 0]),
                descriptor: G9N9NProtocol.indexedConsumerDescriptor
            )
        }

        front = claude
        tapOK()
        front = codex
        tapOK()
        front = notes
        tapOK()

        #expect(performed.count == 3)
        #expect(performed[0].shortcut == nextSession)
        #expect(performed[1].shortcut == nextChat)
        #expect(performed[2].action == baseOK)
    }

    @Test func holdRepeatAndDirectPassthroughRespectPerAppOverrides() throws {
        let (settings, _) = makeSettings()

        let remoteID = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        settings.selectRemoteProfile(remoteID)

        var front: String? = notes
        settings.frontmostApplicationBundleIdentifier = { front }

        // Baseline: .volumeDown longPress defaults to .repeatSingleClick.
        #expect(settings.allowsHoldRepeat(for: .volumeDown, profileID: remoteID))

        // Case 1: overriding singleClick to .openURL suppresses default hold-repeat in that app.
        settings.addApplicationButtonProfile(bundleID: claude, name: "Claude")
        settings.setApplicationScopedAction(
            ConfiguredButtonAction(action: .openURL, shortcut: nil, urlString: "https://example.com"),
            bundleID: claude, button: .volumeDown, trigger: .singleClick
        )
        front = claude
        #expect(!settings.allowsHoldRepeat(for: .volumeDown, profileID: remoteID))
        front = notes
        #expect(settings.allowsHoldRepeat(for: .volumeDown, profileID: remoteID))

        // Case 2: overriding directional singleClick to .directPassthrough suppresses secondary triggers
        // identically in runtime dispatch, UI display (`applicationScopedAction`), and highlight state.
        settings.setBaseBinding(
            ConfiguredButtonAction(action: .escape, shortcut: nil),
            for: .up, trigger: .doubleClick, profileID: remoteID
        )
        settings.setApplicationScopedAction(
            ConfiguredButtonAction(action: .commandCopy, shortcut: nil),
            bundleID: claude, button: .up, trigger: .doubleClick
        )
        #expect(settings.applicationScopedAction(bundleID: claude, button: .up, trigger: .doubleClick).action == .commandCopy)
        #expect(settings.isApplicationOverride(bundleID: claude, button: .up, trigger: .doubleClick))

        settings.setApplicationScopedAction(
            ConfiguredButtonAction(action: .directPassthrough, shortcut: nil),
            bundleID: claude, button: .up, trigger: .singleClick
        )
        front = claude
        #expect(settings.configuredAction(for: .up, trigger: .singleClick, profileID: remoteID).action == .directPassthrough)
        #expect(settings.configuredAction(for: .up, trigger: .doubleClick, profileID: remoteID).action == .disabled)
        #expect(settings.applicationScopedAction(bundleID: claude, button: .up, trigger: .singleClick).action == .directPassthrough)
        #expect(settings.applicationScopedAction(bundleID: claude, button: .up, trigger: .doubleClick).action == .disabled)
        #expect(!settings.isApplicationOverride(bundleID: claude, button: .up, trigger: .doubleClick))
        front = notes
        #expect(settings.configuredAction(for: .up, trigger: .doubleClick, profileID: remoteID).action == .escape)
    }

    @Test func partialAndCorruptedJSONHandlingSurfacesNotice() throws {
        let minimalJSON = #"{"com.openai.codex":{"name":"Codex"}}"#
        let decoded = try JSONDecoder().decode([String: ApplicationButtonProfile].self, from: Data(minimalJSON.utf8))
        #expect(decoded[codex]?.name == "Codex")
        #expect(decoded[codex]?.buttons.isEmpty == true)

        let defaults = EphemeralUserDefaults()
        defaults.set(Data("{invalid-json".utf8), forKey: AppSettings.Keys.applicationButtonProfiles)

        let settings = AppSettings(defaults: defaults)
        #expect(settings.corruptedSettingKeys.contains(AppSettings.Keys.applicationButtonProfiles))
        #expect(CorruptedSettingsNotice.affectedItemKeys(for: settings.corruptedSettingKeys)
            == [CorruptedSettingsNotice.buttonMappingItemKey])
    }

    @Test func mappingEditingHelpersAddClearResetOrderAndParseAppIdentity() throws {
        let (settings, _) = makeSettings()

        let remoteID = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        settings.selectRemoteProfile(remoteID)

        settings.addApplicationButtonProfile(bundleID: "com.zeta.app", name: "Beta")
        settings.addApplicationButtonProfile(bundleID: codex, name: "Codex")
        settings.addApplicationButtonProfile(bundleID: claude, name: "Claude")
        settings.addApplicationButtonProfile(bundleID: "com.alpha.app", name: "Beta")
        #expect(settings.sortedApplicationButtonProfiles.map(\.bundleID)
            == ["com.alpha.app", "com.zeta.app", claude, codex, AppSettings.defaultChromecastSafariBundleID])

        // Double-click override can be cleared explicitly and keeps the app profile.
        settings.setApplicationScopedAction(
            ConfiguredButtonAction(action: .commandUndo, shortcut: nil),
            bundleID: claude, button: .ok, trigger: .doubleClick
        )
        #expect(settings.isApplicationOverride(bundleID: claude, button: .ok, trigger: .doubleClick))
        settings.clearApplicationOverride(bundleID: claude, button: .ok, trigger: .doubleClick)
        #expect(!settings.isApplicationOverride(bundleID: claude, button: .ok, trigger: .doubleClick))
        #expect(settings.applicationButtonProfiles[claude] != nil)

        // Setting the action back to the remote's own base action removes the override.
        settings.setApplicationScopedAction(
            ConfiguredButtonAction(action: .commandUndo, shortcut: nil),
            bundleID: codex, button: .input, trigger: .singleClick
        )
        #expect(settings.isApplicationOverride(bundleID: codex, button: .input, trigger: .singleClick))
        let baseInput = settings.configuredBaseAction(for: .input, trigger: .singleClick)
        settings.setApplicationScopedAction(baseInput, bundleID: codex, button: .input, trigger: .singleClick)
        #expect(!settings.isApplicationOverride(bundleID: codex, button: .input, trigger: .singleClick))
        #expect(settings.applicationButtonProfiles[codex]?.buttons.isEmpty == true)

        // Re-adding an existing app keeps existing overrides.
        settings.setApplicationScopedAction(
            ConfiguredButtonAction(action: .commandUndo, shortcut: nil),
            bundleID: codex, button: .input, trigger: .singleClick
        )
        settings.addApplicationButtonProfile(bundleID: codex, name: "Other Name")
        #expect(settings.isApplicationOverride(bundleID: codex, button: .input, trigger: .singleClick))
        #expect(settings.applicationButtonProfiles[codex]?.name == "Codex")

        // Resetting base bindings preserves per-app overrides on the remote.
        settings.resetBindings()
        #expect(settings.isApplicationOverride(bundleID: codex, button: .input, trigger: .singleClick))

        // Removing the profile deletes only that app.
        settings.removeApplicationButtonProfile(bundleID: codex)
        #expect(settings.applicationButtonProfiles[codex] == nil)
        #expect(settings.applicationButtonProfiles[claude] != nil)

        // Identity helper reads an application bundle cleanly without corrupting ".app" substrings.
        let finderURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        let identity = ApplicationButtonProfiles.applicationIdentity(at: finderURL)
        #expect(identity?.bundleID == "com.apple.finder")
        #expect(identity?.name.hasSuffix(".app") == false)
    }

    @Test func deferredAndRepeatingAppOverridesCancelWhenFocusMovesToAnotherApp() throws {
        let (settings, _) = makeSettings()

        settings.onboardingStep = .complete
        let profileID = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        settings.selectRemoteProfile(profileID)
        settings.setBaseBinding(
            ConfiguredButtonAction(action: .commandUndo, shortcut: nil),
            for: .ok, trigger: .doubleClick, profileID: profileID
        )

        let closeTab = CustomKeyboardShortcut(keyCode: 13, modifierFlags: .command, keyLabel: "W")
        var front: String? = claude
        settings.frontmostApplicationBundleIdentifier = { front }

        settings.addApplicationButtonProfile(bundleID: claude, name: "Claude")
        settings.setApplicationScopedAction(
            ConfiguredButtonAction(action: .customShortcut, shortcut: closeTab),
            bundleID: claude, button: .ok, trigger: .singleClick
        )
        settings.setApplicationScopedAction(
            ConfiguredButtonAction(action: .escape, shortcut: nil),
            bundleID: claude, button: .ok, trigger: .longPress
        )
        settings.setApplicationScopedAction(
            ConfiguredButtonAction(action: .customShortcut, shortcut: nextSession),
            bundleID: claude, button: .volumeDown, trigger: .singleClick
        )

        settings.addApplicationButtonProfile(bundleID: codex, name: "Codex")
        settings.setApplicationScopedAction(
            ConfiguredButtonAction(action: .customShortcut, shortcut: nextChat),
            bundleID: codex, button: .ok, trigger: .singleClick
        )
        settings.setApplicationScopedAction(
            ConfiguredButtonAction(action: .commandCopy, shortcut: nil),
            bundleID: codex, button: .ok, trigger: .longPress
        )

        #expect(settings.allowsHoldRepeat(for: .volumeDown, profileID: profileID))

        let clock = ControlledTestScheduler()
        var performed: [ConfiguredButtonAction] = []
        let monitor = HIDRemoteMonitor(
            settings: settings,
            profileID: profileID,
            scheduler: clock,
            runtimePermissions: { true },
            actionPerformer: { _, _, configured in
                performed.append(configured)
                return true
            },
            diagnosticLogger: { _ in }
        )
        monitor.connectSimulatedDevice(fingerprint: "google", profileID: profileID)
        defer { monitor.disconnectSimulatedDevice() }

        func sendButton(_ index: UInt8?) {
            monitor.handleSimulatedGoogleReport(
                reportID: 1,
                data: Data([1, index ?? 0, 0]),
                descriptor: G9N9NProtocol.indexedConsumerDescriptor
            )
        }

        // 1) Deferred single-click: tap OK in Claude, switch focus to Codex before timeout -> cancelled (not sent to Codex).
        front = claude
        sendButton(7)
        sendButton(nil)
        #expect(performed.isEmpty)
        front = codex
        clock.advance(to: clock.now + HIDRemoteTiming.doubleClickMilliseconds)
        #expect(performed.isEmpty)

        // 2) Long-press: hold OK in Claude, switch focus to Codex before timeout -> cancelled (not sent to Codex).
        front = claude
        sendButton(7)
        front = codex
        clock.advance(to: clock.now + HIDRemoteTiming.longPressMilliseconds)
        sendButton(nil)
        #expect(performed.isEmpty)

        // 3) Hold-repeat: hold Volume Down in Claude (fires initial press), switch focus to Codex -> repeats cancelled.
        front = claude
        sendButton(13)
        #expect(performed.count == 1)
        #expect(performed[0].shortcut == nextSession)
        front = codex
        clock.advance(to: clock.now + HIDRemoteTiming.repeatStartMilliseconds + 500)
        sendButton(nil)
        #expect(performed.count == 1)

        // 4) Staying in the captured app continues to deliver deferred clicks and repeats normally.
        front = codex
        sendButton(7)
        sendButton(nil)
        clock.advance(to: clock.now + HIDRemoteTiming.doubleClickMilliseconds)
        #expect(performed.count == 2)
        #expect(performed[1].shortcut == nextChat)

        front = claude
        sendButton(7)
        sendButton(nil)
        clock.advance(to: clock.now + HIDRemoteTiming.doubleClickMilliseconds)
        #expect(performed.count == 3)
        #expect(performed[2].shortcut == closeTab)

        sendButton(13)
        #expect(performed.count == 4)
        clock.advance(to: clock.now + HIDRemoteTiming.repeatStartMilliseconds)
        sendButton(nil)
        #expect(performed.count >= 5)
        #expect(performed[4].shortcut == nextSession)
    }

    @Test func appScopedHoldRepeatMatchesRuntimeAndAllowsExplicitRepeatAfterOpenURL() throws {
        let (settings, _) = makeSettings()

        let remoteID = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        settings.selectRemoteProfile(remoteID)
        let front = claude
        settings.frontmostApplicationBundleIdentifier = { front }

        settings.addApplicationButtonProfile(bundleID: claude, name: "Claude")
        settings.setApplicationScopedAction(
            ConfiguredButtonAction(action: .openURL, shortcut: nil, urlString: "https://example.com"),
            bundleID: claude, button: .volumeDown, trigger: .singleClick
        )

        // P2 #1: Editor/display and runtime must both disable default hold-repeat after openURL.
        #expect(settings.applicationScopedAction(bundleID: claude, button: .volumeDown, trigger: .longPress).action == .disabled)
        #expect(!settings.allowsHoldRepeat(for: .volumeDown, profileID: remoteID))
        #expect(!settings.isApplicationOverride(bundleID: claude, button: .volumeDown, trigger: .longPress))

        // Explicitly choosing Repeat Single Click stores an override and enables hold-repeat at runtime.
        settings.setApplicationScopedAction(
            ConfiguredButtonAction(action: .repeatSingleClick, shortcut: nil),
            bundleID: claude, button: .volumeDown, trigger: .longPress
        )
        #expect(settings.isApplicationOverride(bundleID: claude, button: .volumeDown, trigger: .longPress))
        #expect(settings.applicationScopedAction(bundleID: claude, button: .volumeDown, trigger: .longPress).action == .repeatSingleClick)
        #expect(settings.allowsHoldRepeat(for: .volumeDown, profileID: remoteID))

        // Restoring singleClick back to the remote's base action prunes the now-redundant Repeat override.
        settings.clearApplicationOverride(bundleID: claude, button: .volumeDown, trigger: .singleClick)
        #expect(!settings.isApplicationOverride(bundleID: claude, button: .volumeDown, trigger: .longPress))
        #expect(settings.allowsHoldRepeat(for: .volumeDown, profileID: remoteID))
    }

    @Test func selectingBaseActionDropsOverrideEvenWithStaleUnusedPayloadFields() throws {
        let (settings, _) = makeSettings()

        let remoteID = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        settings.selectRemoteProfile(remoteID)
        settings.frontmostApplicationBundleIdentifier = { claude }
        settings.addApplicationButtonProfile(bundleID: claude, name: "Claude")

        let baseOK = settings.configuredBaseAction(for: .ok, trigger: .singleClick)

        // Simulate SettingsView.setMappingAction retaining unused fields when switching back to baseOK.action:
        // 1) Stale custom shortcut.
        settings.setApplicationScopedAction(
            ConfiguredButtonAction(action: .customShortcut, shortcut: nextSession),
            bundleID: claude, button: .ok, trigger: .singleClick
        )
        settings.setApplicationScopedAction(
            ConfiguredButtonAction(action: baseOK.action, shortcut: nextSession),
            bundleID: claude, button: .ok, trigger: .singleClick
        )
        #expect(!settings.isApplicationOverride(bundleID: claude, button: .ok, trigger: .singleClick))

        // 2) Stale openURL string + customApplication profile ID.
        settings.setApplicationScopedAction(
            ConfiguredButtonAction(
                action: baseOK.action,
                shortcut: nil,
                applicationProfileID: UUID(),
                urlString: "https://example.com"
            ),
            bundleID: claude, button: .ok, trigger: .singleClick
        )
        #expect(!settings.isApplicationOverride(bundleID: claude, button: .ok, trigger: .singleClick))

        // Updating the remote's base OK binding now propagates to Claude because no ghost override remained.
        settings.setBaseBinding(
            ConfiguredButtonAction(action: .space, shortcut: nil),
            for: .ok, trigger: .singleClick, profileID: remoteID
        )
        #expect(settings.configuredAction(for: .ok, trigger: .singleClick, profileID: remoteID).action == .space)

        // Setting an app override and then changing the remote's base to match clears the override highlight.
        settings.setApplicationScopedAction(
            ConfiguredButtonAction(action: .commandCopy, shortcut: nil),
            bundleID: claude, button: .ok, trigger: .singleClick
        )
        #expect(settings.isApplicationOverride(bundleID: claude, button: .ok, trigger: .singleClick))
        settings.setBaseBinding(
            ConfiguredButtonAction(action: .commandCopy, shortcut: nil),
            for: .ok, trigger: .singleClick, profileID: remoteID
        )
        #expect(!settings.isApplicationOverride(bundleID: claude, button: .ok, trigger: .singleClick))
    }

    @Test func defaultActionDeferredClickAndRepeatCancelWhenDestinationAppDisablesOrChangesButton() throws {
        let (settings, _) = makeSettings()

        settings.onboardingStep = .complete
        let profileID = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        settings.selectRemoteProfile(profileID)

        let closeTab = CustomKeyboardShortcut(keyCode: 13, modifierFlags: .command, keyLabel: "W")
        settings.setBaseBinding(
            ConfiguredButtonAction(action: .customShortcut, shortcut: closeTab),
            for: .ok, trigger: .singleClick, profileID: profileID
        )
        settings.setBaseBinding(
            ConfiguredButtonAction(action: .commandUndo, shortcut: nil),
            for: .ok, trigger: .doubleClick, profileID: profileID
        )
        settings.setBaseBinding(
            ConfiguredButtonAction(action: .arrowDown, shortcut: nil),
            for: .volumeDown, trigger: .singleClick, profileID: profileID
        )

        var front: String? = notes
        settings.frontmostApplicationBundleIdentifier = { front }

        // Codex disables OK single-click and disables Volume Down repeat; Notes and Claude keep defaults.
        settings.addApplicationButtonProfile(bundleID: codex, name: "Codex")
        settings.setApplicationScopedAction(
            ConfiguredButtonAction.disabled,
            bundleID: codex, button: .ok, trigger: .singleClick
        )
        settings.setApplicationScopedAction(
            ConfiguredButtonAction.disabled,
            bundleID: codex, button: .volumeDown, trigger: .longPress
        )

        let clock = ControlledTestScheduler()
        var performed: [ConfiguredButtonAction] = []
        let monitor = HIDRemoteMonitor(
            settings: settings,
            profileID: profileID,
            scheduler: clock,
            runtimePermissions: { true },
            actionPerformer: { _, _, configured in
                performed.append(configured)
                return true
            },
            diagnosticLogger: { _ in }
        )
        monitor.connectSimulatedDevice(fingerprint: "google", profileID: profileID)
        defer { monitor.disconnectSimulatedDevice() }

        func sendButton(_ index: UInt8?) {
            monitor.handleSimulatedGoogleReport(
                reportID: 1,
                data: Data([1, index ?? 0, 0]),
                descriptor: G9N9NProtocol.indexedConsumerDescriptor
            )
        }

        // 1) Tap OK in Notes (uses default Command-W), switch to Codex (which disables OK) before timeout -> cancelled.
        front = notes
        sendButton(7)
        sendButton(nil)
        front = codex
        clock.advance(to: clock.now + HIDRemoteTiming.doubleClickMilliseconds)
        #expect(performed.isEmpty)

        // 2) Tap OK in Notes, switch to Codex when Codex overrides OK to a different action -> cancelled.
        settings.setApplicationScopedAction(
            ConfiguredButtonAction(action: .escape, shortcut: nil),
            bundleID: codex, button: .ok, trigger: .singleClick
        )
        front = notes
        sendButton(7)
        sendButton(nil)
        front = codex
        clock.advance(to: clock.now + HIDRemoteTiming.doubleClickMilliseconds)
        #expect(performed.isEmpty)

        // 3) Hold Volume Down in Notes (fires initial arrowDown), switch to Codex (which disables repeat) -> repeats cancelled.
        front = notes
        sendButton(13)
        #expect(performed.count == 1)
        #expect(performed[0].action == .arrowDown)
        front = codex
        clock.advance(to: clock.now + HIDRemoteTiming.repeatStartMilliseconds + 500)
        sendButton(nil)
        #expect(performed.count == 1)

        // 4) Switching between two apps that share the exact same default action still delivers cleanly.
        front = notes
        sendButton(7)
        sendButton(nil)
        front = claude
        clock.advance(to: clock.now + HIDRemoteTiming.doubleClickMilliseconds)
        #expect(performed.count == 2)
        #expect(performed[1].shortcut == closeTab)
    }

    @Test func changingDefaultToMatchOverridePrunesStorageAcrossConsecutiveDefaultChanges() throws {
        let (settings, _) = makeSettings()

        let xiaomiID = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        let g9n9nID = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        var front: String? = claude
        settings.frontmostApplicationBundleIdentifier = { front }

        // Selected remote: set Claude OK to Copy, change default to Copy, then change default to Undo.
        settings.selectRemoteProfile(g9n9nID)
        settings.addApplicationButtonProfile(bundleID: claude, name: "Claude")
        settings.setApplicationScopedAction(
            ConfiguredButtonAction(action: .commandCopy, shortcut: nil),
            bundleID: claude, button: .ok, trigger: .singleClick
        )

        settings.setBaseBinding(
            ConfiguredButtonAction(action: .commandCopy, shortcut: nil),
            for: .ok, trigger: .singleClick, profileID: g9n9nID
        )
        #expect(!settings.isApplicationOverride(bundleID: claude, button: .ok, trigger: .singleClick))
        #expect(settings.applicationButtonProfiles[claude]?.action(for: .ok, trigger: .singleClick) == nil)

        settings.setBaseBinding(
            ConfiguredButtonAction(action: .commandUndo, shortcut: nil),
            for: .ok, trigger: .singleClick, profileID: g9n9nID
        )
        front = claude
        #expect(settings.configuredAction(for: .ok, trigger: .singleClick, profileID: g9n9nID).action == .commandUndo)
        #expect(!settings.isApplicationOverride(bundleID: claude, button: .ok, trigger: .singleClick))

        // Non-selected remote: same consecutive default changes must prune stored overrides on Xiaomi too.
        settings.selectRemoteProfile(xiaomiID)
        settings.addApplicationButtonProfile(bundleID: claude, name: "Claude")
        settings.setApplicationScopedAction(
            ConfiguredButtonAction(action: .commandCopy, shortcut: nil),
            bundleID: claude, button: .ok, trigger: .singleClick
        )
        settings.selectRemoteProfile(g9n9nID)

        settings.setBaseBinding(
            ConfiguredButtonAction(action: .commandCopy, shortcut: nil),
            for: .ok, trigger: .singleClick, profileID: xiaomiID
        )
        #expect(settings.applicationButtonProfiles(for: xiaomiID)[claude]?.action(for: .ok, trigger: .singleClick) == nil)

        settings.setBaseBinding(
            ConfiguredButtonAction(action: .commandUndo, shortcut: nil),
            for: .ok, trigger: .singleClick, profileID: xiaomiID
        )
        #expect(settings.configuredAction(for: .ok, trigger: .singleClick, profileID: xiaomiID).action == .commandUndo)
    }

    @Test func heldArrowWithPerAppOverrideBypassesNativePassthroughAndCancelsRepeatOnFocusChange() throws {
        let (settings, _) = makeSettings()

        settings.onboardingStep = .complete
        let profileID = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        settings.selectRemoteProfile(profileID)

        var front: String? = notes
        settings.frontmostApplicationBundleIdentifier = { front }

        // Codex disables Right; Left has no per-app override anywhere on this remote.
        settings.addApplicationButtonProfile(bundleID: codex, name: "Codex")
        settings.setApplicationScopedAction(
            ConfiguredButtonAction.disabled,
            bundleID: codex, button: .right, trigger: .singleClick
        )

        var suppressorNow: TimeInterval = 1_000
        let suppressor = KeyboardEventSuppressor(
            uptime: { suppressorNow },
            permissionsGranted: { true },
            tapOperations: .init(start: { true }, stop: {}, isEnabled: { true })
        )

        let clock = ControlledTestScheduler()
        var performed: [ConfiguredButtonAction] = []
        let monitor = HIDRemoteMonitor(
            settings: settings,
            profileID: profileID,
            eventSuppressor: suppressor,
            scheduler: clock,
            runtimePermissions: { true },
            nativeSuppressionAvailable: { true },
            actionPerformer: { _, _, configured in
                performed.append(configured)
                return true
            },
            diagnosticLogger: { _ in }
        )
        monitor.connectSimulatedDevice(fingerprint: "rc003", profileID: profileID, isSeized: false)
        defer { monitor.disconnectSimulatedDevice() }

        func sendRC003(usage: UInt16?) {
            let value = usage ?? 0
            monitor.handleSimulatedReport(
                reportID: 1,
                data: Data([UInt8(value & 0xFF), UInt8(value >> 8)])
            )
        }

        func makeNativeArrowEvent(keyCode: CGKeyCode, down: Bool, autorepeat: Bool = false) throws -> CGEvent {
            let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down))
            if autorepeat {
                event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
            }
            return event
        }

        // 1) Hold Right in Notes: Right has a per-app override on Codex, so it bypasses native passthrough,
        // runs via the software path, and suppresses both the native keyDown and macOS autorepeats.
        front = notes
        sendRC003(usage: RemoteButton.right.hidUsage)
        #expect(performed.count == 1)
        #expect(performed[0].action == .arrowRight)
        #expect(!monitor.nativePassthroughUsages.contains(RemoteButton.right.hidUsage))
        #expect(suppressor.handle(type: .keyDown, event: try makeNativeArrowEvent(keyCode: 124, down: true)))
        #expect(suppressor.handle(type: .keyDown, event: try makeNativeArrowEvent(keyCode: 124, down: true, autorepeat: true)))

        // 2) Switch focus to Codex (where Right is disabled) while still holding Right:
        // software repeat timer cancels, and macOS native autorepeat remains suppressed.
        front = codex
        suppressorNow += 0.25
        clock.advance(to: clock.now + HIDRemoteTiming.repeatStartMilliseconds + 500)
        #expect(performed.count == 1)
        #expect(suppressor.handle(type: .keyDown, event: try makeNativeArrowEvent(keyCode: 124, down: true, autorepeat: true)))

        // Release Right and clean up the paired native up event.
        sendRC003(usage: nil)
        #expect(suppressor.handle(type: .keyUp, event: try makeNativeArrowEvent(keyCode: 124, down: false)))

        // 3) Left has no per-app override on this remote, so it still keeps native passthrough in Notes.
        front = notes
        sendRC003(usage: RemoteButton.left.hidUsage)
        #expect(performed.count == 1)
        #expect(monitor.nativePassthroughUsages.contains(RemoteButton.left.hidUsage))
        #expect(!suppressor.handle(type: .keyDown, event: try makeNativeArrowEvent(keyCode: 123, down: true)))
        sendRC003(usage: nil)
    }

    @Test func newChromecastRemoteSeedsDefaultSafariMappingAndResolvesAtRuntime() throws {
        let (settings, _) = makeSettings()
        settings.onboardingStep = .complete

        let xiaomiID = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        let t1ID = settings.registerBluetoothRemote(identifier: UUID(), model: .t1Remote)
        let g9n9nID = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)

        #expect(settings.applicationButtonProfiles(for: xiaomiID).isEmpty)
        #expect(settings.applicationButtonProfiles(for: t1ID).isEmpty)

        settings.selectRemoteProfile(g9n9nID)
        let safari = AppSettings.defaultChromecastSafariBundleID
        #expect(settings.applicationButtonProfiles[safari]?.name == "Safari")

        let expectedLeft = CustomKeyboardShortcut(keyCode: 33, modifierFlags: .command, keyLabel: "[")
        let expectedRight = CustomKeyboardShortcut(keyCode: 30, modifierFlags: .command, keyLabel: "]")
        var front: String? = safari
        settings.frontmostApplicationBundleIdentifier = { front }

        #expect(settings.configuredAction(for: .up, trigger: .singleClick, profileID: g9n9nID).action == .scrollUp)
        #expect(settings.configuredAction(for: .up, trigger: .longPress, profileID: g9n9nID).action == .repeatSingleClick)
        #expect(settings.configuredAction(for: .down, trigger: .singleClick, profileID: g9n9nID).action == .scrollDown)
        #expect(settings.configuredAction(for: .down, trigger: .longPress, profileID: g9n9nID).action == .repeatSingleClick)
        #expect(settings.configuredAction(for: .left, trigger: .singleClick, profileID: g9n9nID)
            == ConfiguredButtonAction(action: .customShortcut, shortcut: expectedLeft))
        #expect(settings.configuredAction(for: .left, trigger: .longPress, profileID: g9n9nID).action == .disabled)
        #expect(settings.configuredAction(for: .right, trigger: .singleClick, profileID: g9n9nID)
            == ConfiguredButtonAction(action: .customShortcut, shortcut: expectedRight))
        #expect(settings.configuredAction(for: .right, trigger: .longPress, profileID: g9n9nID).action == .disabled)

        // Global / other apps keep standard directional arrow keys.
        front = notes
        #expect(settings.configuredAction(for: .up, trigger: .singleClick, profileID: g9n9nID).action == .arrowUp)
        #expect(settings.configuredAction(for: .down, trigger: .singleClick, profileID: g9n9nID).action == .arrowDown)
        #expect(settings.configuredAction(for: .left, trigger: .singleClick, profileID: g9n9nID).action == .arrowLeft)
        #expect(settings.configuredAction(for: .right, trigger: .singleClick, profileID: g9n9nID).action == .arrowRight)

        let clock = ControlledTestScheduler()
        var performed: [ConfiguredButtonAction] = []
        let monitor = HIDRemoteMonitor(
            settings: settings,
            profileID: g9n9nID,
            scheduler: clock,
            runtimePermissions: { true },
            actionPerformer: { _, _, configured in
                performed.append(configured)
                return true
            },
            diagnosticLogger: { _ in }
        )
        monitor.connectSimulatedDevice(fingerprint: "google", profileID: g9n9nID)
        defer { monitor.disconnectSimulatedDevice() }

        func tap(_ index: UInt8) {
            monitor.handleSimulatedGoogleReport(
                reportID: 1,
                data: Data([1, index, 0]),
                descriptor: G9N9NProtocol.indexedConsumerDescriptor
            )
            monitor.handleSimulatedGoogleReport(
                reportID: 1,
                data: Data([1, 0, 0]),
                descriptor: G9N9NProtocol.indexedConsumerDescriptor
            )
            clock.advance(to: clock.now + HIDRemoteTiming.doubleClickMilliseconds)
        }

        front = safari
        tap(3) // up
        tap(4) // down
        tap(5) // left
        tap(6) // right
        front = notes
        tap(3) // up in Notes

        #expect(performed.count == 5)
        #expect(performed[0].action == .scrollUp)
        #expect(performed[1].action == .scrollDown)
        #expect(performed[2] == ConfiguredButtonAction(action: .customShortcut, shortcut: expectedLeft))
        #expect(performed[3] == ConfiguredButtonAction(action: .customShortcut, shortcut: expectedRight))
        #expect(performed[4].action == .arrowUp)

        // Holding Up in Safari repeats scrollUp; holding Left fires ⌘[ once without repeating history back.
        performed.removeAll()
        front = safari
        monitor.handleSimulatedGoogleReport(
            reportID: 1,
            data: Data([1, 3, 0]),
            descriptor: G9N9NProtocol.indexedConsumerDescriptor
        )
        clock.advance(to: clock.now + HIDRemoteTiming.repeatStartMilliseconds + 250)
        monitor.handleSimulatedGoogleReport(
            reportID: 1,
            data: Data([1, 0, 0]),
            descriptor: G9N9NProtocol.indexedConsumerDescriptor
        )
        let scrollUpCount = performed.count
        #expect(scrollUpCount >= 2)
        #expect(performed.allSatisfy { $0.action == .scrollUp })

        performed.removeAll()
        monitor.handleSimulatedGoogleReport(
            reportID: 1,
            data: Data([1, 5, 0]),
            descriptor: G9N9NProtocol.indexedConsumerDescriptor
        )
        clock.advance(to: clock.now + HIDRemoteTiming.repeatStartMilliseconds + 250)
        monitor.handleSimulatedGoogleReport(
            reportID: 1,
            data: Data([1, 0, 0]),
            descriptor: G9N9NProtocol.indexedConsumerDescriptor
        )
        #expect(performed.count == 1)
        #expect(performed[0] == ConfiguredButtonAction(action: .customShortcut, shortcut: expectedLeft))
    }

    @Test func legacyChromecastMigrationSeedsSafariOnceAndRespectsUserDeletion() throws {
        let defaults = EphemeralUserDefaults()
        let safari = AppSettings.defaultChromecastSafariBundleID

        // 1) Legacy G9N9N with no Safari profile + another legacy G9N9N that already has a custom Safari profile.
        let unseededGoogle = RemoteDeviceProfile(
            model: .chromecastVoiceRemote,
            bluetoothIdentifier: UUID(),
            mappings: RemoteDeviceMappings(
                buttonBindings: AppSettings.defaultMappings(for: .chromecastVoiceRemote).parsedButtonBindings,
                buttonShortcuts: [:],
                secondaryButtonBindings: [:]
            )
        )
        var customSafari = ApplicationButtonProfile(name: "Safari")
        customSafari.setAction(ConfiguredButtonAction(action: .commandCopy, shortcut: nil), for: .up, trigger: .singleClick)
        let customGoogle = RemoteDeviceProfile(
            model: .chromecastVoiceRemote,
            bluetoothIdentifier: UUID(),
            mappings: RemoteDeviceMappings(
                buttonBindings: AppSettings.defaultMappings(for: .chromecastVoiceRemote).parsedButtonBindings,
                buttonShortcuts: [:],
                secondaryButtonBindings: [:],
                applicationButtonProfiles: [safari: customSafari, claude: ApplicationButtonProfile(name: "Claude")]
            )
        )
        let xiaomi = RemoteDeviceProfile(
            model: .rc003,
            bluetoothIdentifier: UUID(),
            mappings: AppSettings.defaultMappings(for: .rc003)
        )

        let encoded = try JSONEncoder().encode([unseededGoogle, customGoogle, xiaomi])
        defaults.set(encoded, forKey: AppSettings.Keys.remoteDeviceProfiles)
        defaults.set(unseededGoogle.id.uuidString, forKey: AppSettings.Keys.selectedRemoteProfileID)

        // First launch after upgrade seeds Safari on unseededGoogle, preserves customGoogle, and skips Xiaomi.
        let migrated = AppSettings(defaults: defaults)
        #expect(migrated.applicationButtonProfiles[safari] == AppSettings.defaultChromecastSafariApplicationProfile)
        #expect(migrated.remoteDeviceProfiles[0].seededDefaultApplicationProfiles == [safari])
        #expect(migrated.applicationButtonProfiles(for: customGoogle.id)[safari]?.action(for: .up, trigger: .singleClick)?.action == .commandCopy)
        #expect(migrated.applicationButtonProfiles(for: customGoogle.id)[claude] != nil)
        #expect(migrated.remoteDeviceProfiles[1].seededDefaultApplicationProfiles == [safari])
        #expect(migrated.applicationButtonProfiles(for: xiaomi.id).isEmpty)

        // User explicitly deletes Safari from unseededGoogle; subsequent launches must NOT re-add it.
        migrated.removeApplicationButtonProfile(bundleID: safari)
        #expect(migrated.applicationButtonProfiles[safari] == nil)

        let relaunched = AppSettings(defaults: defaults)
        #expect(relaunched.applicationButtonProfiles[safari] == nil)
        #expect(relaunched.applicationButtonProfiles(for: relaunched.selectedRemoteProfileID)[safari] == nil)
        #expect(relaunched.remoteDeviceProfiles[0].seededDefaultApplicationProfiles == [safari])

        // Adding a new G9N9N later still gives that new remote its own default Safari profile.
        let thirdGoogle = relaunched.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        #expect(relaunched.applicationButtonProfiles(for: thirdGoogle)[safari] == AppSettings.defaultChromecastSafariApplicationProfile)
        #expect(relaunched.applicationButtonProfiles(for: unseededGoogle.id)[safari] == nil)

        // Identifying an .unknown profile as G9N9N seeds Safari once and also respects deletion across reload.
        let unknown = relaunched.registerBluetoothRemote(identifier: UUID(), model: .unknown)
        relaunched.updateRemoteProfileModel(unknown, model: .chromecastVoiceRemote)
        #expect(relaunched.applicationButtonProfiles(for: unknown)[safari] == AppSettings.defaultChromecastSafariApplicationProfile)
        relaunched.selectRemoteProfile(unknown)
        relaunched.removeApplicationButtonProfile(bundleID: safari)
        let afterUnknownDelete = AppSettings(defaults: defaults)
        #expect(afterUnknownDelete.applicationButtonProfiles(for: unknown)[safari] == nil)
    }
}
