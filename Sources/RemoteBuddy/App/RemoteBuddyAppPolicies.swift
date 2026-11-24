import AppKit
import Foundation

struct UnavailableVoiceToolAlertContent: Equatable {
    let title: String
    let message: String
    let openSettingsTitle: String
    let cancelTitle: String

    @MainActor
    init(
        prompt: BridgeAppModel.VoiceToolUnavailablePrompt,
        using localization: LocalizationStore
    ) {
        let toolName = localization.text(prompt.tool.titleKey)
        let titleKey: String
        let messageKey: String
        switch prompt.reason {
        case .unavailable:
            titleKey = "voice_tool.unavailable.alert.title"
            messageKey = "voice_tool.unavailable.alert.message"
        case .applicationUnavailable:
            titleKey = "voice_tool.unavailable.alert.title"
            messageKey = "voice_tool.application_unavailable.alert.message"
        case .switchFailed:
            titleKey = "voice_tool.switch_failed.alert.title"
            messageKey = "voice_tool.switch_failed.alert.message"
        }
        self.title = LocalizedMessage(titleKey, arguments: [toolName]).text(using: localization)
        self.message = LocalizedMessage(messageKey, arguments: [toolName]).text(using: localization)
        self.openSettingsTitle = localization.text("voice_tool.unavailable.alert.open_settings")
        self.cancelTitle = localization.text("common.action.cancel")
    }
}

final class UnavailableVoiceToolAlertCoordinator {
    private var isPresenting = false

    @MainActor
    func presentIfIdle(
        model: BridgeAppModel,
        localization: LocalizationStore,
        runModal: (UnavailableVoiceToolAlertContent) -> NSApplication.ModalResponse,
        openSettings: () -> Void
    ) {
        guard !isPresenting else { return }
        isPresenting = true
        defer { isPresenting = false }

        while let prompt = model.unavailableVoiceToolPrompt {
            model.unavailableVoiceToolPrompt = nil
            let content = UnavailableVoiceToolAlertContent(prompt: prompt, using: localization)
            if runModal(content) == .alertFirstButtonReturn {
                model.requestedSettingsSection = .integration
                openSettings()
                model.unavailableVoiceToolPrompt = nil
                break
            }
        }
    }
}

struct UpdateFeedSelection {
    let stableFeedURLString: String?

    init(stableFeedURLString: String?) {
        self.stableFeedURLString = stableFeedURLString
    }

    var feedURLString: String? {
        stableFeedURL?.absoluteString
    }

    var appcastAssetName: String {
        guard let name = stableFeedURL?.lastPathComponent
        else { return "appcast-arm64.xml" }
        return name
    }

    var validatedStableFeedURL: URL? {
        stableFeedURL
    }

    private var stableFeedURL: URL? {
        guard let stableFeedURLString,
              let components = URLComponents(string: stableFeedURLString),
              components.scheme == "https",
              components.host == "remote.zfdang.com",
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let url = components.url,
              ["/appcast-arm64.xml", "/appcast-intel.xml"].contains(components.path)
        else { return nil }
        return url
    }
}

struct UpdateCheckPolicy: Equatable {
    let receiveUpdateNotifications: Bool

    var enablesSparkleAutomaticChecks: Bool {
        false
    }

    var checksForUpdateInformationOnAboutAppear: Bool {
        receiveUpdateNotifications
    }
}

enum SettingsWindowActivationPolicy {
    static func value(
        showDockIcon: Bool,
        isSettingsWindowOpen: Bool
    ) -> NSApplication.ActivationPolicy {
        (showDockIcon || isSettingsWindowOpen) ? .regular : .accessory
    }

    static func shouldDeactivateOnClose(showDockIcon: Bool) -> Bool {
        !showDockIcon
    }
}

enum AppEntryPointVisibilityPolicy {
    static func shouldShowMainWindow(
        baseLaunchDecision: Bool,
        showDockIcon: Bool,
        showStatusBarIcon: Bool
    ) -> Bool {
        baseLaunchDecision || (!showDockIcon && !showStatusBarIcon)
    }
}

enum SettingsWindowDisplayPolicy {
    static func shouldMove(isOpen: Bool, currentScreen: Int?, targetScreen: Int?) -> Bool {
        !isOpen && targetScreen != nil && currentScreen != targetScreen
    }
}

enum StatusItemActionResolver {
    static func shouldShowMenu(
        eventType: NSEvent.EventType?,
        modifierFlags: NSEvent.ModifierFlags?
    ) -> Bool {
        eventType == .rightMouseUp || (modifierFlags?.contains(.control) == true)
    }
}

enum ApplicationShortcutAction: Equatable {
    case closeWindow
    case passThrough
}

enum ApplicationShortcutResolver {
    static func resolve(
        modifierFlags: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String?
    ) -> ApplicationShortcutAction {
        let relevantModifiers = modifierFlags.intersection([
            .command, .control, .option, .shift,
        ])
        guard relevantModifiers == .command else { return .passThrough }
        switch charactersIgnoringModifiers?.lowercased() {
        case "q", "w":
            return .closeWindow
        default:
            return .passThrough
        }
    }
}
