import AppKit
import Testing
@testable import RemoteBuddy

@Suite("Voice shortcut physical keyboard selection")
struct VoiceShortcutKeyboardTests {
    private let v = StandardKeyboardKey("v", keyCode: 9, label: "V")

    @Test func unsupportedVisualVoiceSelectionsExplainWhyTheyCannotBeUsed() {
        var draft = ShortcutKeyboardSelection(shortcut: nil)
        #expect(draft.validationHintKey(for: .voice) == nil)
        draft.select(v)
        #expect(draft.validationHintKey(for: .voice) == "connection.voice_key.custom_unsupported")
        #expect(draft.validationHintKey(for: .mapping) == nil)
        draft = ShortcutKeyboardSelection(shortcut: StandaloneKeyboardModifier.leftControl.shortcut)
        #expect(draft.validationHintKey(for: .voice) != nil)
        draft.select(v)
        #expect(draft.validationHintKey(for: .voice) == nil)
        draft = ShortcutKeyboardSelection(shortcut: StandaloneKeyboardModifier.rightOption.shortcut)
        #expect(draft.validationHintKey(for: .voice) == nil)
    }

    @Test func mappingExplainsIncompleteModifierCombinationsUntilAMainKeyIsSelected() {
        var draft = ShortcutKeyboardSelection(shortcut: StandaloneKeyboardModifier.leftCommand.shortcut)
        draft.toggle(.leftOption, purpose: .mapping)
        #expect(!draft.canUse(for: .mapping))
        #expect(draft.validationHintKey(for: .mapping) == "shortcut.keyboard.main_key_required")
        draft.select(v, purpose: .mapping)
        #expect(draft.canUse(for: .mapping))
        #expect(draft.validationHintKey(for: .mapping) == nil)
    }

    @Test func mappingAcceptsPlainKeysAndStandaloneModifiersWithoutWeakeningVoiceValidation() throws {
        var draft = ShortcutKeyboardSelection(shortcut: nil)
        #expect(!draft.canUse(for: .mapping))
        #expect(!draft.canUse(for: .voice))
        draft.select(v)
        #expect(draft.canUse(for: .mapping))
        #expect(!draft.canUse(for: .voice))
        let original = try #require(draft.shortcut)
        var edited = ShortcutKeyboardSelection(shortcut: original)
        edited.toggle(.leftControl)
        #expect(edited.canUse(for: .mapping))
        #expect(edited.canUse(for: .voice))
        #expect(original.modifierFlags.isEmpty)
        let standalone = ShortcutKeyboardSelection(shortcut: StandaloneKeyboardModifier.leftShift.shortcut)
        #expect(standalone.canUse(for: .mapping))
        #expect(!standalone.canUse(for: .voice))
    }

    @Test func mappingRetainsExplicitFnChordsAndCapsLockKeys() throws {
        var draft = ShortcutKeyboardSelection(shortcut: nil)
        draft.toggle(.function, purpose: .mapping)
        draft.select(v, purpose: .mapping)
        let shortcut = try #require(draft.shortcut)
        #expect(shortcut.modifierFlags.contains(.function))
        #expect(shortcut.keyCode == 9)
        #expect(draft.canUse(for: .mapping))
        draft = ShortcutKeyboardSelection(shortcut: nil)
        draft.select(.init("caps_lock", keyCode: 57, label: "Caps Lock"), purpose: .mapping)
        #expect(draft.canUse(for: .mapping))
        #expect(!draft.canUse(for: .voice))
    }

    @Test func selectingLeftControlAndRightOptionKeepsTheirSidesThroughPersistenceAndInjection() throws {
        var selection = ShortcutKeyboardSelection(shortcut: StandaloneKeyboardModifier.function.shortcut)
        selection.toggle(.leftControl)
        selection.toggle(.rightOption)
        selection.select(v)
        #expect(selection.canUse(for: .voice))
        let shortcut = try #require(selection.shortcut)
        #expect(ShortcutEventSequence.selectedModifiers(for: shortcut.cgEventFlags).map(\.key) == [59, 61])
        let mode = VoiceKeyMode.shortcut(shortcut)
        let restored = try #require(VoiceKeyMode(rawValue: mode.rawValue))
        #expect(ShortcutEventSequence.selectedModifiers(for: restored.eventFlags).map(\.key) == [59, 61])
    }

    @Test func changingModifierSideReplacesTheEarlierSideInsteadOfHoldingBoth() throws {
        var selection = ShortcutKeyboardSelection(shortcut: StandaloneKeyboardModifier.leftOption.shortcut)
        selection.toggle(.rightOption)
        selection.select(v)
        let shortcut = try #require(selection.shortcut)
        #expect(ShortcutEventSequence.selectedModifiers(for: shortcut.cgEventFlags).map(\.key) == [61])
        selection.toggle(.rightOption)
        #expect(!selection.canUse(for: .voice))
    }

    @Test func recordedSideSpecificChordsAndStandaloneModifiersRoundTripInTheEditor() throws {
        // Device bits from a physical left-Control + right-Shift key event.
        let flags = NSEvent.ModifierFlags.control.union(.shift).union(.init(rawValue: 0x0005))
        let captured = CustomKeyboardShortcut(keyCode: 9, modifierFlags: flags, keyLabel: "V")
        let selection = ShortcutKeyboardSelection(shortcut: captured)
        #expect(selection.shortcut == captured)
        #expect(selection.modifiers.contains(.leftControl))
        #expect(selection.modifiers.contains(.rightShift))
        for modifier in [StandaloneKeyboardModifier.function, .leftOption, .rightOption, .leftCommand, .rightCommand] {
            let standalone = ShortcutKeyboardSelection(shortcut: modifier.shortcut)
            #expect(standalone.canUse(for: .voice))
            #expect(standalone.shortcut == modifier.shortcut)
        }
    }

    @Test func fnIsStandaloneAndIncompleteSelectionsCannotBeUsed() {
        var selection = ShortcutKeyboardSelection(shortcut: StandaloneKeyboardModifier.function.shortcut)
        selection.toggle(.leftControl)
        #expect(!selection.canUse(for: .voice))
        selection.toggle(.leftShift)
        #expect(selection.shortcut == nil)
        selection.select(v)
        #expect(selection.canUse(for: .voice))
        selection.toggle(.function)
        #expect(selection.shortcut == StandaloneKeyboardModifier.function.shortcut)
        #expect(selection.key == nil)
    }

    @Test func rawValueShortcutParsingResolvesLabelsOffMainThreadWithoutEventLookup() async {
        let restored = await Task.detached {
            (
                v: VoiceKeyMode(rawValue: "shortcut:9:\(NSEvent.ModifierFlags([.control, .shift]).rawValue)"),
                fallback: VoiceKeyMode(rawValue: "shortcut:10:\(NSEvent.ModifierFlags([.control]).rawValue)")
            )
        }.value
        if case let .shortcut(vShortcut) = restored.v {
            #expect(vShortcut.keyLabel == "V")
        } else {
            Issue.record("Expected shortcut for V")
        }
        if case let .shortcut(isoShortcut) = restored.fallback {
            #expect(isoShortcut.keyLabel == "Key Code 10")
        } else {
            Issue.record("Expected shortcut for fallback key code")
        }
    }
}
