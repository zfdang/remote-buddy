import Foundation
import IOKit.hid

struct RemoteHIDIdentity: Codable, Hashable {
    let vendorID: UInt16
    let productID: UInt16

    static let xiaomi = Self(vendorID: 0x2717, productID: 0x32B8)
    static let chromecast = Self(vendorID: 0x18D1, productID: 0x9450)
    static let t1Remote = Self(vendorID: T1RemoteProtocol.vendorID, productID: T1RemoteProtocol.productID)
    var isStandard: Bool { self == .xiaomi || self == .chromecast || self == .t1Remote }
    var matchingDictionary: [String: Any] {
        [kIOHIDVendorIDKey: Int(vendorID), kIOHIDProductIDKey: Int(productID)]
    }

    struct PnPInfo: Equatable {
        let vendorIDSource: UInt8
        let identity: RemoteHIDIdentity
        let productVersion: UInt16?
    }

    // Bluetooth DIS PnP ID: namespace byte, then little-endian VID/PID/version.
    // It is only a hint until matched to actual Bluetooth HID metadata.
    static func parsePnPInfo(_ data: Data) -> PnPInfo? {
        let bytes = Array(data)
        guard bytes.count == 7, bytes[0] == 1 || bytes[0] == 2 else { return nil }
        let vendor = UInt16(bytes[1]) | UInt16(bytes[2]) << 8
        guard vendor != 0 else { return nil }
        let product = UInt16(bytes[3]) | UInt16(bytes[4]) << 8
        let version = UInt16(bytes[5]) | UInt16(bytes[6]) << 8
        return PnPInfo(
            vendorIDSource: bytes[0],
            identity: Self(vendorID: vendor, productID: product),
            productVersion: version == 0 ? nil : version
        )
    }

    static func fromPnP(_ data: Data) -> Self? {
        parsePnPInfo(data)?.identity
    }

    static func productVersionFromPnP(_ data: Data) -> UInt16? {
        parsePnPInfo(data)?.productVersion
    }

    static func pnpLogFields(from data: Data) -> String {
        guard let info = parsePnPInfo(data) else {
            return "unreadable raw_bytes=\(data.count)"
        }
        let vid = String(format: "%04X", info.identity.vendorID)
        let pid = String(format: "%04X", info.identity.productID)
        let hidVersion = info.productVersion.map { String(format: "0x%04X", $0) } ?? "none"
        return "vendor_source=\(info.vendorIDSource) vid=\(vid) pid=\(pid) hid_version=\(hidVersion)"
    }

    private static func trimmedProperty(_ device: IOHIDDevice, key: String) -> String? {
        guard let raw = IOHIDDeviceGetProperty(device, key as CFString) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        return trimmed.isEmpty ? nil : trimmed
    }

    static func readHardwareInfo(
        from device: IOHIDDevice,
        metadataIdentity: RemoteHIDIdentity? = nil,
        reportDescriptor: Data? = nil
    ) -> HIDDeviceHardwareInfo {
        let identity = metadataIdentity ?? read(from: device)
        let versionNumber = readVersionNumber(from: device)
        let maxInput = (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? NSNumber)?.intValue
        let maxInputReportSize = maxInput.flatMap { $0 > 0 ? $0 : nil }
        let descriptor = reportDescriptor ?? (IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data)
        let reportDescriptorBytes = descriptor.flatMap { $0.isEmpty ? nil : $0.count }
        let indexedConsumerLayout = descriptor.map { G9N9NProtocol.usesIndexedConsumerLayout($0) }
        return HIDDeviceHardwareInfo(
            identity: identity,
            versionNumber: versionNumber,
            maxInputReportSize: maxInputReportSize,
            reportDescriptorBytes: reportDescriptorBytes,
            indexedConsumerLayout: indexedConsumerLayout,
            modelNumber: trimmedProperty(device, key: "ModelNumber"),
            firmwareRevision: trimmedProperty(device, key: "kBTFirmwareRevisionKey"),
            hardwareRevision: trimmedProperty(device, key: "kBTHardwareRevisionKey")
        )
    }

    static func read(from device: IOHIDDevice) -> Self? {
        guard let vendor = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? NSNumber,
              let product = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber,
              (1...65535).contains(vendor.intValue), (0...65535).contains(product.intValue)
        else { return nil }
        return Self(vendorID: UInt16(vendor.intValue), productID: UInt16(product.intValue))
    }

    static func readVersionNumber(from device: IOHIDDevice) -> UInt16? {
        guard let version = IOHIDDeviceGetProperty(device, kIOHIDVersionNumberKey as CFString) as? NSNumber,
              (1...65535).contains(version.intValue)
        else { return nil }
        return UInt16(version.intValue)
    }

    static func readVersionNumber(forFingerprint fingerprint: String) -> UInt16? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        for device in devices {
            guard HIDRemoteMonitor.fingerprint(for: device) == fingerprint,
                  let version = readVersionNumber(from: device)
            else { continue }
            return version
        }
        return nil
    }
}

struct HIDDeviceHardwareInfo: Equatable {
    let identity: RemoteHIDIdentity?
    let versionNumber: UInt16?
    let maxInputReportSize: Int?
    let reportDescriptorBytes: Int?
    let indexedConsumerLayout: Bool?
    let modelNumber: String?
    let firmwareRevision: String?
    let hardwareRevision: String?

    var logFields: String {
        var fields: [String] = []
        if let identity {
            fields.append(String(format: "vid=%04X pid=%04X", identity.vendorID, identity.productID))
        }
        if let versionNumber {
            fields.append(String(format: "hid_version=0x%04X", versionNumber))
        }
        if let maxInputReportSize {
            fields.append("max_input_bytes=\(maxInputReportSize)")
        }
        if let reportDescriptorBytes {
            fields.append("descriptor_bytes=\(reportDescriptorBytes)")
        }
        if let indexedConsumerLayout {
            fields.append("indexed_consumer=\(indexedConsumerLayout)")
        }
        if let modelNumber {
            fields.append("model=\(RemoteDeviceInformation.formatLogValue(modelNumber))")
        }
        if let firmwareRevision {
            fields.append("firmware=\(RemoteDeviceInformation.formatLogValue(firmwareRevision))")
        }
        if let hardwareRevision {
            fields.append("hardware=\(RemoteDeviceInformation.formatLogValue(hardwareRevision))")
        }
        return fields.joined(separator: " ")
    }
}

struct RemoteHIDBinding: Codable, Equatable {
    let identity: RemoteHIDIdentity
    let fingerprint: String
}

struct RemoteHIDCandidate: Identifiable, Equatable {
    let binding: RemoteHIDBinding
    let name: String
    var id: String { binding.fingerprint }

    // Read-only enumeration. Selection never requires opening every device.
    static func available() -> [Self] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        let pairedNames = RemoteDeviceNameReader.readHIDNames()
        let candidates = devices.compactMap { device -> Self? in
            let page = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? NSNumber)?.intValue
            let usage = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? NSNumber)?.intValue
            guard page == 0x0C || (page == 0x01 && usage == 0x06),
                  let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String,
                  transport.lowercased().contains("bluetooth"),
                  let identity = RemoteHIDIdentity.read(from: device),
                  let fingerprint = HIDRemoteMonitor.fingerprint(for: device),
                  let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return Self(binding: RemoteHIDBinding(identity: identity, fingerprint: fingerprint), name: pairedNames[fingerprint]?.name ?? name)
        }
        return unambiguous(candidates).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func unambiguous(_ candidates: [Self]) -> [Self] {
        Dictionary(grouping: candidates, by: \.id).values.compactMap { interfaces in
            guard let first = interfaces.first,
                  interfaces.allSatisfy({ $0.binding == first.binding }) else { return nil }
            return first
        }
    }

    static func identified(identity: RemoteHIDIdentity, expectedName: String? = nil, among candidates: [Self]) -> Self? {
        let normalizedName = expectedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedName, normalizedName.isEmpty { return nil }
        let matches = unambiguous(candidates).filter { candidate in
            guard candidate.binding.identity == identity else { return false }
            guard let normalizedName else { return true }
            return candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(normalizedName) == .orderedSame
        }
        return matches.count == 1 ? matches.first : nil
    }
}
