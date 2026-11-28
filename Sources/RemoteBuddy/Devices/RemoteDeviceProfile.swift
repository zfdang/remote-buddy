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
    var buttonURLs: [String: String]?
    var secondaryButtonBindings: [String: [String: ConfiguredButtonAction]]
    var applicationButtonProfiles: [String: ApplicationButtonProfile]?

    init(
        buttonBindings: [RemoteButton: ButtonAction],
        buttonShortcuts: [RemoteButton: CustomKeyboardShortcut],
        buttonApplicationProfileIDs: [RemoteButton: UUID] = [:],
        buttonURLs: [RemoteButton: String] = [:],
        secondaryButtonBindings: [RemoteButton: [ButtonTrigger: ConfiguredButtonAction]],
        applicationButtonProfiles: [String: ApplicationButtonProfile] = [:]
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
        let encodedURLs = Dictionary(
            uniqueKeysWithValues: buttonURLs.map { ($0.key.rawValue, $0.value) }
        )
        self.buttonURLs = encodedURLs.isEmpty ? nil : encodedURLs
        self.secondaryButtonBindings = Dictionary(
            uniqueKeysWithValues: secondaryButtonBindings.map { button, bindings in
                (
                    button.rawValue,
                    Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
                )
            }
        )
        self.applicationButtonProfiles = applicationButtonProfiles.isEmpty ? nil : applicationButtonProfiles
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

    var parsedButtonURLs: [RemoteButton: String] {
        Dictionary(uniqueKeysWithValues: (buttonURLs ?? [:]).compactMap { key, value in
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

    var parsedApplicationButtonProfiles: [String: ApplicationButtonProfile] {
        applicationButtonProfiles ?? [:]
    }
}

/// Operating mode for Chromecast G9N9N remotes: full native single-key support via IOHID,
/// or full single-key support recovered via the opt-in `.mobileconfig` Bluetooth logging profile.
enum G9N9NInputMode: String, Codable, Equatable, CaseIterable {
    case full = "full"
    case bluetoothLogRecovery = "bluetooth_log_recovery"
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
    var lastObservedSystemName: String?
    var hardwareShortID: String?
    var bluetoothIdentifier: UUID?
    var hidFingerprint: String?
    var gainDB: Double?
    var compatibleHIDBinding: RemoteHIDBinding?
    var g9n9nInputMode: G9N9NInputMode?
    var g9n9nVoiceButtonMode: G9N9NVoiceButtonMode?
    var seededDefaultApplicationProfiles: [String]?
    var mappings: RemoteDeviceMappings

    var displayNameFallbackKey: String { model.localizationKey }
    var effectiveG9N9NInputMode: G9N9NInputMode {
        model.isChromecastRemote ? (g9n9nInputMode ?? .full) : .full
    }

    var effectiveG9N9NVoiceButtonMode: G9N9NVoiceButtonMode {
        model.isChromecastRemote ? (g9n9nVoiceButtonMode ?? .smartToggle) : .holdToTalk
    }

    enum CodingKeys: String, CodingKey {
        case id
        case model
        case customName
        case lastObservedSystemName
        case hardwareShortID
        case bluetoothIdentifier
        case hidFingerprint
        case gainDB
        case compatibleHIDBinding
        case g9n9nInputMode
        case g9n9nVoiceButtonMode
        case seededDefaultApplicationProfiles
        case mappings
    }

    init(
        id: UUID = UUID(),
        model: RemoteModel = .unknown,
        customName: String = "",
        lastObservedSystemName: String? = nil,
        hardwareShortID: String? = nil,
        bluetoothIdentifier: UUID? = nil,
        hidFingerprint: String? = nil,
        compatibleHIDBinding: RemoteHIDBinding? = nil,
        gainDB: Double? = nil,
        g9n9nInputMode: G9N9NInputMode? = nil,
        g9n9nVoiceButtonMode: G9N9NVoiceButtonMode? = nil,
        seededDefaultApplicationProfiles: [String]? = nil,
        mappings: RemoteDeviceMappings
    ) {
        self.id = id
        self.model = model
        self.customName = customName
        self.lastObservedSystemName = lastObservedSystemName
        self.hardwareShortID = hardwareShortID
        self.bluetoothIdentifier = bluetoothIdentifier
        self.hidFingerprint = hidFingerprint
        self.gainDB = gainDB
        self.compatibleHIDBinding = compatibleHIDBinding
        self.g9n9nInputMode = g9n9nInputMode
        self.g9n9nVoiceButtonMode = g9n9nVoiceButtonMode
        self.seededDefaultApplicationProfiles = seededDefaultApplicationProfiles?.isEmpty == true
            ? nil
            : seededDefaultApplicationProfiles
        self.mappings = mappings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.model = try container.decode(RemoteModel.self, forKey: .model)
        self.customName = try container.decode(String.self, forKey: .customName)
        self.lastObservedSystemName = try container.decodeIfPresent(String.self, forKey: .lastObservedSystemName)
        self.hardwareShortID = try container.decodeIfPresent(String.self, forKey: .hardwareShortID)
        self.bluetoothIdentifier = try container.decodeIfPresent(UUID.self, forKey: .bluetoothIdentifier)
        self.hidFingerprint = try container.decodeIfPresent(String.self, forKey: .hidFingerprint)
        self.gainDB = try container.decodeIfPresent(Double.self, forKey: .gainDB)
        self.compatibleHIDBinding = try container.decodeIfPresent(RemoteHIDBinding.self, forKey: .compatibleHIDBinding)
        // Tolerate retired input modes (e.g. legacy "two_key_compatibility") per-profile
        // instead of failing decoding of the entire remoteDeviceProfiles array.
        if let rawMode = try container.decodeIfPresent(String.self, forKey: .g9n9nInputMode) {
            self.g9n9nInputMode = G9N9NInputMode(rawValue: rawMode)
        } else {
            self.g9n9nInputMode = nil
        }
        self.g9n9nVoiceButtonMode = try container.decodeIfPresent(
            G9N9NVoiceButtonMode.self,
            forKey: .g9n9nVoiceButtonMode
        )
        self.seededDefaultApplicationProfiles = try container.decodeIfPresent(
            [String].self,
            forKey: .seededDefaultApplicationProfiles
        )
        self.mappings = try container.decode(RemoteDeviceMappings.self, forKey: .mappings)
    }
}
