import SwiftUI

/// Trigger choices and the keyboard editor for the integration wizard.
struct VoiceTriggerPicker: View {
    let selection: VoiceKeyMode
    let onSelect: (VoiceKeyMode) -> Void
    @EnvironmentObject private var localization: LocalizationStore
    @State private var editing = false

    private var choices: [VoiceKeyMode] {
        Self.menuChoices(for: selection)
    }

    static func menuChoices(for selection: VoiceKeyMode) -> [VoiceKeyMode] {
        VoiceKeyMode.allCases.contains(selection) ? VoiceKeyMode.allCases : VoiceKeyMode.allCases + [selection]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker(localization.text("connection.voice_key_mode.title"), selection: Binding(
                    get: { selection }, set: onSelect
                )) {
                    ForEach(choices) { mode in
                        Text(mode.displayName(using: localization)).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                Button(localization.text("connection.voice_key.customize")) { editing = true }
            }
            Text(localization.text({
                if case .shortcut = selection { return "connection.voice_key.chord_help" }
                return "connection.voice_key_mode.help"
            }()))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $editing) {
            KeyboardShortcutEditor(shortcut: editableShortcut, onSelect: accept, onCancel: { editing = false })
        }
    }

    private var editableShortcut: CustomKeyboardShortcut {
        switch selection {
        case let .shortcut(shortcut): return shortcut
        case .function: return StandaloneKeyboardModifier.function.shortcut
        case .leftCommand: return StandaloneKeyboardModifier.leftCommand.shortcut
        case .rightCommand: return StandaloneKeyboardModifier.rightCommand.shortcut
        case .leftOption: return StandaloneKeyboardModifier.leftOption.shortcut
        case .rightOption: return StandaloneKeyboardModifier.rightOption.shortcut
        }
    }

    private func accept(_ shortcut: CustomKeyboardShortcut) {
        if let modifier = shortcut.standaloneModifier,
           let mode = VoiceKeyMode(standaloneModifier: modifier) {
            onSelect(mode)
            editing = false
        } else if VoiceKeyMode.supportsShortcut(shortcut) {
            onSelect(.shortcut(shortcut))
            editing = false
        }
    }
}
