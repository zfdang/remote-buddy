import AppKit
import Foundation
import IOKit.hidsystem

enum RemoteHIDReportParser {
    static func usages(reportID: UInt32, data: Data) -> Set<UInt16>? {
        guard reportID == 1 else { return nil }
        var bytes = Array(data)
        if bytes.count > 1, !bytes.count.isMultiple(of: 2), bytes.first == UInt8(reportID) {
            bytes.removeFirst()
        }
        guard bytes.count.isMultiple(of: 2) else { return nil }

        var result = Set<UInt16>()
        for index in stride(from: 0, to: bytes.count, by: 2) {
            let usage = UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
            if usage != 0 { result.insert(usage) }
        }
        return result
    }
}

enum HIDPermissionGate {
    static func canMonitor(
        inputMonitoringGranted: Bool,
        accessibilityGranted: Bool,
        powerKeySuppressed: Bool
    ) -> Bool {
        inputMonitoringGranted && accessibilityGranted && powerKeySuppressed
    }

    static func nextPermissionRequest(
        inputMonitoringGranted: Bool,
        accessibilityGranted: Bool
    ) -> HIDPermissionRequest {
        if !inputMonitoringGranted { return .inputMonitoring }
        if !accessibilityGranted { return .accessibility }
        return .none
    }
}

enum HIDPermissionRequest: Equatable {
    case none
    case inputMonitoring
    case accessibility
}
