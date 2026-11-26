import Foundation
import os

/// Some G9N9N hardware/firmware batches send shortened BLE HID reports whose length
/// is shorter than their HID descriptor expects (for example 0x011B sending 2-byte
/// report 2 instead of 3 bytes, or FW 26.7 sending 1-byte report 1 instead of 2 bytes).
/// macOS BTLEServer logs the received payload before dropping it prior to IOHID.
///
/// When the user explicitly enables this compatibility option and manually installs
/// the `com.apple.bluetooth` logging configuration profile, this source reads those
/// dropped reports from `/usr/bin/log stream` and attributes them strictly to
/// configured Chromecast G9N9N peripherals.
enum BTLEServerReportLog {
    struct Report: Equatable, Sendable {
        let reportID: UInt32
        let data: Data
    }

    struct AttributedReport: Equatable, Sendable {
        let peripheral: UUID
        let reportID: UInt32
        let data: Data
    }

    struct RedactedObservation: Equatable, Sendable {
        let peripheral: UUID?
        let reportID: UInt32
    }

    enum Line: Equatable, Sendable {
        case indication(peripheral: UUID, timestamp: TimeInterval)
        case report(Report, timestamp: TimeInterval)
        case redactedReport(reportID: UInt32, timestamp: TimeInterval)
    }

    enum AttributedEvent: Equatable, Sendable {
        case report(AttributedReport)
        case redacted(RedactedObservation)
    }

    static let predicate =
        "(process == \"BTLEServer\" AND eventMessage BEGINSWITH \"Updated input report for ID #\") OR " +
        "(process == \"bluetoothd\" AND " +
        "(eventMessage BEGINSWITH \"Dispatching GATT indication for device\" OR " +
        "eventMessage BEGINSWITH \"Dispatching GATT notification for device\") " +
        "AND eventMessage CONTAINS \"BTLEServer\")"

    /// Maximum gap between bluetoothd's dispatch line and BTLEServer's report line.
    /// Observed gaps reach ~46 ms, so leave comfortable headroom.
    static let attributionWindow: TimeInterval = 0.2

    private static let indicationPattern = try! NSRegularExpression(
        pattern: #"^Dispatching GATT (?:indication|notification) for device "([0-9A-Fa-f-]{36})" to session "#
    )
    private static let reportPattern = try! NSRegularExpression(
        pattern: #"^Updated input report for ID #(\d+): \{length = (\d+), bytes = 0x([0-9a-fA-F]+)\}$"#
    )
    private static let redactedPattern = try! NSRegularExpression(
        pattern: #"^Updated input report for ID #(\d+): <private>$"#
    )

    private static let timestampFormatterLock = OSAllocatedUnfairLock<DateFormatter>(initialState: {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return formatter
    }())

    static func parseTimestamp(_ text: String) -> TimeInterval? {
        timestampFormatterLock.withLock { formatter in
            formatter.date(from: text)?.timeIntervalSince1970
        }
    }

    /// Parses one `log stream --style ndjson` line.
    static func parse(ndjsonLine: String) -> Line? {
        guard let raw = ndjsonLine.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let message = object["eventMessage"] as? String,
              let timestampText = object["timestamp"] as? String,
              let timestamp = parseTimestamp(timestampText)
        else { return nil }
        return parse(message: message, timestamp: timestamp)
    }

    static func parse(message: String, timestamp: TimeInterval) -> Line? {
        let range = NSRange(message.startIndex..., in: message)
        if let match = indicationPattern.firstMatch(in: message, range: range),
           let idRange = Range(match.range(at: 1), in: message),
           let peripheral = UUID(uuidString: String(message[idRange])) {
            return .indication(peripheral: peripheral, timestamp: timestamp)
        }
        if let match = redactedPattern.firstMatch(in: message, range: range),
           let idRange = Range(match.range(at: 1), in: message),
           let reportID = UInt32(message[idRange]) {
            return .redactedReport(reportID: reportID, timestamp: timestamp)
        }
        guard let match = reportPattern.firstMatch(in: message, range: range),
              let idRange = Range(match.range(at: 1), in: message),
              let lengthRange = Range(match.range(at: 2), in: message),
              let bytesRange = Range(match.range(at: 3), in: message),
              let reportID = UInt32(message[idRange]),
              let length = Int(message[lengthRange])
        else { return nil }

        let hex = message[bytesRange]
        // Long payloads are abbreviated by Foundation; only exact short payloads are usable.
        guard length > 0, length <= 16, hex.count == length * 2 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(length)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return .report(Report(reportID: reportID, data: Data(bytes)), timestamp: timestamp)
    }

    /// Pairs indication/notification and report lines, keeping only reports whose
    /// peripheral identity is verifiably attributed and part of `peripherals`.
    ///
    /// - Interleaved dispatch lines from multiple BLE peripherals within
    ///   `attributionWindow` make the following report ambiguous and are dropped.
    /// - Dispatch-less all-zero release reports are only accepted when strictly
    ///   one target remote is held, no other BLE peripheral has emitted any
    ///   indication since that press, and the release arrives within
    ///   `maxMissingDispatchReleaseWindow`.
    struct Attributor: Sendable {
        static let maxMissingDispatchReleaseWindow: TimeInterval = 10.0

        private struct HeldState: Sendable {
            var reportID: UInt32
            var maxLength: Int
            var pressedAt: TimeInterval
            var taintedByOtherPeripheral: Bool
        }

        private var pendingIndications: [(peripheral: UUID, timestamp: TimeInterval)] = []
        private var heldByPeripheral: [UUID: HeldState] = [:]
        private var lastActivityByPeripheral: [UUID: TimeInterval] = [:]

        private mutating func pruneExpired(before timestamp: TimeInterval) {
            pendingIndications.removeAll { timestamp - $0.timestamp > BTLEServerReportLog.attributionWindow }
            lastActivityByPeripheral = lastActivityByPeripheral.filter {
                abs(timestamp - $0.value) <= BTLEServerReportLog.attributionWindow
            }
        }

        private func hasConcurrentActivity(fromOtherThan peripheral: UUID, around timestamp: TimeInterval) -> Bool {
            lastActivityByPeripheral.contains { otherPeripheral, otherTime in
                otherPeripheral != peripheral && abs(timestamp - otherTime) <= BTLEServerReportLog.attributionWindow
            }
        }

        private func hasNonTargetActivity(among peripherals: Set<UUID>, around timestamp: TimeInterval) -> Bool {
            lastActivityByPeripheral.contains { peripheral, time in
                !peripherals.contains(peripheral) && abs(timestamp - time) <= BTLEServerReportLog.attributionWindow
            }
        }

        mutating func accept(_ line: Line, peripherals: Set<UUID>) -> AttributedEvent? {
            switch line {
            case let .indication(peripheral, timestamp):
                pruneExpired(before: timestamp)
                for heldPeripheral in heldByPeripheral.keys where heldPeripheral != peripheral {
                    heldByPeripheral[heldPeripheral]?.taintedByOtherPeripheral = true
                }
                lastActivityByPeripheral[peripheral] = timestamp
                pendingIndications.append((peripheral, timestamp))
                return nil

            case let .redactedReport(reportID, timestamp):
                pruneExpired(before: timestamp)
                let valid = pendingIndications.filter {
                    let delta = timestamp - $0.timestamp
                    return delta >= -0.005 && delta <= BTLEServerReportLog.attributionWindow
                }
                if !valid.isEmpty {
                    let distinct = Set(valid.map(\.peripheral))
                    if distinct.count > 1 {
                        pendingIndications.removeAll()
                        return nil
                    }
                    let matched = valid[0]
                    if let removeIndex = pendingIndications.firstIndex(where: {
                        $0.peripheral == matched.peripheral && $0.timestamp == matched.timestamp
                    }) {
                        pendingIndications.remove(at: removeIndex)
                    }
                    guard peripherals.contains(matched.peripheral),
                          !hasConcurrentActivity(fromOtherThan: matched.peripheral, around: timestamp)
                    else { return nil }
                    return .redacted(RedactedObservation(peripheral: matched.peripheral, reportID: reportID))
                }
                // Without the logging profile, bluetoothd also logs `<private>` for the
                // peripheral UUID so no indication line is matched.
                guard !peripherals.isEmpty,
                      reportID == 1 || reportID == 2,
                      !hasNonTargetActivity(among: peripherals, around: timestamp)
                else { return nil }
                return .redacted(RedactedObservation(peripheral: nil, reportID: reportID))

            case let .report(report, timestamp):
                pruneExpired(before: timestamp)
                let valid = pendingIndications.filter {
                    let delta = timestamp - $0.timestamp
                    return delta >= -0.005 && delta <= BTLEServerReportLog.attributionWindow
                }
                if !valid.isEmpty {
                    let distinct = Set(valid.map(\.peripheral))
                    if distinct.count > 1 {
                        pendingIndications.removeAll()
                        return nil
                    }
                    let matched = valid[0]
                    if let removeIndex = pendingIndications.firstIndex(where: {
                        $0.peripheral == matched.peripheral && $0.timestamp == matched.timestamp
                    }) {
                        pendingIndications.remove(at: removeIndex)
                    }
                    guard !hasConcurrentActivity(fromOtherThan: matched.peripheral, around: timestamp),
                          peripherals.contains(matched.peripheral)
                    else { return nil }
                    track(report, for: matched.peripheral, at: timestamp)
                    return .report(AttributedReport(
                        peripheral: matched.peripheral,
                        reportID: report.reportID,
                        data: report.data
                    ))
                }
                guard report.data.allSatisfy({ $0 == 0 }),
                      heldByPeripheral.count == 1,
                      let (candidate, held) = heldByPeripheral.first,
                      peripherals.contains(candidate),
                      !held.taintedByOtherPeripheral,
                      held.reportID == report.reportID,
                      (1...held.maxLength).contains(report.data.count),
                      timestamp >= held.pressedAt,
                      timestamp - held.pressedAt <= Self.maxMissingDispatchReleaseWindow
                else { return nil }
                heldByPeripheral.removeValue(forKey: candidate)
                return .report(AttributedReport(
                    peripheral: candidate,
                    reportID: report.reportID,
                    data: report.data
                ))
            }
        }

        private mutating func track(_ report: Report, for peripheral: UUID, at timestamp: TimeInterval) {
            if report.data.allSatisfy({ $0 == 0 }) {
                heldByPeripheral.removeValue(forKey: peripheral)
            } else {
                let existing = heldByPeripheral[peripheral]
                let previousMax = existing?.reportID == report.reportID ? (existing?.maxLength ?? 0) : 0
                heldByPeripheral[peripheral] = HeldState(
                    reportID: report.reportID,
                    maxLength: max(previousMax, report.data.count),
                    pressedAt: timestamp,
                    taintedByOtherPeripheral: false
                )
            }
        }
    }
}

/// Streams attributed reports from `/usr/bin/log stream`. Callbacks arrive on the main queue.
final class BTLEServerReportLogSource: @unchecked Sendable {
    private let targetPeripherals: OSAllocatedUnfairLock<Set<UUID>>
    private let onReport: @Sendable (BTLEServerReportLog.AttributedReport) -> Void
    private let onRedactedReport: @Sendable (BTLEServerReportLog.RedactedObservation) -> Void
    private let diagnosticLogger: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "RemoteBuddy.BTLEServerReportLog")
    private var process: Process?
    private var stopped = true
    private var attributor = BTLEServerReportLog.Attributor()
    private var buffer = Data()
    private var restartCount = 0

    init(
        peripherals: Set<UUID>,
        diagnosticLogger: @escaping @Sendable (String) -> Void,
        onReport: @escaping @Sendable (BTLEServerReportLog.AttributedReport) -> Void,
        onRedactedReport: @escaping @Sendable (BTLEServerReportLog.RedactedObservation) -> Void = { _ in }
    ) {
        self.targetPeripherals = OSAllocatedUnfairLock(initialState: peripherals)
        self.diagnosticLogger = diagnosticLogger
        self.onReport = onReport
        self.onRedactedReport = onRedactedReport
    }

    deinit {
        process?.terminationHandler = nil
        process?.terminate()
    }

    func updatePeripherals(_ peripherals: Set<UUID>) {
        targetPeripherals.withLock { $0 = peripherals }
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.stopped else { return }
            self.stopped = false
            self.restartCount = 0
            self.launch()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.process?.terminationHandler = nil
            self.process?.terminate()
            self.process = nil
            self.buffer.removeAll()
        }
    }

    private func launch() {
        guard !stopped else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "stream", "--style", "ndjson", "--level", "debug",
            "--predicate", BTLEServerReportLog.predicate,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        buffer.removeAll()
        attributor = BTLEServerReportLog.Attributor()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let source = self else { return }
            source.queue.async { source.consume(chunk) }
        }
        process.terminationHandler = { [weak self] _ in
            guard let source = self else { return }
            source.queue.async {
                guard !source.stopped else { return }
                source.restartCount += 1
                let delay = min(30.0, Double(source.restartCount))
                source.diagnosticLogger("HID BTLE_LOG exited restart_in=\(Int(delay))s")
                source.queue.asyncAfter(deadline: .now() + delay) { [weak source] in
                    source?.launch()
                }
            }
        }
        do {
            try process.run()
            self.process = process
            diagnosticLogger("HID BTLE_LOG started")
        } catch {
            diagnosticLogger("HID BTLE_LOG launch_failed error=\(error.localizedDescription)")
        }
    }

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let line = String(data: lineData, encoding: .utf8),
                  let parsed = BTLEServerReportLog.parse(ndjsonLine: line)
            else { continue }
            let targets = targetPeripherals.withLock { $0 }
            guard let event = attributor.accept(parsed, peripherals: targets) else { continue }
            switch event {
            case let .report(attributed):
                restartCount = 0
                DispatchQueue.main.async { [onReport] in onReport(attributed) }
            case let .redacted(observation):
                DispatchQueue.main.async { [onRedactedReport] in onRedactedReport(observation) }
            }
        }
    }
}
