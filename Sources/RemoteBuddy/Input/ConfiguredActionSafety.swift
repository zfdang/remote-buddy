extension ButtonAction {
    /// Actions capable of inserting or editing text require a non-secure target.
    /// Cleanup and navigation stay available; key-up recovery bypasses send().
    var requiresNonSecureInput: Bool {
        switch self {
        case .returnKey, .commandReturn, .shiftReturn, .commandCopy, .commandPaste,
             .commandCut, .commandSelectAll, .commandUndo, .commandRedo, .commandFind,
             .commandSave, .commandDelete, .deleteBackward, .customShortcut:
            return true
        case .disabled, .escape, .commandClose, .commandQuit,
             .arrowUp, .arrowDown, .arrowLeft, .arrowRight, .scrollUp, .scrollDown,
             .showDesktop, .contextMenu, .appSwitcher, .focusInput,
             .volumeUp, .volumeDown, .volumeMute, .playPause,
             .previousCommandLeft, .nextCommandRight,
             .toggleLongRecording, .openCommonPhrases,
             .openCustomApplication, .openRemoteBuddy, .openCodex, .openClaude,
             .openCmux, .openWeChat, .openCursor, .openXcode, .openSlack,
             .openWeCom, .openNeteaseMusic, .openChrome, .openSafari, .openZed,
             .repeatSingleClick:
            return false
        }
    }
}
