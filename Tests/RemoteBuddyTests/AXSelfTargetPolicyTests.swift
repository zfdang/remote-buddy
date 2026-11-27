import AppKit
import Foundation
import Testing
@testable import RemoteBuddy

@Suite("AX self-target policy")
struct AXSelfTargetPolicyTests {
    @Test func identifiesOwnProcessIdentifierOnly() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        #expect(AXSelfTargetPolicy.isOwnProcess(ownPID, ownProcessIdentifier: ownPID))
        #expect(!AXSelfTargetPolicy.isOwnProcess(ownPID + 1, ownProcessIdentifier: ownPID))
    }

    @Test func hitTestsOwnWindowFramesCorrectly() {
        let frames = [
            NSRect(x: 100, y: 100, width: 300, height: 200),
            NSRect(x: 600, y: 200, width: 120, height: 80),
        ]
        #expect(AXSelfTargetPolicy.isPointInsideOwnWindow(NSPoint(x: 150, y: 150), windowFrames: frames))
        #expect(!AXSelfTargetPolicy.isPointInsideOwnWindow(NSPoint(x: 50, y: 50), windowFrames: frames))
    }

    @Test func accessibilityHelpersShortCircuitOnOwnProcessIdentifier() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        #expect(!KeyboardInjector.announceManualAccessibility(
            processIdentifier: ownPID,
            bundleIdentifier: "com.remote-buddy.test",
            attempt: 0
        ))
        #expect(!KeyboardInjector.focusComposer(processIdentifier: ownPID))
        #expect(!KeyboardInjector.focusWeChatComposer(processIdentifier: ownPID))
        #expect(!KeyboardInjector.focusRecordedAccessibilityTarget(
            AccessibilityFocusTarget(
                role: "AXTextArea",
                identifier: "composer",
                title: "",
                description: "",
                help: "",
                placeholder: "",
                context: "",
                windowTitle: "",
                normalizedFrame: nil
            ),
            processIdentifier: ownPID
        ))
    }
}
