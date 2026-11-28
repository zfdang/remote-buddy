import SwiftUI

/// Trigger choices and the keyboard editor for the integration wizard.
struct VoiceTriggerPicker: View {
    let selection: VoiceKeyMode
    let onSelect: @MainActor @Sendable (VoiceKeyMode) -> Void
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
            Text(Self.helpText(for: selection, localization: localization))
                .font(.caption)
                .foregroundStyle(selection == .function ? Color.orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $editing) {
            KeyboardShortcutEditor(shortcut: editableShortcut, onSelect: accept, onCancel: { editing = false })
        }
    }

    static func helpText(
        for selection: VoiceKeyMode,
        localization: LocalizationStore
    ) -> AttributedString {
        let key: String
        let highlightKey: String?
        if case .shortcut = selection {
            key = "connection.voice_key.chord_help"
            highlightKey = "connection.voice_key.chord_help.highlight"
        } else if selection == .function {
            key = "connection.voice_key_mode.fn_caution_help"
            highlightKey = nil
        } else {
            key = "connection.voice_key_mode.help"
            highlightKey = "connection.voice_key_mode.help.highlight"
        }

        var attributed = AttributedString(localization.text(key))
        guard let highlightKey else { return attributed }
        let phrase = localization.text(highlightKey)
        guard !phrase.isEmpty, let range = attributed.range(of: phrase) else { return attributed }

        var highlight = AttributeContainer()
        highlight[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = .red
        highlight[AttributeScopes.SwiftUIAttributes.FontAttribute.self] = .caption.bold()
        attributed[range].mergeAttributes(highlight)
        return attributed
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
