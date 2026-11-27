import CoreGraphics
import Foundation
import Testing
@testable import RemoteBuddy

@Suite("EventTap owner lifetime")
struct EventTapOwnerLifetimeTests {
    @Test func releaseNilPortAndSourceDrainsImmediately() {
        #expect(EventTapPort.release(port: nil, source: nil))
    }

    @Test func suppressorReleasesRetainedOwnerWhenPortDrains() {
        weak var weakSuppressor: KeyboardEventSuppressor?
        do {
            let suppressor = KeyboardEventSuppressor(uptime: { 0 }, releasePort: { _, _ in true })
            weakSuppressor = suppressor
            suppressor.installSimulatedRetainedOwnerForTesting()
            #expect(weakSuppressor != nil)
            suppressor.stop()
        }
        #expect(weakSuppressor == nil)
    }

    @Test func suppressorRetainsOwnerOnFallbackWhenPortReleaseTimesOut() {
        var fallbackRetainedObject: AnyObject?
        weak var weakSuppressor: KeyboardEventSuppressor?
        do {
            let suppressor = KeyboardEventSuppressor(uptime: { 0 }, releasePort: { _, _ in false })
            weakSuppressor = suppressor
            suppressor.installSimulatedRetainedOwnerForTesting()
            suppressor.stop()
            // Keep a strong handle in test scope only long enough to clean up the intentional
            // fallback retain after asserting it survived scope exit.
            fallbackRetainedObject = weakSuppressor
        }
        #expect(weakSuppressor != nil)
        if let leakedOwner = fallbackRetainedObject as? KeyboardEventSuppressor {
            Unmanaged.passUnretained(leakedOwner).release()
            fallbackRetainedObject = nil
        }
        #expect(weakSuppressor == nil)
    }

    @Test func captureMonitorReleasesRetainedOwnerWhenPortDrains() {
        weak var weakMonitor: ShortcutCaptureMonitor?
        do {
            let monitor = ShortcutCaptureMonitor(
                onCapture: { _ in },
                releasePort: { _, _ in true }
            )
            weakMonitor = monitor
            monitor.installSimulatedRetainedOwnerForTesting()
            #expect(weakMonitor != nil)
            monitor.stop()
        }
        #expect(weakMonitor == nil)
    }

    @Test func captureMonitorRetainsOwnerOnFallbackWhenPortReleaseTimesOut() {
        var fallbackRetainedObject: AnyObject?
        weak var weakMonitor: ShortcutCaptureMonitor?
        do {
            let monitor = ShortcutCaptureMonitor(
                onCapture: { _ in },
                releasePort: { _, _ in false }
            )
            weakMonitor = monitor
            monitor.installSimulatedRetainedOwnerForTesting()
            monitor.stop()
            fallbackRetainedObject = weakMonitor
        }
        #expect(weakMonitor != nil)
        if let leakedOwner = fallbackRetainedObject as? ShortcutCaptureMonitor {
            Unmanaged.passUnretained(leakedOwner).release()
            fallbackRetainedObject = nil
        }
        #expect(weakMonitor == nil)
    }
}
