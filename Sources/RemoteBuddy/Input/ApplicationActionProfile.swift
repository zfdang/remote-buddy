import AppKit
import Foundation
import IOKit.hidsystem

enum CustomApplicationFocusStrategy: String, Codable, CaseIterable, Identifiable {
    case none
    case keyboardShortcut
    case recordedAccessibility

    var id: String { rawValue }

    @MainActor
    func displayName(using localization: LocalizationStore) -> String {
        switch self {
        case .none: return localization.text("custom_application.focus.none")
        case .keyboardShortcut: return localization.text("custom_application.focus.shortcut")
        case .recordedAccessibility: return localization.text("custom_application.focus.recorded")
        }
    }
}

struct NormalizedAccessibilityFrame: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct AccessibilityFocusTarget: Codable, Equatable {
    let role: String
    let identifier: String
    let title: String
    let description: String
    let help: String
    let placeholder: String
    let context: String
    let windowTitle: String
    let normalizedFrame: NormalizedAccessibilityFrame?
}

struct CustomApplicationProfile: Codable, Equatable, Identifiable {
    let id: UUID
    var displayName: String
    var bundleIdentifier: String
    var applicationPath: String
    var focusStrategy: CustomApplicationFocusStrategy
    var focusShortcut: CustomKeyboardShortcut?
    var accessibilityTarget: AccessibilityFocusTarget?

    init(
        id: UUID = UUID(),
        displayName: String,
        bundleIdentifier: String,
        applicationPath: String,
        focusStrategy: CustomApplicationFocusStrategy = .none,
        focusShortcut: CustomKeyboardShortcut? = nil,
        accessibilityTarget: AccessibilityFocusTarget? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.applicationPath = applicationPath
        self.focusStrategy = focusStrategy
        self.focusShortcut = focusShortcut
        self.accessibilityTarget = accessibilityTarget
    }
}

enum ApplicationFocusStrategy: Equatable {
    case accessibilityComposer
    case cmuxSurfaceAPI
}

enum PresetApplication: String, CaseIterable, Identifiable {
    case remoteMic
    case codex
    case claude
    case chatGPT
    case deepSeekHarness
    case workBuddy
    case cmux
    case cursor
    case vsCode
    case xcode
    case zed
    case ghostty
    case iTerm2
    case terminal
    case chrome
    case safari
    case weChat
    case weCom
    case feishu
    case dingTalk
    case slack
    case neteaseMusic
    case appleMusic
    case spotify
    case finder

    var id: String { rawValue }

    @MainActor
    func displayName(using localization: LocalizationStore) -> String {
        switch self {
        case .remoteMic: return localization.text("app.name")
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .chatGPT: return "ChatGPT"
        case .deepSeekHarness: return "DeepSeek Harness"
        case .workBuddy: return "WorkBuddy"
        case .cmux: return "cmux"
        case .cursor: return "Cursor"
        case .vsCode: return "VS Code"
        case .xcode: return "Xcode"
        case .zed: return "Zed"
        case .ghostty: return "Ghostty"
        case .iTerm2: return "iTerm2"
        case .terminal: return localization.text("application.terminal")
        case .chrome: return "Chrome"
        case .safari: return "Safari"
        case .weChat: return localization.text("application.wechat")
        case .weCom: return localization.text("application.wecom")
        case .feishu: return localization.text("application.feishu")
        case .dingTalk: return localization.text("application.dingtalk")
        case .slack: return "Slack"
        case .neteaseMusic: return localization.text("application.netease_music")
        case .appleMusic: return localization.text("application.apple_music")
        case .spotify: return "Spotify"
        case .finder: return localization.text("application.finder")
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .remoteMic: return "com.zfdang.remote-buddy"
        case .codex: return "com.openai.codex"
        case .claude: return "com.anthropic.claudefordesktop"
        case .chatGPT: return "com.openai.chat"
        case .deepSeekHarness: return "com.deepseek.dsh"
        case .workBuddy: return "com.tencent.workbuddy.mac"
        case .cmux: return "com.cmuxterm.app"
        case .cursor: return "com.todesktop.230313mzl4w4u92"
        case .vsCode: return "com.microsoft.VSCode"
        case .xcode: return "com.apple.dt.Xcode"
        case .zed: return "dev.zed.Zed"
        case .ghostty: return "com.mitchellh.ghostty"
        case .iTerm2: return "com.googlecode.iterm2"
        case .terminal: return "com.apple.Terminal"
        case .chrome: return "com.google.Chrome"
        case .safari: return "com.apple.Safari"
        case .weChat: return "com.tencent.xinWeChat"
        case .weCom: return "com.tencent.WeWorkMac"
        case .feishu: return "com.electron.lark"
        case .dingTalk: return "5ZSL2CJU2T.com.dingtalk.mac"
        case .slack: return "com.tinyspeck.slackmacgap"
        case .neteaseMusic: return "com.netease.163music"
        case .appleMusic: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        case .finder: return "com.apple.finder"
        }
    }

    var bundleIdentifiers: [String] {
        switch self {
        case .workBuddy:
            return ["com.tencent.workbuddy.mac", "com.workbuddy.workbuddy", "com.workbuddy.workbuddy-ai"]
        case .feishu:
            return ["com.electron.lark", "com.bytedance.macos.feishu"]
        case .dingTalk:
            return ["5ZSL2CJU2T.com.dingtalk.mac", "com.alibaba.DingTalkMac"]
        default:
            return [bundleIdentifier]
        }
    }

    func isInstalled(in installedBundleIdentifiers: Set<String>) -> Bool {
        bundleIdentifiers.contains { installedBundleIdentifiers.contains($0) }
    }

    var focusStrategy: ApplicationFocusStrategy? {
        switch self {
        case .codex, .claude: return .accessibilityComposer
        case .cmux: return .cmuxSurfaceAPI
        default: return nil
        }
    }

    static var installedBundleIdentifiers: Set<String> {
        var identifiers: Set<String> = [remoteMic.bundleIdentifier]
        for application in allCases {
            for bundleID in application.bundleIdentifiers {
                if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil {
                    identifiers.insert(bundleID)
                }
            }
        }
        return identifiers
    }
}

