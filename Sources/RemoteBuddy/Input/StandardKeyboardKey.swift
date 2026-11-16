import AppKit
import SwiftUI

enum StandaloneKeyboardModifier: String, CaseIterable, Identifiable {
    case leftCommand = "left_command"
    case rightCommand = "right_command"
    case leftOption = "left_option"
    case rightOption = "right_option"
    case leftControl = "left_control"
    case rightControl = "right_control"
    case leftShift = "left_shift"
    case rightShift = "right_shift"
    case function

    var id: String { rawValue }

    var keyCode: UInt16 {
        switch self {
        case .leftCommand: return 55
        case .rightCommand: return 54
        case .leftOption: return 58
        case .rightOption: return 61
        case .leftControl: return 59
        case .rightControl: return 62
        case .leftShift: return 56
        case .rightShift: return 60
        case .function: return 63
        }
    }

    var modifierFlags: NSEvent.ModifierFlags {
        switch self {
        case .leftCommand, .rightCommand: return .command
        case .leftOption, .rightOption: return .option
        case .leftControl, .rightControl: return .control
        case .leftShift, .rightShift: return .shift
        case .function: return .function
        }
    }

    var keyLabel: String {
        switch self {
        case .leftCommand: return "Left Command"
        case .rightCommand: return "Right Command"
        case .leftOption: return "Left Option"
        case .rightOption: return "Right Option"
        case .leftControl: return "Left Control"
        case .rightControl: return "Right Control"
        case .leftShift: return "Left Shift"
        case .rightShift: return "Right Shift"
        case .function: return "Fn"
        }
    }

    var symbol: String {
        switch self {
        case .leftCommand, .rightCommand: return "⌘"
        case .leftOption, .rightOption: return "⌥"
        case .leftControl, .rightControl: return "⌃"
        case .leftShift, .rightShift: return "⇧"
        case .function: return "fn"
        }
    }

    var shortcut: CustomKeyboardShortcut {
        CustomKeyboardShortcut(
            keyCode: keyCode,
            modifierFlags: modifierFlags,
            keyLabel: keyLabel
        )
    }

    @MainActor
    func displayName(using localization: LocalizationStore, abbreviated: Bool = false) -> String {
        if abbreviated && (self == .leftControl || self == .rightControl) {
            return localization.text("shortcut.standalone_modifier.\(rawValue)_short")
        }
        return localization.text("shortcut.standalone_modifier.\(rawValue)")
    }

    static func matching(_ shortcut: CustomKeyboardShortcut) -> Self? {
        allCases.first {
            $0.keyCode == shortcut.keyCode && $0.modifierFlags == shortcut.modifierFlags
        }
    }
}

struct StandardKeyboardKey: Identifiable, Equatable {
    let id: String
    let keyCode: UInt16
    let keyLabel: String
    let widthUnits: Double

    var visualLabel: String {
        switch keyCode {
        case 36: return "⏎"
        case 48: return "⇥"
        case 49: return "␠"
        case 51: return "⌫"
        case 53: return "⎋"
        case 76: return "⌤"
        case 117: return "⌦"
        default: return keyLabel
        }
    }

    init(_ id: String, keyCode: UInt16, label: String, widthUnits: Double = 1) {
        self.id = id
        self.keyCode = keyCode
        keyLabel = label
        self.widthUnits = widthUnits
    }

    func shortcut(modifierFlags: NSEvent.ModifierFlags) -> CustomKeyboardShortcut {
        CustomKeyboardShortcut(
            keyCode: keyCode,
            modifierFlags: modifierFlags,
            keyLabel: keyLabel
        )
    }

    static let mainRows: [[StandardKeyboardKey]] = [
        [
            .init("escape", keyCode: 53, label: "Esc", widthUnits: 1.35),
            .init("f1", keyCode: 122, label: "F1"),
            .init("f2", keyCode: 120, label: "F2"),
            .init("f3", keyCode: 99, label: "F3"),
            .init("f4", keyCode: 118, label: "F4"),
            .init("f5", keyCode: 96, label: "F5"),
            .init("f6", keyCode: 97, label: "F6"),
            .init("f7", keyCode: 98, label: "F7"),
            .init("f8", keyCode: 100, label: "F8"),
            .init("f9", keyCode: 101, label: "F9"),
            .init("f10", keyCode: 109, label: "F10"),
            .init("f11", keyCode: 103, label: "F11"),
            .init("f12", keyCode: 111, label: "F12"),
        ],
        [
            .init("grave", keyCode: 50, label: "`"),
            .init("1", keyCode: 18, label: "1"),
            .init("2", keyCode: 19, label: "2"),
            .init("3", keyCode: 20, label: "3"),
            .init("4", keyCode: 21, label: "4"),
            .init("5", keyCode: 23, label: "5"),
            .init("6", keyCode: 22, label: "6"),
            .init("7", keyCode: 26, label: "7"),
            .init("8", keyCode: 28, label: "8"),
            .init("9", keyCode: 25, label: "9"),
            .init("0", keyCode: 29, label: "0"),
            .init("minus", keyCode: 27, label: "−"),
            .init("equal", keyCode: 24, label: "="),
            .init("delete_backward", keyCode: 51, label: "⌫", widthUnits: 1.55),
        ],
        [
            .init("tab", keyCode: 48, label: "Tab", widthUnits: 1.55),
            .init("q", keyCode: 12, label: "Q"),
            .init("w", keyCode: 13, label: "W"),
            .init("e", keyCode: 14, label: "E"),
            .init("r", keyCode: 15, label: "R"),
            .init("t", keyCode: 17, label: "T"),
            .init("y", keyCode: 16, label: "Y"),
            .init("u", keyCode: 32, label: "U"),
            .init("i", keyCode: 34, label: "I"),
            .init("o", keyCode: 31, label: "O"),
            .init("p", keyCode: 35, label: "P"),
            .init("left_bracket", keyCode: 33, label: "["),
            .init("right_bracket", keyCode: 30, label: "]"),
            .init("backslash", keyCode: 42, label: "\\"),
        ],
        [
            .init("caps_lock", keyCode: 57, label: "Caps", widthUnits: 1.75),
            .init("a", keyCode: 0, label: "A"),
            .init("s", keyCode: 1, label: "S"),
            .init("d", keyCode: 2, label: "D"),
            .init("f", keyCode: 3, label: "F"),
            .init("g", keyCode: 5, label: "G"),
            .init("h", keyCode: 4, label: "H"),
            .init("j", keyCode: 38, label: "J"),
            .init("k", keyCode: 40, label: "K"),
            .init("l", keyCode: 37, label: "L"),
            .init("semicolon", keyCode: 41, label: ";"),
            .init("quote", keyCode: 39, label: "'"),
            .init("return", keyCode: 36, label: "Return", widthUnits: 1.75),
        ],
        [
            .init("z", keyCode: 6, label: "Z"),
            .init("x", keyCode: 7, label: "X"),
            .init("c", keyCode: 8, label: "C"),
            .init("v", keyCode: 9, label: "V"),
            .init("b", keyCode: 11, label: "B"),
            .init("n", keyCode: 45, label: "N"),
            .init("m", keyCode: 46, label: "M"),
            .init("comma", keyCode: 43, label: ","),
            .init("period", keyCode: 47, label: "."),
            .init("slash", keyCode: 44, label: "/"),
        ],
        [
            .init("space", keyCode: 49, label: "Space", widthUnits: 6),
        ],
    ]

    static let navigationRows: [[StandardKeyboardKey]] = [
        [
            .init("help", keyCode: 114, label: "Help"),
            .init("home", keyCode: 115, label: "Home"),
            .init("page_up", keyCode: 116, label: "Page Up", widthUnits: 1.45),
            .init("delete_forward", keyCode: 117, label: "⌦"),
            .init("end", keyCode: 119, label: "End"),
            .init("page_down", keyCode: 121, label: "Page Down", widthUnits: 1.45),
        ],
        [
            .init("arrow_left", keyCode: 123, label: "←"),
            .init("arrow_down", keyCode: 125, label: "↓"),
            .init("arrow_up", keyCode: 126, label: "↑"),
            .init("arrow_right", keyCode: 124, label: "→"),
        ],
    ]

    static let extendedFunctionRows: [[StandardKeyboardKey]] = [[
        .init("f13", keyCode: 105, label: "F13"),
        .init("f14", keyCode: 107, label: "F14"),
        .init("f15", keyCode: 113, label: "F15"),
        .init("f16", keyCode: 106, label: "F16"),
        .init("f17", keyCode: 64, label: "F17"),
        .init("f18", keyCode: 79, label: "F18"),
        .init("f19", keyCode: 80, label: "F19"),
        .init("f20", keyCode: 90, label: "F20"),
    ]]

    static let numberPadRows: [[StandardKeyboardKey]] = [
        [
            .init("keypad_clear", keyCode: 71, label: "Clear"),
            .init("keypad_equal", keyCode: 81, label: "="),
            .init("keypad_divide", keyCode: 75, label: "/"),
            .init("keypad_multiply", keyCode: 67, label: "×"),
        ],
        [
            .init("keypad_7", keyCode: 89, label: "7"),
            .init("keypad_8", keyCode: 91, label: "8"),
            .init("keypad_9", keyCode: 92, label: "9"),
            .init("keypad_minus", keyCode: 78, label: "−"),
        ],
        [
            .init("keypad_4", keyCode: 86, label: "4"),
            .init("keypad_5", keyCode: 87, label: "5"),
            .init("keypad_6", keyCode: 88, label: "6"),
            .init("keypad_plus", keyCode: 69, label: "+"),
        ],
        [
            .init("keypad_1", keyCode: 83, label: "1"),
            .init("keypad_2", keyCode: 84, label: "2"),
            .init("keypad_3", keyCode: 85, label: "3"),
            .init("keypad_enter", keyCode: 76, label: "Enter"),
        ],
        [
            .init("keypad_0", keyCode: 82, label: "0", widthUnits: 2.1),
            .init("keypad_decimal", keyCode: 65, label: "."),
        ],
    ]

    static var allKeys: [StandardKeyboardKey] {
        (mainRows + navigationRows + extendedFunctionRows + numberPadRows).flatMap { $0 }
    }

    private static let keyLabelsByCode: [UInt16: String] = Dictionary(
        allKeys.map { ($0.keyCode, $0.keyLabel) },
        uniquingKeysWith: { first, _ in first }
    )

    static func keyLabel(forKeyCode keyCode: UInt16) -> String {
        keyLabelsByCode[keyCode] ?? "Key Code \(keyCode)"
    }
}
