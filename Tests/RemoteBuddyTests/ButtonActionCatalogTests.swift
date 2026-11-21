import CoreGraphics
import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Button action catalog, labels and preset applications")
struct ButtonActionCatalogTests {
    @MainActor
    @Test func allActionsAndPresetApplicationsResolveLocalizedNamesInBothLanguages() throws {
        let suite = "button-action-catalog-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LocalizationStore(settings: AppSettings(defaults: defaults))

        for language in [AppLanguage.english, .simplifiedChinese] {
            store.select(language)
            for action in ButtonAction.allCases {
                let name = action.displayName(using: store)
                #expect(!name.isEmpty, "Empty displayName for \(action) in \(language)")
                #expect(!name.hasPrefix("action."), "Unresolved key \(name) for \(action) in \(language)")
            }
            for application in PresetApplication.allCases {
                let name = application.displayName(using: store)
                #expect(!name.isEmpty, "Empty displayName for \(application) in \(language)")
                #expect(!name.hasPrefix("application."), "Unresolved key \(name) for \(application) in \(language)")
            }
            for shortKey in ["action.brightness_up_short", "action.brightness_down_short"] {
                let text = store.text(shortKey)
                #expect(text != shortKey, "Unresolved short key \(shortKey) in \(language)")
            }
        }
    }

    @MainActor
    @Test func shortcutActionsExposeDescriptiveNamesAndShortcutLabels() throws {
        let suite = "button-action-shortcuts-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LocalizationStore(settings: AppSettings(defaults: defaults))

        store.select(.simplifiedChinese)
        #expect(ButtonAction.appSwitcher.displayName(using: store) == "切换应用")
        #expect(ButtonAction.appSwitcher.shortcutDisplayLabel == "⌘Tab")
        #expect(ButtonAction.appSwitcher.detailedDisplayName(using: store) == "切换应用 (⌘Tab)")
        #expect(ButtonAction.missionControl.detailedDisplayName(using: store) == "调度中心 (⌃↑)")
        #expect(ButtonAction.notificationCenter.detailedDisplayName(using: store) == "通知中心 (fn N)")
        #expect(ButtonAction.showDesktop.detailedDisplayName(using: store) == "显示桌面 (fn F11)")
        #expect(ButtonAction.spotlight.detailedDisplayName(using: store) == "聚焦搜索 (⌘Space)")
        #expect(ButtonAction.spaceLeft.detailedDisplayName(using: store) == "上一桌面 (⌃←)")
        #expect(ButtonAction.spaceRight.detailedDisplayName(using: store) == "下一桌面 (⌃→)")
        #expect(ButtonAction.lockScreen.detailedDisplayName(using: store) == "锁定屏幕 (⌃⌘Q)")
        #expect(ButtonAction.screenshot.detailedDisplayName(using: store) == "截屏 (⇧⌘5)")
        #expect(ButtonAction.commandCopy.detailedDisplayName(using: store) == "复制 (⌘C)")
        #expect(ButtonAction.commandRefresh.detailedDisplayName(using: store) == "刷新 (⌘R)")
        #expect(ButtonAction.space.detailedDisplayName(using: store) == "空格 (Space)")
        #expect(ButtonAction.tab.detailedDisplayName(using: store) == "切换焦点 (⇥)")

        store.select(.english)
        #expect(ButtonAction.appSwitcher.detailedDisplayName(using: store) == "App Switcher (⌘Tab)")
        #expect(ButtonAction.missionControl.detailedDisplayName(using: store) == "Mission Control (⌃↑)")
        #expect(ButtonAction.notificationCenter.detailedDisplayName(using: store) == "Notification Center (fn N)")
        #expect(ButtonAction.commandCopy.detailedDisplayName(using: store) == "Copy (⌘C)")
        #expect(ButtonAction.commandRefresh.detailedDisplayName(using: store) == "Reload (⌘R)")

        // Non-shortcut actions should not display a shortcut badge
        #expect(ButtonAction.scrollUp.shortcutDisplayLabel == nil)
        #expect(ButtonAction.volumeUp.shortcutDisplayLabel == nil)
        #expect(ButtonAction.brightnessUp.shortcutDisplayLabel == nil)
        #expect(ButtonAction.openWorkBuddy.shortcutDisplayLabel == nil)
    }

    @Test func newBasicKeysAndBrightnessMediaKeysInjectExpectedEvents() {
        var keys: [(CGKeyCode, CGEventFlags)] = []
        #expect(KeyboardInjector.send(.space, accessibilityTrusted: { true }, secureInputEnabled: { false },
            keyPoster: { keys.append(($0, $1)) }))
        #expect(KeyboardInjector.send(.tab, accessibilityTrusted: { true }, secureInputEnabled: { false },
            keyPoster: { keys.append(($0, $1)) }))
        #expect(keys.count == 2)
        #expect(keys[0].0 == 49 && keys[0].1.isEmpty)
        #expect(keys[1].0 == 48 && keys[1].1.isEmpty)

        var mediaKeys: [Int32] = []
        #expect(KeyboardInjector.send(.brightnessUp, accessibilityTrusted: { true }, secureInputEnabled: { false },
            systemKeyPoster: { mediaKeys.append($0) }))
        #expect(KeyboardInjector.send(.brightnessDown, accessibilityTrusted: { true }, secureInputEnabled: { false },
            systemKeyPoster: { mediaKeys.append($0) }))
        #expect(mediaKeys == [2, 3])
    }

    @Test func secureInputPolicyClassifiesNewActionsCorrectly() {
        #expect(ButtonAction.space.requiresNonSecureInput == true)
        #expect(ButtonAction.tab.requiresNonSecureInput == true)
        for action: ButtonAction in [
            .commandRefresh, .missionControl, .notificationCenter, .spotlight, .spaceLeft, .spaceRight,
            .lockScreen, .screenshot, .brightnessUp, .brightnessDown,
            .openDeepSeekHarness, .openWorkBuddy, .openChatGPT, .openVSCode,
            .openGhostty, .openITerm2, .openTerminal, .openFeishu, .openDingTalk,
            .openAppleMusic, .openSpotify, .openFinder,
        ] {
            #expect(action.requiresNonSecureInput == false, "\(action) should not require non-secure input")
        }
        for action in ButtonAction.allCases {
            if action.presetApplication != nil {
                #expect(action.category == .applications)
                #expect(action.requiresNonSecureInput == false)
            } else {
                _ = action.category
            }
        }
    }

    @Test func presetApplicationsSupportAlternateBundleIdentifiersAndNewEntries() {
        #expect(PresetApplication.deepSeekHarness.bundleIdentifier == "com.deepseek.dsh")
        #expect(PresetApplication.workBuddy.bundleIdentifier == "com.tencent.workbuddy.mac")
        #expect(PresetApplication.workBuddy.isInstalled(in: ["com.tencent.workbuddy.mac"]))
        #expect(PresetApplication.workBuddy.isInstalled(in: ["com.workbuddy.workbuddy"]))
        #expect(PresetApplication.workBuddy.isInstalled(in: ["com.workbuddy.workbuddy-ai"]))
        #expect(PresetApplication.feishu.isInstalled(in: ["com.bytedance.macos.feishu"]))
        #expect(PresetApplication.feishu.isInstalled(in: ["com.electron.lark"]))
        #expect(PresetApplication.dingTalk.isInstalled(in: ["5ZSL2CJU2T.com.dingtalk.mac"]))
        #expect(PresetApplication.dingTalk.isInstalled(in: ["com.alibaba.DingTalkMac"]))

        let installed: Set<String> = [
            "com.deepseek.dsh",
            "com.workbuddy.workbuddy-ai",
            "com.bytedance.macos.feishu",
        ]
        let picker = ButtonAction.pickerActions(installedBundleIdentifiers: installed, current: .disabled)
        #expect(picker.contains(.openDeepSeekHarness))
        #expect(picker.contains(.openWorkBuddy))
        #expect(picker.contains(.openFeishu))
        #expect(!picker.contains(.openSpotify))

        nonisolated(unsafe) var openedURL: URL?
        KeyboardInjector.open(
            .workBuddy,
            focusRequestID: 1,
            applicationURL: { bundleID in
                bundleID == "com.workbuddy.workbuddy-ai" ? URL(fileURLWithPath: "/Applications/WorkBuddy AI.app") : nil
            },
            applicationOpener: { url, _, completion in
                openedURL = url
                completion(123, nil)
            },
            applicationFocuser: { _, _, _, _ in }
        )
        #expect(openedURL == URL(fileURLWithPath: "/Applications/WorkBuddy AI.app"))
    }
}
