import AppKit
import SwiftUI

enum ShortcutKeyboardPurpose {
    case voice, mapping
}

/// A draft key selection that retains the side of each modifier.
struct ShortcutKeyboardSelection {
    private(set) var modifiers: [StandaloneKeyboardModifier] = []
    private(set) var key: StandardKeyboardKey?

    init(shortcut: CustomKeyboardShortcut?) {
        guard let shortcut else { return }
        if let modifier = shortcut.standaloneModifier {
            modifiers = [modifier]
        } else {
            modifiers = ShortcutEventSequence.selectedModifiers(for: shortcut.cgEventFlags).compactMap { selected in
                StandaloneKeyboardModifier.allCases.first { $0.keyCode == selected.key }
            }
            key = StandardKeyboardKey.allKeys.first { $0.keyCode == shortcut.keyCode }
                ?? StandardKeyboardKey("captured", keyCode: shortcut.keyCode, label: shortcut.keyLabel)
        }
    }

    mutating func toggle(_ modifier: StandaloneKeyboardModifier, purpose: ShortcutKeyboardPurpose = .voice) {
        if modifiers.contains(modifier) {
            modifiers.removeAll { $0 == modifier }
        } else if modifier == .function && purpose == .voice {
            modifiers = [.function]
            key = nil
        } else {
            let family = modifier.modifierFlags.intersection(CustomKeyboardShortcut.supportedModifiers)
            modifiers.removeAll {
                (purpose == .voice && $0 == .function) || $0.modifierFlags.intersection(CustomKeyboardShortcut.supportedModifiers) == family
            }
            modifiers.append(modifier)
        }
    }

    mutating func select(_ key: StandardKeyboardKey, purpose: ShortcutKeyboardPurpose = .voice) {
        if purpose == .voice { modifiers.removeAll { $0 == .function } }
        self.key = key
    }

    var shortcut: CustomKeyboardShortcut? {
        if let key {
            return key.shortcut(modifierFlags: modifiers.reduce([]) { flags, modifier in
                flags.union(NSEvent.ModifierFlags(rawValue: UInt(ShortcutEventSequence.modifierFlags(for: modifier.keyCode).rawValue)))
            })
        }
        return modifiers.count == 1 ? modifiers[0].shortcut : nil
    }

    func canUse(for purpose: ShortcutKeyboardPurpose) -> Bool {
        guard let shortcut else { return false }
        if purpose == .mapping { return true }
        if let modifier = shortcut.standaloneModifier { return VoiceKeyMode(standaloneModifier: modifier) != nil }
        return VoiceKeyMode.supportsShortcut(shortcut)
    }

    func validationHintKey(for purpose: ShortcutKeyboardPurpose) -> String? {
        guard key != nil || !modifiers.isEmpty, !canUse(for: purpose) else { return nil }
        return purpose == .voice ? "connection.voice_key.custom_unsupported" : "shortcut.keyboard.main_key_required"
    }

    @MainActor func displayName(using localization: LocalizationStore) -> String {
        if key != nil, let shortcut {
            return shortcut.detailedDisplayName(using: localization, showsModifierSymbols: true)
        }
        let order: [StandaloneKeyboardModifier] = [.leftControl, .rightControl, .leftOption, .rightOption,
            .leftShift, .rightShift, .leftCommand, .rightCommand, .function]
        return order.filter { modifiers.contains($0) }.map { modifier in
            let name = modifier.displayName(using: localization, abbreviated: true)
            return "\(name) (\(modifier == .function ? "🌐" : modifier.symbol))"
        }.joined(separator: " + ")
    }
}

enum ShortcutKeyboardKey: Identifiable {
    case key(StandardKeyboardKey)
    case modifier(StandaloneKeyboardModifier, Double)
    case arrows

    var id: String {
        switch self {
        case let .key(key): return key.id
        case let .modifier(modifier, _): return "modifier-\(modifier.rawValue)"
        case .arrows: return "up-down"
        }
    }

    var widthUnits: Double {
        switch self {
        case let .key(key): return key.widthUnits
        case let .modifier(_, width): return width
        case .arrows: return 1
        }
    }

    /// ANSI MacBook positions, with distinct left and right modifier keys.
    static let macBookRows: [[ShortcutKeyboardKey]] = Array(StandardKeyboardKey.mainRows.prefix(4)).map {
        $0.map(ShortcutKeyboardKey.key)
    } + [
        [.modifier(.leftShift, 2.3)] + StandardKeyboardKey.mainRows[4].map(ShortcutKeyboardKey.key)
            + [.modifier(.rightShift, 2.25)],
        [.modifier(.function, 1), .modifier(.leftControl, 1), .modifier(.leftOption, 1),
         .modifier(.leftCommand, 1.3), .key(.init("space", keyCode: 49, label: "Space", widthUnits: 4.95)),
         .modifier(.rightCommand, 1.3), .modifier(.rightOption, 1),
         .key(.init("left", keyCode: 123, label: "←")), .arrows,
         .key(.init("right", keyCode: 124, label: "→"))],
    ]
}

struct KeyboardShortcutEditor: View {
    let purpose: ShortcutKeyboardPurpose
    let onSelect: (CustomKeyboardShortcut) -> Void
    let onCancel: () -> Void
    @EnvironmentObject private var localization: LocalizationStore
    @State private var selection: ShortcutKeyboardSelection
    @State private var recording = false
    @State private var errorKey: String?
    @State private var replacedFnSelection = false

    init(shortcut: CustomKeyboardShortcut?, purpose: ShortcutKeyboardPurpose = .voice, onSelect: @escaping (CustomKeyboardShortcut) -> Void,
         onCancel: @escaping () -> Void) {
        let selection = ShortcutKeyboardSelection(shortcut: shortcut)
        _selection = State(initialValue: selection)
        self.purpose = purpose
        self.onSelect = onSelect
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(localization.text(purpose == .voice ? "voice.keyboard.title" : "shortcut.keyboard.title")).font(.title3.bold())
            Text(localization.text(purpose == .voice ? "voice.keyboard.help" : "shortcut.keyboard.help"))
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 14) {
                let name = selection.displayName(using: localization)
                Text(name.isEmpty ? localization.text("voice.keyboard.choose_keys") : name)
                    .font(.headline).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(localization.text(recording ? "voice.keyboard.stop_recording" : "shortcut.action.record")) {
                    errorKey = nil
                    recording.toggle()
                }.buttonStyle(.bordered)
            }
            .frame(minHeight: 36)
            if recording {
                Text(localization.text("shortcut.editor.recording_prompt"))
                    .font(.callout).foregroundStyle(Color.accentColor)
                    .fixedSize(horizontal: false, vertical: true)
                ShortcutCaptureView(onCapture: { shortcut in
                    recording = false
                    selection = ShortcutKeyboardSelection(shortcut: shortcut)
                    errorKey = nil
                    replacedFnSelection = false
                }, onFailure: { failure in
                    recording = false
                    errorKey = failure == .accessibilityPermissionRequired
                        ? "shortcut.editor.permission_required" : "shortcut.editor.capture_unavailable"
                }).frame(width: 1, height: 1)
            }
            ScrollView {
                VStack(spacing: 5) {
                    ForEach(Array(ShortcutKeyboardKey.macBookRows.enumerated()), id: \.offset) { _, row in
                        keyboardRow(row)
                    }
                }.padding(10)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            }
            if let hint = errorKey ?? selection.validationHintKey(for: purpose)
                ?? (replacedFnSelection ? "voice.keyboard.fn_replaced" : nil) {
                Text(localization.text(hint)).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(localization.text("common.action.cancel")) { recording = false; onCancel() }
                    .buttonStyle(.bordered)
                Button(localization.text(purpose == .voice ? "voice.keyboard.use_shortcut" : "shortcut.keyboard.use_shortcut")) {
                    guard selection.canUse(for: purpose), let shortcut = selection.shortcut else { return }
                    recording = false
                    onSelect(shortcut)
                }.buttonStyle(.borderedProminent).disabled(!selection.canUse(for: purpose))
            }
        }
        .padding(20)
        .frame(width: 920, height: 540)
        .onDisappear { recording = false }
    }

    private func keyboardRow(_ keys: [ShortcutKeyboardKey]) -> some View {
        GeometryReader { geometry in
            let units = keys.reduce(0) { $0 + $1.widthUnits }
            let unitWidth = max(0, geometry.size.width - CGFloat(keys.count - 1) * 5) / CGFloat(units)
            HStack(spacing: 5) {
                ForEach(keys) { key in
                    keyboardKey(key).frame(width: unitWidth * CGFloat(key.widthUnits), height: 42)
                }
            }
        }.frame(height: 42)
    }

    @ViewBuilder private func keyboardKey(_ item: ShortcutKeyboardKey) -> some View {
        switch item {
        case let .modifier(modifier, _):
            keyButton(selected: selection.modifiers.contains(modifier), title: modifier.displayName(using: localization)) {
                recording = false
                errorKey = nil
                replacedFnSelection = purpose == .voice && (
                    (modifier == .function && (selection.key != nil || selection.modifiers.contains { $0 != .function })) ||
                    (modifier != .function && selection.modifiers.contains(.function)))
                selection.toggle(modifier, purpose: purpose)
            } label: {
                VStack(spacing: 1) {
                    Text(modifier == .function ? "🌐" : modifier.symbol).font(.system(size: 14))
                    Text(modifierName(modifier)).font(.system(size: 10))
                }
            }
        case let .key(key):
            normalKey(key)
        case .arrows:
            VStack(spacing: 3) {
                normalKey(.init("up", keyCode: 126, label: "↑"))
                normalKey(.init("down", keyCode: 125, label: "↓"))
            }
        }
    }

    private func normalKey(_ key: StandardKeyboardKey) -> some View {
        keyButton(selected: selection.key?.keyCode == key.keyCode, title: key.keyLabel) {
            recording = false
            errorKey = nil
            replacedFnSelection = purpose == .voice && selection.modifiers.contains(.function)
            selection.select(key, purpose: purpose)
        } label: {
            Text(key.keyCode == 49 ? localization.text("voice.keyboard.space") : (key.keyCode == 53 ? "esc" : key.visualLabel))
                .font(.system(size: 12, weight: .medium))
        }
        .help(key.keyCode == 57 && purpose == .voice
            ? localization.text("voice.keyboard.caps_unsupported") : key.keyLabel)
        .disabled(key.keyCode == 57 && purpose == .voice) // Voice triggers exclude Caps Lock.
        .opacity(key.keyCode == 57 && purpose == .voice ? 0.45 : 1)
    }

    private func keyButton<Label: View>(selected: Bool, title: String, action: @escaping () -> Void,
                                       @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            label().frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? Color.accentColor : Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 5))
                .overlay { RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.15)) }
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain).help(title).accessibilityLabel(title)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func modifierName(_ modifier: StandaloneKeyboardModifier) -> String {
        switch modifier {
        case .leftControl, .rightControl: return "control"
        case .leftOption, .rightOption: return "option"
        case .leftCommand, .rightCommand: return "command"
        case .leftShift, .rightShift: return "shift"
        case .function: return "fn"
        }
    }
}
