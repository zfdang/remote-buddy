import Foundation
import Testing
@testable import RemoteBuddy

@Suite("HID report path health and deduplication")
struct HIDReportPathHealthTests {
    @Test func dedupCacheDropsDuplicateReportWithinFiftyMillisecondsAndKeepsPressRelease() {
        var cache = HIDReportDeduplicationCache()
        let press = HIDReportDeduplicationKey(devicePointer: 1, reportID: 1, data: Data([0x41, 0x00]))
        let release = HIDReportDeduplicationKey(devicePointer: 1, reportID: 1, data: Data([0x00, 0x00]))

        let firstPress = cache.shouldDrop(key: press, timestampNanoseconds: 1_000_000_000)
        let dupPress = cache.shouldDrop(key: press, timestampNanoseconds: 1_020_000_000)
        let firstRelease = cache.shouldDrop(key: release, timestampNanoseconds: 1_025_000_000)
        // After 50 ms, identical payload is accepted again.
        let laterPress = cache.shouldDrop(key: press, timestampNanoseconds: 1_071_000_000)

        #expect(!firstPress)
        #expect(dupPress)
        #expect(!firstRelease)
        #expect(!laterPress)
    }

    @Test func dedupCachePartitionsByDeviceAndReportIDAndCapsEntries() {
        var cache = HIDReportDeduplicationCache()
        let device1 = HIDReportDeduplicationKey(devicePointer: 1, reportID: 1, data: Data([0x01]))
        let device2 = HIDReportDeduplicationKey(devicePointer: 2, reportID: 1, data: Data([0x01]))
        let report2 = HIDReportDeduplicationKey(devicePointer: 1, reportID: 2, data: Data([0x01]))

        let d1 = cache.shouldDrop(key: device1, timestampNanoseconds: 1_000_000_000)
        let d2 = cache.shouldDrop(key: device2, timestampNanoseconds: 1_005_000_000)
        let r2 = cache.shouldDrop(key: report2, timestampNanoseconds: 1_010_000_000)

        #expect(!d1)
        #expect(!d2)
        #expect(!r2)

        for index in UInt32(10)..<UInt32(25) {
            let key = HIDReportDeduplicationKey(devicePointer: 99, reportID: index, data: Data([0xAA]))
            _ = cache.shouldDrop(key: key, timestampNanoseconds: 1_020_000_000)
        }
        #expect(cache.entries.count <= 8)
    }

    @Test func pathHealthDetectsManagerFallbackAndDeviceRecovery() {
        var health = HIDReportPathHealth()
        let confirmed = health.record(
            path: .device,
            duplicate: false,
            nowNanoseconds: 1_000_000_000,
            recoveryEnabled: true
        )
        #expect(confirmed == [.deviceDeliveryConfirmed])

        let recentManager = health.record(
            path: .manager,
            duplicate: false,
            nowNanoseconds: 2_000_000_000,
            recoveryEnabled: true
        )
        #expect(!recentManager.contains(.managerFallback))

        let fallback = health.record(
            path: .manager,
            duplicate: false,
            nowNanoseconds: 4_000_000_000,
            recoveryEnabled: true
        )
        #expect(fallback.contains(.managerFallback))

        let recovered = health.record(
            path: .device,
            duplicate: false,
            nowNanoseconds: 4_500_000_000,
            recoveryEnabled: true
        )
        #expect(recovered.contains(.deviceDeliveryRecovered))
    }

    @Test func pathHealthThrottlesAndBoundsDeviceCallbackRecovery() {
        var health = HIDReportPathHealth()
        var events = driveManagerOnlyWindow(&health, startingAt: 1_000_000_000)
        events += driveManagerOnlyWindow(&health, startingAt: 11_000_000_000)

        var start: UInt64 = 21_000_000_000
        for _ in 0..<18 {
            events += driveManagerOnlyWindow(&health, startingAt: start)
            start += 10_000_000_000
        }

        let attempts = events.compactMap { event -> Int? in
            if case let .recoveryCandidate(attempt, _) = event { return attempt }
            return nil
        }
        #expect(attempts == [1, 2, 3])
        #expect(events.contains { event in
            if case .recoveryExhausted(attempts: 3) = event { return true }
            return false
        })
    }

    @Test func monitorNeverDropsManagerReportsSolelyBecauseDeviceCallbackIsRegistered() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let matchingSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteBuddy/Devices/HIDRemoteMonitor.DeviceMatching.swift"),
            encoding: .utf8
        )
        #expect(!matchingSource.contains("hasDeviceCallback"))
        #expect(matchingSource.contains("recordPathReport("))
    }

    private func driveManagerOnlyWindow(
        _ health: inout HIDReportPathHealth,
        startingAt start: UInt64
    ) -> [HIDReportPathHealthEvent] {
        var events = health.record(
            path: .manager,
            duplicate: false,
            nowNanoseconds: start,
            recoveryEnabled: true
        )
        events += health.record(
            path: .manager,
            duplicate: false,
            nowNanoseconds: start + 5_000_000_000,
            recoveryEnabled: true
        )
        events += health.record(
            path: .manager,
            duplicate: false,
            nowNanoseconds: start + 10_000_000_000,
            recoveryEnabled: true
        )
        return events
    }
}
