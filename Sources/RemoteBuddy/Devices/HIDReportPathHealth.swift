import Foundation

enum HIDReportCallbackPath: Equatable, Sendable {
    case manager
    case device
    case simulated

    var logName: String {
        switch self {
        case .manager: "manager"
        case .device: "device"
        case .simulated: "simulated"
        }
    }
}

enum HIDReportClock {
    private static let timebaseInfo: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func uptimeNanoseconds(fromMachTime machTime: UInt64 = mach_absolute_time()) -> UInt64 {
        guard timebaseInfo.denom > 0 else { return machTime }
        let (product, overflow) = machTime.multipliedReportingOverflow(by: UInt64(timebaseInfo.numer))
        if !overflow {
            return product / UInt64(timebaseInfo.denom)
        }
        let divided = machTime / UInt64(timebaseInfo.denom)
        return divided.multipliedReportingOverflow(by: UInt64(timebaseInfo.numer)).partialValue
    }
}

struct HIDReportDeduplicationKey: Equatable {
    let devicePointer: UInt
    let reportID: UInt32
    let data: Data
}

/// Deduplicates physical reports when both manager-level and per-device HID
/// callbacks deliver the same packet on macOS 27+.
///
/// Deduplication is strictly based on actual arrivals within a 50 ms window
/// rather than callback registration state, so manager fallback stays active
/// whenever a registered device callback silently stops firing.
struct HIDReportDeduplicationCache {
    struct Entry {
        let key: HIDReportDeduplicationKey
        let timestampNanoseconds: UInt64
    }

    static let duplicateWindowNanoseconds: UInt64 = 50_000_000
    private static let retentionNanoseconds: UInt64 = 250_000_000
    private static let maximumEntries = 8

    private(set) var entries: [Entry] = []

    mutating func shouldDrop(
        key: HIDReportDeduplicationKey,
        timestampNanoseconds: UInt64
    ) -> Bool {
        entries.removeAll {
            Self.distance($0.timestampNanoseconds, timestampNanoseconds) > Self.retentionNanoseconds
        }
        if entries.contains(where: {
            $0.key == key &&
                Self.distance($0.timestampNanoseconds, timestampNanoseconds) <= Self.duplicateWindowNanoseconds
        }) {
            return true
        }
        entries.append(Entry(key: key, timestampNanoseconds: timestampNanoseconds))
        if entries.count > Self.maximumEntries {
            entries.removeFirst(entries.count - Self.maximumEntries)
        }
        return false
    }

    private static func distance(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs >= rhs ? lhs - rhs : rhs - lhs
    }
}

struct HIDReportPathWindow: Equatable {
    let windowMilliseconds: Int
    let deviceReports: Int
    let managerReports: Int
    let duplicateReports: Int
    let fallbackReports: Int

    var deviceHealthy: Bool { deviceReports > 0 }
}

enum HIDReportPathHealthEvent: Equatable {
    case deviceDeliveryConfirmed
    case deviceDeliveryRecovered
    case managerFallback
    case window(HIDReportPathWindow)
    case recoveryCandidate(attempt: Int, managerReports: Int)
    case recoveryExhausted(attempts: Int)
}

/// Tracks delivery health across manager and per-device report paths per monitor
/// instance and requests bounded device-callback recovery when only manager
/// reports arrive across two consecutive 10-second windows.
struct HIDReportPathHealth {
    static let windowNanoseconds: UInt64 = 10_000_000_000
    static let recentDeviceWindowNanoseconds: UInt64 = 2_000_000_000
    static let recoveryThrottleNanoseconds: UInt64 = 60_000_000_000
    static let maximumRecoveryAttempts = 3

    private var windowStartNanoseconds: UInt64?
    private var lastReportNanoseconds: UInt64?
    private var lastDeviceReportNanoseconds: UInt64?
    private var deviceReports = 0
    private var managerReports = 0
    private var duplicateReports = 0
    private var fallbackReports = 0
    private var consecutiveManagerOnlyWindows = 0
    private var didLogDeviceDeliveryConfirmed = false
    private var didLogManagerFallback = false
    private var lastRecoveryNanoseconds: UInt64?
    private var recoveryAttempts = 0
    private var didLogRecoveryExhausted = false

    mutating func record(
        path: HIDReportCallbackPath,
        duplicate: Bool,
        nowNanoseconds: UInt64,
        recoveryEnabled: Bool
    ) -> [HIDReportPathHealthEvent] {
        guard path != .simulated else { return [] }

        if let last = lastReportNanoseconds, nowNanoseconds >= last,
           nowNanoseconds - last > Self.windowNanoseconds {
            resetWindow(nowNanoseconds: nowNanoseconds)
        }
        if windowStartNanoseconds == nil {
            windowStartNanoseconds = nowNanoseconds
        }
        lastReportNanoseconds = nowNanoseconds

        var events: [HIDReportPathHealthEvent] = []
        switch path {
        case .device:
            deviceReports += 1
            lastDeviceReportNanoseconds = nowNanoseconds
            if !didLogDeviceDeliveryConfirmed {
                didLogDeviceDeliveryConfirmed = true
                if !didLogManagerFallback {
                    events.append(.deviceDeliveryConfirmed)
                }
            }
            if didLogManagerFallback {
                didLogManagerFallback = false
                events.append(.deviceDeliveryRecovered)
            }
        case .manager:
            managerReports += 1
        case .simulated:
            return []
        }

        if duplicate {
            duplicateReports += 1
        } else if path == .manager {
            let deviceIsRecent = lastDeviceReportNanoseconds.map {
                nowNanoseconds >= $0 &&
                    nowNanoseconds - $0 <= Self.recentDeviceWindowNanoseconds
            } ?? false
            if !deviceIsRecent {
                fallbackReports += 1
                if !didLogManagerFallback {
                    didLogManagerFallback = true
                    events.append(.managerFallback)
                }
            }
        }

        events.append(contentsOf: recordWindowIfNeeded(
            nowNanoseconds: nowNanoseconds,
            recoveryEnabled: recoveryEnabled
        ))
        return events
    }

    private mutating func recordWindowIfNeeded(
        nowNanoseconds: UInt64,
        recoveryEnabled: Bool
    ) -> [HIDReportPathHealthEvent] {
        guard let start = windowStartNanoseconds,
              nowNanoseconds >= start,
              nowNanoseconds - start >= Self.windowNanoseconds
        else { return [] }

        let window = HIDReportPathWindow(
            windowMilliseconds: Int((nowNanoseconds - start) / 1_000_000),
            deviceReports: deviceReports,
            managerReports: managerReports,
            duplicateReports: duplicateReports,
            fallbackReports: fallbackReports
        )
        var result: [HIDReportPathHealthEvent] = [.window(window)]

        if window.managerReports > 0, window.deviceReports == 0 {
            consecutiveManagerOnlyWindows += 1
        } else {
            consecutiveManagerOnlyWindows = 0
        }
        resetWindow(nowNanoseconds: nowNanoseconds)

        if consecutiveManagerOnlyWindows >= 2 {
            result.append(contentsOf: requestRecovery(
                nowNanoseconds: nowNanoseconds,
                managerReports: window.managerReports,
                recoveryEnabled: recoveryEnabled
            ))
        }
        return result
    }

    private mutating func requestRecovery(
        nowNanoseconds: UInt64,
        managerReports: Int,
        recoveryEnabled: Bool
    ) -> [HIDReportPathHealthEvent] {
        if let last = lastRecoveryNanoseconds,
           nowNanoseconds >= last,
           nowNanoseconds - last < Self.recoveryThrottleNanoseconds {
            return []
        }
        if recoveryAttempts >= Self.maximumRecoveryAttempts {
            guard !didLogRecoveryExhausted else { return [] }
            didLogRecoveryExhausted = true
            return [.recoveryExhausted(attempts: recoveryAttempts)]
        }

        lastRecoveryNanoseconds = nowNanoseconds
        consecutiveManagerOnlyWindows = 0
        guard recoveryEnabled else { return [] }

        recoveryAttempts += 1
        return [.recoveryCandidate(attempt: recoveryAttempts, managerReports: managerReports)]
    }

    private mutating func resetWindow(nowNanoseconds: UInt64) {
        windowStartNanoseconds = nowNanoseconds
        deviceReports = 0
        managerReports = 0
        duplicateReports = 0
        fallbackReports = 0
    }
}
