import AppKit
import Foundation

/// Filters out Accessibility queries targeting our own process or windows.
///
/// Same-process AX queries run synchronously on the calling thread and can enter
/// SwiftUI's `NSHostingView` view graph while the main thread holds `_MovableLock`,
/// risking a UI deadlock. All external target inspection must short-circuit here.
enum AXSelfTargetPolicy {
    static func isOwnProcess(
        _ processIdentifier: pid_t,
        ownProcessIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> Bool {
        processIdentifier == ownProcessIdentifier
    }

    static func isOwnFrontmostApplication(
        _ application: NSRunningApplication? = NSWorkspace.shared.frontmostApplication,
        ownProcessIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> Bool {
        guard let application else { return false }
        return isOwnProcess(
            application.processIdentifier,
            ownProcessIdentifier: ownProcessIdentifier
        )
    }

    static func isPointInsideOwnWindow(
        _ point: NSPoint,
        windowFrames: [NSRect]
    ) -> Bool {
        windowFrames.contains { $0.contains(point) }
    }
}
