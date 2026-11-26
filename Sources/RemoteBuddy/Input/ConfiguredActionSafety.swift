extension ButtonAction {
    /// Actions capable of inserting or editing text require a non-secure target.
    /// Cleanup and navigation stay available; key-up recovery bypasses send().
    var requiresNonSecureInput: Bool {
        if presetApplication != nil { return false }
        switch self {
        case .returnKey, .commandReturn, .shiftReturn, .space, .tab,
             .commandCopy, .commandPaste, .commandCut, .commandSelectAll,
             .commandUndo, .commandRedo, .commandFind, .commandSave,
             .commandDelete, .deleteBackward, .customShortcut:
            return true
        case .disabled, .escape, .commandRefresh, .commandClose, .commandQuit,
             .arrowUp, .arrowDown, .arrowLeft, .arrowRight, .directPassthrough, .scrollUp, .scrollDown,
             .appSwitcher, .missionControl, .showDesktop, .notificationCenter, .spotlight,
             .spaceLeft, .spaceRight, .lockScreen, .screenshot, .contextMenu, .focusInput,
             .volumeUp, .volumeDown, .volumeMute, .brightnessUp, .brightnessDown,
             .playPause, .previousCommandLeft, .nextCommandRight,
             .toggleLongRecording, .openCommonPhrases, .openCustomApplication, .openURL,
             .repeatSingleClick:
            return false
        default:
            preconditionFailure("Unhandled non-preset ButtonAction safety classification: \(self)")
        }
    }
}
