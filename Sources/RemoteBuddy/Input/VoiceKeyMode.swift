import AppKit
import CoreGraphics
import Foundation
import IOKit.hidsystem

/// The complete trigger held for a voice session.
enum VoiceKeyMode: Hashable, RawRepresentable, Codable, CaseIterable, Identifiable {
    case function
    case leftCommand
    case rightCommand
    case leftOption
    case rightOption
    case shortcut(CustomKeyboardShortcut)

    static let shortcutPresets: [VoiceKeyMode] = [(UInt16(9), "V"), (UInt16(15), "R")].flatMap { keyCode, label in
        ([
            [.control, .shift], [.control, .option], [.control, .command],
        ] as [NSEvent.ModifierFlags]).map { modifiers in
            .shortcut(CustomKeyboardShortcut(keyCode: keyCode, modifierFlags: modifiers, keyLabel: label))
        }
    }
    static let suggestedShortcut = shortcutPresets[0]
    static let allCases: [VoiceKeyMode] = [.function, .rightOption, .rightCommand] + shortcutPresets

    var id: String { rawValue }
    var rawValue: String {
        switch self {
        case .function: return "fn"
        case .leftCommand: return "left_command"
        case .rightCommand: return "right_command"
        case .leftOption: return "left_option"
        case .rightOption: return "right_option"
        case let .shortcut(shortcut):
            return "shortcut:\(shortcut.keyCode):\(shortcut.modifierFlagsRawValue)"
        }
    }

    init?(rawValue: String) {
        switch rawValue {
        case "fn": self = .function
        case "left_command": self = .leftCommand
        case "right_command": self = .rightCommand
        case "left_option": self = .leftOption
        case "right_option": self = .rightOption
        default:
            let parts = rawValue.split(separator: ":")
            guard parts.count == 3, parts[0] == "shortcut",
                  let code = UInt16(parts[1]), code < 128, let flags = UInt(parts[2])
            else { return nil }
            let shortcut = CustomKeyboardShortcut(keyCode: code,
                modifierFlags: NSEvent.ModifierFlags(rawValue: flags),
                keyLabel: StandardKeyboardKey.keyLabel(forKeyCode: code))
            guard Self.supportsShortcut(shortcut) else { return nil }
            self = .shortcut(shortcut)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let mode = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported voice trigger")
        }
        self = mode
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.rawValue == rhs.rawValue }
    func hash(into hasher: inout Hasher) { hasher.combine(rawValue) }

    static func supportsShortcut(_ shortcut: CustomKeyboardShortcut) -> Bool {
        // Require a regular main key plus modifiers; standalone modifiers have dedicated modes.
        shortcut.keyCode < 128 && !(54...63).contains(shortcut.keyCode) &&
            !shortcut.modifierFlags.intersection([.control, .option, .command, .shift]).isEmpty &&
            !shortcut.modifierFlags.contains(.function)
    }

    @MainActor func displayName(using localization: LocalizationStore) -> String {
        if case let .shortcut(shortcut) = self { return shortcut.detailedDisplayName(using: localization, showsModifierSymbols: true) }
        return localization.text(localizationKey)
    }

    var keyCode: UInt16 {
        switch self {
        case .function: return 63
        case .leftCommand: return 55
        case .rightCommand: return 54
        case .leftOption: return 58
        case .rightOption: return 61
        case let .shortcut(shortcut): return shortcut.keyCode
        }
    }

    var eventFlags: CGEventFlags {
        switch self {
        case .function:
            return .maskSecondaryFn
        case .leftCommand:
            return [.maskCommand, CGEventFlags(rawValue: UInt64(NX_DEVICELCMDKEYMASK))]
        case .rightCommand:
            return [.maskCommand, CGEventFlags(rawValue: UInt64(NX_DEVICERCMDKEYMASK))]
        case .leftOption:
            return [.maskAlternate, CGEventFlags(rawValue: UInt64(NX_DEVICELALTKEYMASK))]
        case .rightOption:
            return [.maskAlternate, CGEventFlags(rawValue: UInt64(NX_DEVICERALTKEYMASK))]
        case let .shortcut(shortcut): return shortcut.cgEventFlags
        }
    }

    var requiresAccessibility: Bool {
        self != .function
    }

    var usesHardwareMapping: Bool {
        self == .function
    }

    var statusIdentifier: String {
        if case .shortcut = self { return "custom" }
        return rawValue
    }

    var localizationKey: String {
        if case .shortcut = self { return "connection.voice_key.mode.custom" }
        return "connection.voice_key.mode.\(rawValue)"
    }
}

extension VoiceKeyMode {
    init?(standaloneModifier: StandaloneKeyboardModifier) {
        switch standaloneModifier {
        case .function: self = .function
        case .leftCommand: self = .leftCommand
        case .rightCommand: self = .rightCommand
        case .leftOption: self = .leftOption
        case .rightOption: self = .rightOption
        case .leftControl, .rightControl, .leftShift, .rightShift:
            return nil
        }
    }
}
