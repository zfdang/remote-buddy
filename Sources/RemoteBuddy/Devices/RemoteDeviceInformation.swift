import Foundation

/// Information read during the current BLE connection, never inferred from a catalog.
struct RemoteDeviceInformation: Equatable {
    var modelNumber: String?
    var firmwareRevision: String?
    var identity: RemoteHIDIdentity?
    var hidVersion: UInt16?
    var capabilities: ATVVCapabilities?
    var hardwareRevision: String?

    static func deviceString(_ data: Data) -> String? {
        guard let value = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        return trimmed.isEmpty ? nil : trimmed
    }

    static func formatLogValue(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        var collapsed = ""
        var pendingSpace = false
        for scalar in trimmed.unicodeScalars {
            if CharacterSet.newlines.union(.controlCharacters).contains(scalar) {
                pendingSpace = !collapsed.isEmpty
            } else {
                if pendingSpace {
                    collapsed.append(" ")
                    pendingSpace = false
                }
                collapsed.append(Character(scalar))
            }
        }
        let safe = collapsed.replacingOccurrences(of: "\"", with: "'")
        return safe.contains(" ") ? "\"\(safe)\"" : safe
    }

    static func firmwareLogLine(from data: Data) -> String {
        if let value = deviceString(data) {
            return "BLE FIRMWARE observed firmwareRevision=\(formatLogValue(value))"
        }
        return "BLE FIRMWARE unreadable bytes=\(data.count)"
    }

    static func hardwareLogLine(from data: Data) -> String {
        if let value = deviceString(data) {
            return "BLE HARDWARE observed hardwareRevision=\(formatLogValue(value))"
        }
        return "BLE HARDWARE unreadable bytes=\(data.count)"
    }

    var identityValue: String? {
        identity.map { String(format: "%04X / %04X", $0.vendorID, $0.productID) }
    }

    private var compactIdentityValue: String? {
        identity.map { String(format: "%04X/%04X", $0.vendorID, $0.productID) }
    }

    var hidVersionValue: String? {
        hidVersion.map { String(format: "0x%04X", $0) }
    }

    @MainActor
    func conciseHardwareSummary(using localization: LocalizationStore) -> String? {
        var parts: [String] = []
        if let modelNumber {
            parts.append("\(localization.text("connection.device.model")) \(modelNumber)")
        }
        if let compactIdentityValue {
            parts.append("VID/PID \(compactIdentityValue)")
        }
        if let hidVersionValue {
            parts.append("\(localization.text("connection.device.hid_version")) \(hidVersionValue)")
        }
        if let firmwareRevision {
            parts.append("\(localization.text("connection.device.firmware")) \(firmwareRevision)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var protocolVersion: String? {
        capabilities.map { "ATVV \($0.version >> 8).\($0.version & 0xFF)" }
    }

    var audioFormat: String? {
        guard let capabilities else { return nil }
        let codec = [UInt8(1), 2].contains(capabilities.selectedCodec)
            ? "IMA ADPCM" : String(format: "Codec 0x%02X", capabilities.selectedCodec)
        let rate = String(format: "%g", capabilities.sampleRate / 1_000)
        return "\(rate) kHz · \(codec)"
    }
}
