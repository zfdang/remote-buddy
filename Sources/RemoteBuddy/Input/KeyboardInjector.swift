import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

enum KeyboardInjector {
    typealias ApplicationOpener = @Sendable (
        URL,
        PresetApplication,
        @escaping @Sendable (pid_t?, Error?) -> Void
    ) -> Void
    typealias ApplicationFocuser = @Sendable (URL, PresetApplication, pid_t, UInt64) -> Void
    typealias CustomApplicationOpener = @Sendable (
        URL,
        CustomApplicationProfile,
        @escaping @Sendable (pid_t?, Error?) -> Void
    ) -> Void
    typealias CustomApplicationFocuser = @Sendable (CustomApplicationProfile, pid_t, UInt64) -> Void
    typealias CmuxCommandRunner = (URL, [String], TimeInterval) -> CmuxCommandResult
    typealias KeyPoster = (CGKeyCode, CGEventFlags) -> Void
    typealias KeyStatePoster = (CGKeyCode, Bool, CGEventFlags) -> Bool
    typealias ScrollPoster = (Int32) -> Void
    typealias SystemKeyPoster = (Int32) -> Void


    private static let transientAppSwitcher = AppSwitcherSession()

    struct AccessibilityTextCandidate: Equatable {
        let subrole: String
        let protectedContent: Bool
        let role: String
        let identifier: String
        let title: String
        let description: String
        let help: String
        let placeholder: String
        let context: String
        let frame: CGRect?
        let enabled: Bool
        let focused: Bool
        let selectedContext: Bool
        let hasWorkBuddyComposerControls: Bool

        init(
            role: String,
            subrole: String = "",
            protectedContent: Bool = false,
            identifier: String,
            title: String,
            description: String,
            help: String,
            placeholder: String,
            context: String,
            frame: CGRect?,
            enabled: Bool,
            focused: Bool = false,
            selectedContext: Bool = false,
            hasWorkBuddyComposerControls: Bool = false
        ) {
            self.subrole = subrole
            self.protectedContent = protectedContent
            self.role = role
            self.identifier = identifier
            self.title = title
            self.description = description
            self.help = help
            self.placeholder = placeholder
            self.context = context
            self.frame = frame
            self.enabled = enabled
            self.focused = focused
            self.selectedContext = selectedContext
            self.hasWorkBuddyComposerControls = hasWorkBuddyComposerControls
        }
    }

    struct CmuxCommandResult: Equatable {
        let terminationStatus: Int32
        let standardOutput: Data
        let timedOut: Bool
    }

    static let syntheticEventMarker: Int64 = 0x5849_414F
    static let orderedVoiceEventMarker: Int64 = 0x5849_4156

    static func isSyntheticEvent(_ event: CGEvent) -> Bool {
        let marker = event.getIntegerValueField(.eventSourceUserData)
        return isSyntheticEventMarker(marker)
    }
    static func isSyntheticEventMarker(_ marker: Int64) -> Bool {
        marker == syntheticEventMarker || marker == orderedVoiceEventMarker
    }
    static let contextualMenuKeyCode: CGKeyCode = 110
    static let functionKeyCode: CGKeyCode = 63
    static let leftCommandKeyCode: CGKeyCode = 55
    static let rightCommandKeyCode: CGKeyCode = 54
    /// Undocumented framework-specific attributes retained for explicit focus
    /// actions. Automatic voice integrations never set these attributes.
    /// Web content shells only build the accessibility tree once an assistive
    /// client announces itself, so the composer scan finds an empty shell until
    /// one of these attributes is set. `AXManualAccessibility` is the Chromium
    /// and Electron convention and is tried first, because the
    /// `AXEnhancedUserInterface` attribute is known to distort windows
    /// and animations on some Electron versions. Shells that are not Chromium
    /// based answer `attributeUnsupported` for the first attribute and only
    /// respond to the fallback attribute, so it is used as a fallback for exactly
    /// those apps.
    static let manualAccessibilityAttribute = "AXManualAccessibility"
    static let enhancedUserInterfaceAttribute = "AXEnhancedUserInterface"
    /// The web content tree needs about one to two seconds after the attribute
    /// is set, so the composer scan keeps retrying for longer than that.
    static let composerFocusMaximumAttempts = 12
    static let composerFocusRetryMilliseconds = 250
    static let weChatBundleIdentifier = "com.tencent.xinWeChat"
    static let weChatComposerHorizontalRatio = 0.68
    static let weChatComposerVerticalRatio = 0.85
    /// One scroll action moves the conversation by this many lines; the 100ms
    /// repeat interval turns a held D-pad key into a steady scroll.
    static let scrollLineCount: Int32 = 3
    static let focusRequests = ApplicationFocusRequestGate()
    static let frontmostFocusRequests = ApplicationFocusRequestGate()
    static let focusQueue = DispatchQueue(
        label: "RemoteBuddy.application-focus",
        qos: .userInitiated
    )
    static let accessibilityChildAttributes = [
        "AXChildrenInNavigationOrder",
        kAXVisibleChildrenAttribute,
        kAXContentsAttribute,
        kAXChildrenAttribute,
    ]
    static let maximumAccessibilityTraversalCount = 5_000

    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestAccessibilityAccess() -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    static func setFunctionKeyPressed(
        _ isPressed: Bool,
        accessibilityTrusted: () -> Bool = { isAccessibilityTrusted },
        keyStatePoster: @escaping KeyStatePoster = postVoiceKeyState
    ) -> Bool {
        setVoiceKeyPressed(
            .function,
            isPressed: isPressed,
            accessibilityTrusted: accessibilityTrusted,
            keyStatePoster: keyStatePoster
        )
    }

    @discardableResult
    static func setVoiceKeyPressed(
        _ mode: VoiceKeyMode,
        isPressed: Bool,
        accessibilityTrusted: () -> Bool = { isAccessibilityTrusted },
        keyStatePoster: @escaping KeyStatePoster = postVoiceKeyState,
        secureInputEnabled: () -> Bool = SecureInputMonitor.isEnabled,
        shortcutSession: HeldVoiceShortcut = .shared,
        shortcutKeyStatePoster: @escaping KeyStatePoster = postVoiceShortcutState,
        shortcutHardwareFlags: @escaping () -> CGEventFlags = KeyboardHardwareModifierPolicy.currentForVoiceShortcut
    ) -> Bool {
        guard !isPressed || !secureInputEnabled() else { return false }
        guard accessibilityTrusted() else { return false }
        if case let .shortcut(shortcut) = mode {
            return shortcutSession.setPressed(isPressed, shortcut: shortcut, post: shortcutKeyStatePoster,
                hardwareFlags: shortcutHardwareFlags)
        }
        let flags = isPressed ? mode.eventFlags : []
        return keyStatePoster(
            mode.keyCode,
            isPressed,
            flags
        )
    }

    @discardableResult
    static func send(
        _ action: ButtonAction,
        shortcut: CustomKeyboardShortcut? = nil,
        applicationProfile: CustomApplicationProfile? = nil,
        applicationURL: (String) -> URL? = {
            if $0 == PresetApplication.remoteMic.bundleIdentifier {
                return Bundle.main.bundleURL
            }
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        },
        applicationOpener: ApplicationOpener = { openApplication(at: $0, application: $1, completion: $2) },
        applicationFocuser: @escaping ApplicationFocuser = {
            focusApplication(at: $0, application: $1, processIdentifier: $2, requestID: $3)
        },
        customApplicationURL: (CustomApplicationProfile) -> URL? = resolveCustomApplicationURL,
        customApplicationOpener: CustomApplicationOpener = {
            openCustomApplication(at: $0, application: $1, completion: $2)
        },
        customApplicationFocuser: @escaping CustomApplicationFocuser = {
            focusCustomApplication(application: $0, processIdentifier: $1, requestID: $2)
        },
        frontmostComposerFocuser: (@escaping @Sendable (Bool) -> Void) -> Bool = focusFrontmostComposer,
        focusInputCompletion: @escaping @Sendable (Bool) -> Void = { _ in },
        accessibilityTrusted: () -> Bool = { isAccessibilityTrusted },
        secureInputEnabled: () -> Bool = SecureInputMonitor.isEnabled,
        keyPoster: KeyPoster = { postKey(code: $0, flags: $1) },
        keyStatePoster: @escaping KeyStatePoster = postKeyState,
        modifierReleaseRecovery: StandaloneModifierReleaseRecovery = .shared,
        appSwitcherSession: AppSwitcherSession? = nil,
        scrollPoster: ScrollPoster = { postScrollWheel(lines: $0) },
        systemKeyPoster: SystemKeyPoster = postSystemKey,
        shortcutEventPoster: @escaping (CGEvent) -> Bool = ShortcutEventSequence.post,
        shortcutHardwareFlags: @escaping () -> CGEventFlags = KeyboardHardwareModifierPolicy.currentForMappedAction
    ) -> Bool {
        guard action != .disabled else { return true }
        if action != .appSwitcher, transientAppSwitcher.isActive {
            guard transientAppSwitcher.confirm() else { return false }
        }
        guard !action.requiresNonSecureInput || !secureInputEnabled() else {
            AppLogger.shared.write("BUTTON ACTION blocked reason=secure_input action=\(action.rawValue)")
            return false
        }
        if action.isAppInternal {
            AppLogger.shared.write("INTERNAL ACTION ignored_by_keyboard action=\(action.rawValue)")
            return true
        }
        if let application = action.presetApplication {
            let focusRequestID = focusRequests.begin()
            open(
                application,
                focusRequestID: focusRequestID,
                applicationURL: applicationURL,
                applicationOpener: applicationOpener,
                applicationFocuser: applicationFocuser
            )
            return true
        }
        if action == .openCustomApplication {
            guard let applicationProfile else {
                AppLogger.shared.write("APP ACTION custom unavailable reason=profile_missing")
                return true
            }
            let focusRequestID = focusRequests.begin()
            open(
                applicationProfile,
                focusRequestID: focusRequestID,
                applicationURL: customApplicationURL,
                applicationOpener: customApplicationOpener,
                applicationFocuser: customApplicationFocuser
            )
            return true
        }
        if action == .focusInput {
            guard accessibilityTrusted() else { return false }
            return frontmostComposerFocuser(focusInputCompletion)
        }
        if action == .customShortcut, shortcut == nil {
            AppLogger.shared.write("SHORTCUT ACTION ignored reason=not_configured")
            return true
        }
        guard accessibilityTrusted() else { return false }

        switch action {
        case .disabled, .repeatSingleClick:
            return true
        case .escape:
            keyPoster(53, [])
        case .returnKey:
            keyPoster(36, [])
        case .commandReturn:
            return ShortcutEventSequence.send(keyCode: 36, modifiers: .maskCommand,
                hardwareFlags: shortcutHardwareFlags, eventPoster: shortcutEventPoster)
        case .shiftReturn:
            return ShortcutEventSequence.send(keyCode: 36, modifiers: .maskShift,
                hardwareFlags: shortcutHardwareFlags, eventPoster: shortcutEventPoster)
        case .commandCopy:
            return ShortcutEventSequence.send(keyCode: 8, modifiers: .maskCommand,
                hardwareFlags: shortcutHardwareFlags, eventPoster: shortcutEventPoster)
        case .commandPaste:
            return ShortcutEventSequence.send(keyCode: 9, modifiers: .maskCommand,
                hardwareFlags: shortcutHardwareFlags, eventPoster: shortcutEventPoster)
        case .commandClose:
            return ShortcutEventSequence.send(keyCode: 13, modifiers: .maskCommand,
                hardwareFlags: shortcutHardwareFlags, eventPoster: shortcutEventPoster)
        case .commandQuit:
            return ShortcutEventSequence.send(keyCode: 12, modifiers: .maskCommand,
                hardwareFlags: shortcutHardwareFlags, eventPoster: shortcutEventPoster)
        case .commandCut:
            return ShortcutEventSequence.send(keyCode: 7, modifiers: .maskCommand,
                hardwareFlags: shortcutHardwareFlags, eventPoster: shortcutEventPoster)
        case .commandSelectAll:
            return ShortcutEventSequence.send(keyCode: 0, modifiers: .maskCommand,
                hardwareFlags: shortcutHardwareFlags, eventPoster: shortcutEventPoster)
        case .commandUndo:
            return ShortcutEventSequence.send(keyCode: 6, modifiers: .maskCommand,
                hardwareFlags: shortcutHardwareFlags, eventPoster: shortcutEventPoster)
        case .commandRedo:
            return ShortcutEventSequence.send(keyCode: 6, modifiers: [.maskCommand, .maskShift],
                hardwareFlags: shortcutHardwareFlags, eventPoster: shortcutEventPoster)
        case .commandFind:
            return ShortcutEventSequence.send(keyCode: 3, modifiers: .maskCommand,
                hardwareFlags: shortcutHardwareFlags, eventPoster: shortcutEventPoster)
        case .commandSave:
            return ShortcutEventSequence.send(keyCode: 1, modifiers: .maskCommand,
                hardwareFlags: shortcutHardwareFlags, eventPoster: shortcutEventPoster)
        case .commandDelete:
            return ShortcutEventSequence.send(keyCode: 51, modifiers: .maskCommand,
                hardwareFlags: shortcutHardwareFlags, eventPoster: shortcutEventPoster)
        case .arrowUp:
            keyPoster(126, [])
        case .arrowDown:
            keyPoster(125, [])
        case .arrowLeft:
            keyPoster(123, [])
        case .arrowRight:
            keyPoster(124, [])
        case .scrollUp:
            scrollPoster(scrollLineCount)
        case .scrollDown:
            scrollPoster(-scrollLineCount)
        case .deleteBackward:
            keyPoster(51, [])
        case .showDesktop:
            return ShortcutEventSequence.send(keyCode: 103, modifiers: .maskSecondaryFn,
                hardwareFlags: shortcutHardwareFlags, eventPoster: shortcutEventPoster)
        case .contextMenu:
            keyPoster(contextualMenuKeyCode, [])
        case .appSwitcher:
            return (appSwitcherSession ?? transientAppSwitcher).triggerTemporarily()
        case .volumeUp:
            systemKeyPoster(0)
        case .volumeDown:
            systemKeyPoster(1)
        case .volumeMute:
            systemKeyPoster(7)
        case .playPause:
            systemKeyPoster(16)
        case .previousCommandLeft:
            systemKeyPoster(18)
        case .nextCommandRight:
            systemKeyPoster(17)
        case .customShortcut:
            if let shortcut {
                let eventFlags = shortcut.cgEventFlags
                if shortcut.standaloneModifier != nil {
                    guard modifierReleaseRecovery.permitsPress(CGKeyCode(shortcut.keyCode)) else { return false }
                    let pressed = keyStatePoster(
                        CGKeyCode(shortcut.keyCode),
                        true,
                        eventFlags
                    )
                    var released = keyStatePoster(CGKeyCode(shortcut.keyCode), false, [])
                    if !released {
                        released = keyStatePoster(CGKeyCode(shortcut.keyCode), false, [])
                        if !released {
                            AppLogger.shared.write("SHORTCUT ACTION cleanup_failed standalone=true recovery=scheduled")
                            modifierReleaseRecovery.recover(CGKeyCode(shortcut.keyCode), post: keyStatePoster)
                        }
                    }
                    let submitted = pressed && released
                    AppLogger.shared.write(
                        "SHORTCUT ACTION submitted key_code=\(shortcut.keyCode) " +
                            "modifier_flags=\(eventFlags.rawValue) standalone=true " +
                            "success=\(submitted)"
                    )
                    return submitted
                }
                if !eventFlags.isEmpty {
                    return ShortcutEventSequence.send(
                        keyCode: CGKeyCode(shortcut.keyCode),
                        modifiers: eventFlags,
                        hardwareFlags: shortcutHardwareFlags,
                        eventPoster: shortcutEventPoster
                    )
                }
                keyPoster(CGKeyCode(shortcut.keyCode), eventFlags)
                AppLogger.shared.write(
                    "SHORTCUT ACTION submitted key_code=\(shortcut.keyCode) " +
                        "modifier_flags=\(eventFlags.rawValue) standalone=false"
                )
            }
        case .focusInput:
            break
        case .openCustomApplication:
            break
        case .toggleLongRecording, .openCommonPhrases, .directPassthrough:
            break
        case .openRemoteBuddy, .openCodex, .openClaude, .openCmux, .openWeChat, .openCursor, .openXcode,
             .openSlack, .openWeCom, .openNeteaseMusic, .openChrome, .openSafari, .openZed:
            break
        }
        return true
    }
}

final class ApplicationFocusRequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var latestRequestID: UInt64 = 0

    func begin() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        latestRequestID &+= 1
        return latestRequestID
    }

    func isCurrent(_ requestID: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return requestID == latestRequestID
    }
}
