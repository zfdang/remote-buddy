import Foundation

enum RemotePowerState: Equatable {
    case onBattery
    case externalPower
    case charging
    case unknown

    var logValue: String {
        switch self {
        case .onBattery: return "on_battery"
        case .externalPower: return "external_power"
        case .charging: return "charging"
        case .unknown: return "unknown"
        }
    }

    static func decodeBatteryLevelStatus(_ data: Data) -> RemotePowerState? {
        guard data.count >= 3 else { return nil }
        let powerState = UInt16(data[data.startIndex + 1]) |
            UInt16(data[data.startIndex + 2]) << 8
        let batteryPresent = powerState & 0x0001 == 0x0001
        guard batteryPresent else { return .unknown }

        let wiredExternalPower = (powerState >> 1) & 0x0003
        let wirelessExternalPower = (powerState >> 3) & 0x0003
        let chargeState = (powerState >> 5) & 0x0003

        if chargeState == 0x0001 {
            return .charging
        }
        if wiredExternalPower == 0x0001 || wirelessExternalPower == 0x0001 {
            return .externalPower
        }
        if wiredExternalPower == 0 && wirelessExternalPower == 0 {
            return .onBattery
        }
        return .unknown
    }
}

struct RemoteDeviceMappings: Codable, Equatable {
    var buttonBindings: [String: ButtonAction]
    var buttonShortcuts: [String: CustomKeyboardShortcut]
    var buttonApplicationProfileIDs: [String: UUID]?
    var secondaryButtonBindings: [String: [String: ConfiguredButtonAction]]

    private enum CodingKeys: String, CodingKey {
        case buttonBindings, buttonShortcuts, buttonApplicationProfileIDs, secondaryButtonBindings
    }

    /// Reads entry by entry: one action, shortcut or gesture this build does not know is
    /// dropped on its own instead of discarding the remote's whole mapping.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        buttonBindings = try container.decodeLossyDictionary(ButtonAction.self, forKey: .buttonBindings)
        buttonShortcuts = try container.decodeLossyDictionary(CustomKeyboardShortcut.self, forKey: .buttonShortcuts)
        buttonApplicationProfileIDs = try container.decodeIfPresent(
            LossyDictionary<UUID>.self, forKey: .buttonApplicationProfileIDs
        )?.entries
        secondaryButtonBindings = try container.decodeLossyDictionary(
            LossyDictionary<ConfiguredButtonAction>.self, forKey: .secondaryButtonBindings
        ).mapValues(\.entries)
        if let log = decoder.lossyDecodingLog { recordUnknownKeys(at: decoder.codingPath, in: log) }
    }

    /// Button and gesture keys this build has no case for still decode as strings and are kept,
    /// but nothing reads them, so they are reported: the raw bytes are then preserved before the
    /// next save rebuilds the mapping from the known keys only.
    private func recordUnknownKeys(at path: [any CodingKey], in log: LossyDecodingLog) {
        let tables: [(CodingKeys, [String])] = [
            (.buttonBindings, Array(buttonBindings.keys)),
            (.buttonShortcuts, Array(buttonShortcuts.keys)),
            (.buttonApplicationProfileIDs, Array((buttonApplicationProfileIDs ?? [:]).keys)),
        ]
        for (table, keys) in tables {
            for key in keys.sorted() where RemoteButton(rawValue: key) == nil {
                log.record(path + [table as any CodingKey, LossyCodingKey(stringValue: key)])
            }
        }
        for (button, bindings) in secondaryButtonBindings.sorted(by: { $0.key < $1.key }) {
            let buttonPath: [any CodingKey] = path + [
                CodingKeys.secondaryButtonBindings as any CodingKey, LossyCodingKey(stringValue: button),
            ]
            guard RemoteButton(rawValue: button) != nil else {
                log.record(buttonPath)
                continue
            }
            for trigger in bindings.keys.sorted() where ButtonTrigger(rawValue: trigger) == nil {
                log.record(buttonPath + [LossyCodingKey(stringValue: trigger)])
            }
        }
    }

    init(
        buttonBindings: [RemoteButton: ButtonAction],
        buttonShortcuts: [RemoteButton: CustomKeyboardShortcut],
        buttonApplicationProfileIDs: [RemoteButton: UUID] = [:],
        secondaryButtonBindings: [RemoteButton: [ButtonTrigger: ConfiguredButtonAction]]
    ) {
        self.buttonBindings = Dictionary(
            uniqueKeysWithValues: buttonBindings.map { ($0.key.rawValue, $0.value) }
        )
        self.buttonShortcuts = Dictionary(
            uniqueKeysWithValues: buttonShortcuts.map { ($0.key.rawValue, $0.value) }
        )
        let applicationProfileIDs = Dictionary(
            uniqueKeysWithValues: buttonApplicationProfileIDs.map { ($0.key.rawValue, $0.value) }
        )
        self.buttonApplicationProfileIDs = applicationProfileIDs.isEmpty ? nil : applicationProfileIDs
        self.secondaryButtonBindings = Dictionary(
            uniqueKeysWithValues: secondaryButtonBindings.map { button, bindings in
                (
                    button.rawValue,
                    Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
                )
            }
        )
    }

    var parsedButtonBindings: [RemoteButton: ButtonAction] {
        Dictionary(uniqueKeysWithValues: buttonBindings.compactMap { key, value in
            RemoteButton(rawValue: key).map { ($0, value) }
        })
    }

    var parsedButtonShortcuts: [RemoteButton: CustomKeyboardShortcut] {
        Dictionary(uniqueKeysWithValues: buttonShortcuts.compactMap { key, value in
            RemoteButton(rawValue: key).map { ($0, value) }
        })
    }

    var parsedButtonApplicationProfileIDs: [RemoteButton: UUID] {
        Dictionary(uniqueKeysWithValues: (buttonApplicationProfileIDs ?? [:]).compactMap { key, value in
            RemoteButton(rawValue: key).map { ($0, value) }
        })
    }

    var parsedSecondaryButtonBindings: [RemoteButton: [ButtonTrigger: ConfiguredButtonAction]] {
        Dictionary(uniqueKeysWithValues: secondaryButtonBindings.compactMap { buttonKey, bindings in
            guard let button = RemoteButton(rawValue: buttonKey) else { return nil }
            let parsed = Dictionary(uniqueKeysWithValues: bindings.compactMap { triggerKey, value in
                ButtonTrigger(rawValue: triggerKey).map { ($0, value) }
            })
            return parsed.isEmpty ? nil : (button, parsed)
        })
    }
}

/// Operating mode for Chromecast G9N9N remotes: full single-key support vs.
/// partial compatibility mode for hardware/firmware revisions whose 1-byte
/// single-key reports are dropped by macOS before reaching public IOHID.
enum G9N9NInputMode: String, Codable, Equatable, CaseIterable {
    case full = "full"
    case twoKeyCompatibility = "two_key_compatibility"
}

/// Physical voice button behavior for Chromecast G9N9N remotes.
enum G9N9NVoiceButtonMode: String, Codable, Equatable, CaseIterable {
    case holdToTalk = "hold_to_talk"
    case smartToggle = "smart_toggle"
}

struct RemoteDeviceProfile: Codable, Equatable, Identifiable {
    let id: UUID
    var model: RemoteModel
    var customName: String
    var bluetoothIdentifier: UUID?
    var hidFingerprint: String?
    var gainDB: Double?
    var compatibleHIDBinding: RemoteHIDBinding?
    var g9n9nInputMode: G9N9NInputMode?
    var g9n9nVoiceButtonMode: G9N9NVoiceButtonMode?
    var mappings: RemoteDeviceMappings

    var displayNameFallbackKey: String { model.localizationKey }
    var effectiveG9N9NInputMode: G9N9NInputMode {
        model.isChromecastRemote ? (g9n9nInputMode ?? .full) : .full
    }

    var effectiveG9N9NVoiceButtonMode: G9N9NVoiceButtonMode {
        model.isChromecastRemote ? (g9n9nVoiceButtonMode ?? .smartToggle) : .holdToTalk
    }

    init(
        id: UUID = UUID(),
        model: RemoteModel = .unknown,
        customName: String = "",
        bluetoothIdentifier: UUID? = nil,
        hidFingerprint: String? = nil,
        compatibleHIDBinding: RemoteHIDBinding? = nil,
        gainDB: Double? = nil,
        g9n9nInputMode: G9N9NInputMode? = nil,
        g9n9nVoiceButtonMode: G9N9NVoiceButtonMode? = nil,
        mappings: RemoteDeviceMappings
    ) {
        self.id = id
        self.model = model
        self.customName = customName
        self.bluetoothIdentifier = bluetoothIdentifier
        self.hidFingerprint = hidFingerprint
        self.gainDB = gainDB
        self.compatibleHIDBinding = compatibleHIDBinding
        self.g9n9nInputMode = g9n9nInputMode
        self.g9n9nVoiceButtonMode = g9n9nVoiceButtonMode
        self.mappings = mappings
    }
}
