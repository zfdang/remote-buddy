import AppKit
import Foundation
import IOKit.hidsystem

enum ButtonTrigger: String, CaseIterable, Codable, Identifiable {
    case singleClick
    case doubleClick
    case longPress

    var id: String { rawValue }

    @MainActor
    func displayName(using localization: LocalizationStore) -> String {
        switch self {
        case .singleClick: return localization.text("trigger.single_click")
        case .doubleClick: return localization.text("trigger.double_click")
        case .longPress: return localization.text("trigger.long_press")
        }
    }
}

struct ConfiguredButtonAction: Codable, Equatable {
    var action: ButtonAction
    var shortcut: CustomKeyboardShortcut?
    var applicationProfileID: UUID?
    var urlString: String?

    init(
        action: ButtonAction,
        shortcut: CustomKeyboardShortcut?,
        applicationProfileID: UUID? = nil,
        urlString: String? = nil
    ) {
        self.action = action
        self.shortcut = shortcut
        self.applicationProfileID = applicationProfileID
        self.urlString = urlString
    }

    static let disabled = ConfiguredButtonAction(action: .disabled, shortcut: nil)

    /// Returns a copy retaining only the payload field used by `action`, clearing
    /// stale fields left behind when switching from another action type.
    func normalizedForAction() -> ConfiguredButtonAction {
        ConfiguredButtonAction(
            action: action,
            shortcut: action == .customShortcut ? shortcut : nil,
            applicationProfileID: action == .openCustomApplication ? applicationProfileID : nil,
            urlString: action == .openURL ? CustomActionURLPolicy.normalizedInput(urlString) : nil
        )
    }
}

enum CustomActionURLPolicy {
    private static let blockedSchemes: Set<String> = [
        "file", "javascript", "data", "vbscript",
    ]
    private static let allowedCharacterSet = CharacterSet.urlQueryAllowed.union(
        CharacterSet(charactersIn: ":/?#[]@!$&'()*+,;=%")
    )

    static func normalizedInput(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func validatedURL(from raw: String?) -> URL? {
        guard let trimmed = normalizedInput(raw) else { return nil }
        let candidate = URL(string: trimmed)
            ?? trimmed.addingPercentEncoding(withAllowedCharacters: allowedCharacterSet).flatMap(URL.init(string:))
        guard let url = candidate,
              let scheme = url.scheme?.lowercased(),
              !blockedSchemes.contains(scheme),
              isValidScheme(scheme)
        else { return nil }

        if scheme == "http" || scheme == "https" {
            guard let host = url.host, !host.isEmpty else { return nil }
            return url
        }
        if scheme == "shortcuts",
           url.host?.lowercased() == "run-shortcut" {
            let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "name" })?
                .value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let name, !name.isEmpty else { return nil }
        }
        return url
    }

    static func summaryLabel(for raw: String?) -> String? {
        guard let url = validatedURL(from: raw) else {
            return normalizedInput(raw)
        }
        let scheme = url.scheme?.lowercased()
        if scheme == "shortcuts",
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let shortcutName = components.queryItems?.first(where: { $0.name == "name" })?.value,
           !shortcutName.isEmpty {
            return "shortcuts: \(shortcutName)"
        }
        if (scheme == "http" || scheme == "https"), let host = url.host, !host.isEmpty {
            return host
        }
        return url.absoluteString
    }

    private static func isValidScheme(_ scheme: String) -> Bool {
        guard let first = scheme.unicodeScalars.first,
              CharacterSet.letters.contains(first) else { return false }
        let validBody = CharacterSet.letters
            .union(.decimalDigits)
            .union(CharacterSet(charactersIn: "+.-"))
        return scheme.unicodeScalars.allSatisfy(validBody.contains)
    }
}


enum ButtonActionCategory: String, CaseIterable, Identifiable {
    case directPassthrough
    case basicKeys
    case systemAndMedia
    case applications
    case commonPhrases
    case custom

    var id: String { rawValue }

    var localizationKey: String {
        switch self {
        case .directPassthrough: return "action.direct_passthrough"
        case .basicKeys: return "button_mapping.action_group.basic_keys"
        case .systemAndMedia: return "button_mapping.action_group.system_and_media"
        case .applications: return "button_mapping.action_group.applications"
        case .commonPhrases: return "common_phrases.title"
        case .custom: return "button_mapping.action_group.custom"
        }
    }
}

enum ButtonAction: String, CaseIterable, Codable, Identifiable {
    case disabled
    // Basic keys: confirmation, navigation & deletion
    case returnKey
    case shiftReturn
    case commandReturn
    case escape
    case space
    case tab
    case deleteBackward
    case commandDelete
    // Basic keys: editing & clipboard
    case commandCopy
    case commandPaste
    case commandCut
    case commandSelectAll
    case commandUndo
    case commandRedo
    case commandFind
    case commandSave
    // Basic keys: window & app lifecycle
    case commandRefresh
    case commandClose
    case commandQuit
    // Basic keys: arrows & scrolling
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight
    case scrollUp
    case scrollDown
    // System & Media: macOS desktop & system navigation
    case appSwitcher
    case missionControl
    case showDesktop
    case notificationCenter
    case spotlight
    case spaceLeft
    case spaceRight
    case lockScreen
    case screenshot
    // System & Media: assistive & voice
    case focusInput
    case contextMenu
    case toggleLongRecording
    // System & Media: media, audio & display
    case playPause
    case previousCommandLeft
    case nextCommandRight
    case volumeUp
    case volumeDown
    case volumeMute
    case brightnessUp
    case brightnessDown
    // Common phrases
    case openCommonPhrases
    // Applications
    case openRemoteBuddy
    case openCodex
    case openClaude
    case openChatGPT
    case openDeepSeekHarness
    case openWorkBuddy
    case openCmux
    case openCursor
    case openVSCode
    case openXcode
    case openZed
    case openGhostty
    case openITerm2
    case openTerminal
    case openChrome
    case openSafari
    case openWeChat
    case openWeCom
    case openFeishu
    case openDingTalk
    case openSlack
    case openNeteaseMusic
    case openAppleMusic
    case openSpotify
    case openFinder
    case openCustomApplication
    // Custom & passthrough
    case customShortcut
    case openURL
    case repeatSingleClick
    case directPassthrough = "direct_passthrough"

    var id: String { rawValue }

    @MainActor
    func displayName(using localization: LocalizationStore) -> String {
        switch self {
        case .disabled: return localization.text("action.disabled")
        case .repeatSingleClick: return localization.text("action.repeat_single_click")
        case .returnKey: return localization.text("action.return_key")
        case .shiftReturn: return localization.text("action.shift_return")
        case .commandReturn: return localization.text("action.command_return")
        case .escape: return localization.text("action.escape")
        case .space: return localization.text("action.space")
        case .tab: return localization.text("action.tab")
        case .deleteBackward: return localization.text("action.delete_backspace")
        case .commandDelete: return localization.text("action.command_delete")
        case .commandCopy: return localization.text("action.command_copy")
        case .commandPaste: return localization.text("action.command_paste")
        case .commandCut: return localization.text("action.command_cut")
        case .commandSelectAll: return localization.text("action.command_select_all")
        case .commandUndo: return localization.text("action.command_undo")
        case .commandRedo: return localization.text("action.command_redo")
        case .commandFind: return localization.text("action.command_find")
        case .commandSave: return localization.text("action.command_save")
        case .commandRefresh: return localization.text("action.command_refresh")
        case .commandClose: return localization.text("action.command_close")
        case .commandQuit: return localization.text("action.command_quit")
        case .arrowUp: return localization.text("action.arrow_up")
        case .arrowDown: return localization.text("action.arrow_down")
        case .arrowLeft: return localization.text("action.arrow_left")
        case .arrowRight: return localization.text("action.arrow_right")
        case .directPassthrough: return localization.text("action.direct_passthrough")
        case .scrollUp: return localization.text("action.scroll_up")
        case .scrollDown: return localization.text("action.scroll_down")
        case .appSwitcher: return localization.text("action.app_switcher")
        case .missionControl: return localization.text("action.mission_control")
        case .showDesktop: return localization.text("action.show_desktop")
        case .notificationCenter: return localization.text("action.notification_center")
        case .spotlight: return localization.text("action.spotlight")
        case .spaceLeft: return localization.text("action.space_left")
        case .spaceRight: return localization.text("action.space_right")
        case .lockScreen: return localization.text("action.lock_screen")
        case .screenshot: return localization.text("action.screenshot")
        case .contextMenu: return localization.text("action.context_menu")
        case .focusInput: return localization.text("action.focus_input")
        case .toggleLongRecording: return localization.text("action.toggle_long_recording")
        case .playPause: return localization.text("action.play_pause")
        case .previousCommandLeft: return localization.text("action.previous_command_left")
        case .nextCommandRight: return localization.text("action.next_command_right")
        case .volumeUp: return localization.text("action.system_volume_up")
        case .volumeDown: return localization.text("action.system_volume_down")
        case .volumeMute: return localization.text("action.system_mute")
        case .brightnessUp: return localization.text("action.brightness_up")
        case .brightnessDown: return localization.text("action.brightness_down")
        case .customShortcut: return localization.text("action.custom_shortcut")
        case .openURL: return localization.text("action.open_url")
        case .openCustomApplication: return localization.text("action.open_custom_application")
        case .openCommonPhrases: return localization.text("action.open_common_phrases")
        case .openRemoteBuddy: return localization.text("action.open_remote_mic")
        case .openCodex: return localization.text("action.open_codex")
        case .openClaude: return localization.text("action.open_claude")
        case .openChatGPT: return localization.text("action.open_chatgpt")
        case .openDeepSeekHarness: return localization.text("action.open_deepseek_harness")
        case .openWorkBuddy: return localization.text("action.open_workbuddy")
        case .openCmux: return localization.text("action.open_cmux")
        case .openCursor: return localization.text("action.open_cursor")
        case .openVSCode: return localization.text("action.open_vscode")
        case .openXcode: return localization.text("action.open_xcode")
        case .openZed: return localization.text("action.open_zed")
        case .openGhostty: return localization.text("action.open_ghostty")
        case .openITerm2: return localization.text("action.open_iterm2")
        case .openTerminal: return localization.text("action.open_terminal")
        case .openChrome: return localization.text("action.open_chrome")
        case .openSafari: return localization.text("action.open_safari")
        case .openWeChat: return localization.text("action.open_wechat")
        case .openWeCom: return localization.text("action.open_wecom")
        case .openFeishu: return localization.text("action.open_feishu")
        case .openDingTalk: return localization.text("action.open_dingtalk")
        case .openSlack: return localization.text("action.open_slack")
        case .openNeteaseMusic: return localization.text("action.open_netease_music")
        case .openAppleMusic: return localization.text("action.open_apple_music")
        case .openSpotify: return localization.text("action.open_spotify")
        case .openFinder: return localization.text("action.open_finder")
        }
    }

    var shortcutDisplayLabel: String? {
        switch self {
        case .returnKey: return "↩"
        case .shiftReturn: return "⇧↩"
        case .commandReturn: return "⌘↩"
        case .escape: return "Esc"
        case .space: return "Space"
        case .tab: return "⇥"
        case .deleteBackward: return "⌫"
        case .commandDelete: return "⌘⌫"
        case .commandCopy: return "⌘C"
        case .commandPaste: return "⌘V"
        case .commandCut: return "⌘X"
        case .commandSelectAll: return "⌘A"
        case .commandUndo: return "⌘Z"
        case .commandRedo: return "⇧⌘Z"
        case .commandFind: return "⌘F"
        case .commandSave: return "⌘S"
        case .commandRefresh: return "⌘R"
        case .commandClose: return "⌘W"
        case .commandQuit: return "⌘Q"
        case .arrowUp: return "↑"
        case .arrowDown: return "↓"
        case .arrowLeft: return "←"
        case .arrowRight: return "→"
        case .appSwitcher: return "⌘Tab"
        case .missionControl: return "⌃↑"
        case .showDesktop: return "fn F11"
        case .notificationCenter: return "fn N"
        case .spotlight: return "⌘Space"
        case .spaceLeft: return "⌃←"
        case .spaceRight: return "⌃→"
        case .lockScreen: return "⌃⌘Q"
        case .screenshot: return "⇧⌘5"
        default: return nil
        }
    }

    @MainActor
    func detailedDisplayName(using localization: LocalizationStore) -> String {
        let name = displayName(using: localization)
        guard let shortcut = shortcutDisplayLabel else { return name }
        return "\(name) (\(shortcut))"
    }

    var presetApplication: PresetApplication? {
        switch self {
        case .openRemoteBuddy: return .remoteMic
        case .openCodex: return .codex
        case .openClaude: return .claude
        case .openChatGPT: return .chatGPT
        case .openDeepSeekHarness: return .deepSeekHarness
        case .openWorkBuddy: return .workBuddy
        case .openCmux: return .cmux
        case .openCursor: return .cursor
        case .openVSCode: return .vsCode
        case .openXcode: return .xcode
        case .openZed: return .zed
        case .openGhostty: return .ghostty
        case .openITerm2: return .iTerm2
        case .openTerminal: return .terminal
        case .openChrome: return .chrome
        case .openSafari: return .safari
        case .openWeChat: return .weChat
        case .openWeCom: return .weCom
        case .openFeishu: return .feishu
        case .openDingTalk: return .dingTalk
        case .openSlack: return .slack
        case .openNeteaseMusic: return .neteaseMusic
        case .openAppleMusic: return .appleMusic
        case .openSpotify: return .spotify
        case .openFinder: return .finder
        default: return nil
        }
    }

    var category: ButtonActionCategory {
        if presetApplication != nil { return .applications }
        switch self {
        case .directPassthrough:
            return .directPassthrough
        case .disabled, .returnKey, .shiftReturn, .commandReturn, .escape, .space, .tab,
             .deleteBackward, .commandDelete, .commandCopy, .commandPaste, .commandCut,
             .commandSelectAll, .commandUndo, .commandRedo, .commandFind, .commandSave,
             .commandRefresh, .commandClose, .commandQuit, .arrowUp, .arrowDown, .arrowLeft, .arrowRight,
             .scrollUp, .scrollDown:
            return .basicKeys
        case .appSwitcher, .missionControl, .showDesktop, .notificationCenter, .spotlight,
             .spaceLeft, .spaceRight, .lockScreen, .screenshot, .contextMenu, .focusInput,
             .toggleLongRecording, .playPause, .previousCommandLeft, .nextCommandRight,
             .volumeUp, .volumeDown, .volumeMute, .brightnessUp, .brightnessDown:
            return .systemAndMedia
        case .openCommonPhrases:
            return .commonPhrases
        case .openCustomApplication:
            return .applications
        case .customShortcut, .openURL, .repeatSingleClick:
            return .custom
        default:
            preconditionFailure("Unhandled non-preset ButtonAction category: \(self)")
        }
    }

    var isAppInternal: Bool {
        self == .toggleLongRecording || self == .openCommonPhrases
    }

    static func pickerActions(
        installedBundleIdentifiers: Set<String>,
        current: ButtonAction,
        button: RemoteButton? = nil,
        trigger: ButtonTrigger? = nil
    ) -> [ButtonAction] {
        let actions = allCases.filter { action in
            if action == .directPassthrough {
                guard let button, button.isDirectional, trigger == nil || trigger == .singleClick else {
                    return action == current
                }
                return true
            }
            guard let application = action.presetApplication else { return true }
            return application.isInstalled(in: installedBundleIdentifiers) || action == current
        }
        return actions.filter { $0 != .openCustomApplication } +
            (actions.contains(.openCustomApplication) ? [.openCustomApplication] : [])
    }
}

