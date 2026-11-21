extension ButtonAction {
    /// Actions capable of inserting or editing text require a non-secure target.
    /// Cleanup and navigation stay available; key-up recovery bypasses send().
    var requiresNonSecureInput: Bool {
        switch self {
        case .returnKey, .commandReturn, .shiftReturn, .space, .tab,
             .commandCopy, .commandPaste, .commandCut, .commandSelectAll,
             .commandUndo, .commandRedo, .commandFind, .commandSave,
             .commandDelete, .deleteBackward, .customShortcut:
            return true
        case .disabled, .escape, .commandClose, .commandQuit,
             .arrowUp, .arrowDown, .arrowLeft, .arrowRight, .directPassthrough, .scrollUp, .scrollDown,
             .appSwitcher, .missionControl, .showDesktop, .notificationCenter, .spotlight,
             .spaceLeft, .spaceRight, .lockScreen, .screenshot, .contextMenu, .focusInput,
             .volumeUp, .volumeDown, .volumeMute, .brightnessUp, .brightnessDown,
             .playPause, .previousCommandLeft, .nextCommandRight,
             .toggleLongRecording, .openCommonPhrases,
             .openCustomApplication, .openRemoteBuddy, .openCodex, .openClaude,
             .openChatGPT, .openDeepSeekHarness, .openWorkBuddy,
             .openCmux, .openCursor, .openVSCode, .openXcode, .openZed,
             .openGhostty, .openITerm2, .openTerminal,
             .openChrome, .openSafari,
             .openWeChat, .openWeCom, .openFeishu, .openDingTalk, .openSlack,
             .openNeteaseMusic, .openAppleMusic, .openSpotify, .openFinder,
             .repeatSingleClick:
            return false
        }
    }
}
