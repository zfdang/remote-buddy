import Foundation

enum SettingsBackupError: Error, Equatable {
    case notASettingsFile
    case fileTooLarge
}

/// What an import changed and, item by item, what it had to leave out.
struct SettingsBackupImportReport: Equatable {
    struct SkippedItem: Equatable {
        enum Reason: Equatable {
            case unrecognizedValue
            case remoteModelNotOnThisMac
            case unknownApplicationReference
            case mappingLockedByCompatibilityMode
        }

        /// For example `["chromecast_voice_remote", "home", "longPress"]` or `["general", "appIconIdentifier"]`.
        var location: [String]
        var reason: Reason
    }

    var importedRemoteCount = 0
    var skippedItems: [SkippedItem] = []
    var missingApplications: [String] = []
    var sharedRemoteModels: [RemoteModel] = []
    var isFromNewerVersion = false

    var isClean: Bool {
        skippedItems.isEmpty && missingApplications.isEmpty && sharedRemoteModels.isEmpty && !isFromNewerVersion
    }

    mutating func skip(_ location: [String], _ reason: SkippedItem.Reason) {
        let item = SkippedItem(location: location, reason: reason)
        if !skippedItems.contains(item) { skippedItems.append(item) }
    }
}

/// A user-exported copy of the general settings and each remote's mapping. Pairing data,
/// onboarding state and voice settings stay out: they are only valid on the Mac that set them up.
struct SettingsBackupDocument: Codable {
    static let formatIdentifier = "remote-buddy-settings"
    static let currentFormatVersion = 1

    var format: String
    var formatVersion: Int
    var exportedAt: Date?
    var appVersion: String?
    var general: General
    var customApplications: [CustomApplicationProfile]
    var remotes: [Remote]

    struct General: Codable {
        var applicationLanguage: String?
        var appIconIdentifier: String?
        var showDockIcon: Bool?
        var showStatusBarIcon: Bool?
        var openMainWindowAtLaunch: Bool?
        var checksForPreReleaseUpdates: Bool?
        var diagnosticLoggingEnabled: Bool?
        var customMappingEnabled: Bool?
        var disabledApplicationIntegrations: [String]?

        private enum CodingKeys: String, CodingKey {
            case applicationLanguage, appIconIdentifier, showDockIcon, showStatusBarIcon
            case openMainWindowAtLaunch, checksForPreReleaseUpdates, diagnosticLoggingEnabled
            case customMappingEnabled, disabledApplicationIntegrations
        }

        init(
            applicationLanguage: String? = nil,
            appIconIdentifier: String? = nil,
            showDockIcon: Bool? = nil,
            showStatusBarIcon: Bool? = nil,
            openMainWindowAtLaunch: Bool? = nil,
            checksForPreReleaseUpdates: Bool? = nil,
            diagnosticLoggingEnabled: Bool? = nil,
            customMappingEnabled: Bool? = nil,
            disabledApplicationIntegrations: [String]? = nil
        ) {
            self.applicationLanguage = applicationLanguage
            self.appIconIdentifier = appIconIdentifier
            self.showDockIcon = showDockIcon
            self.showStatusBarIcon = showStatusBarIcon
            self.openMainWindowAtLaunch = openMainWindowAtLaunch
            self.checksForPreReleaseUpdates = checksForPreReleaseUpdates
            self.diagnosticLoggingEnabled = diagnosticLoggingEnabled
            self.customMappingEnabled = customMappingEnabled
            self.disabledApplicationIntegrations = disabledApplicationIntegrations
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            applicationLanguage = container.decodeLossyIfPresent(String.self, forKey: .applicationLanguage)
            appIconIdentifier = container.decodeLossyIfPresent(String.self, forKey: .appIconIdentifier)
            showDockIcon = container.decodeLossyIfPresent(Bool.self, forKey: .showDockIcon)
            showStatusBarIcon = container.decodeLossyIfPresent(Bool.self, forKey: .showStatusBarIcon)
            openMainWindowAtLaunch = container.decodeLossyIfPresent(Bool.self, forKey: .openMainWindowAtLaunch)
            checksForPreReleaseUpdates = container.decodeLossyIfPresent(
                Bool.self, forKey: .checksForPreReleaseUpdates)
            diagnosticLoggingEnabled = container.decodeLossyIfPresent(Bool.self, forKey: .diagnosticLoggingEnabled)
            customMappingEnabled = container.decodeLossyIfPresent(Bool.self, forKey: .customMappingEnabled)
            disabledApplicationIntegrations = container.decodeLossyIfPresent(
                [String].self, forKey: .disabledApplicationIntegrations)
        }
    }

    struct Remote: Codable {
        var model: RemoteModel
        var name: String
        var gainDB: Double?
        var g9n9nVoiceButtonMode: G9N9NVoiceButtonMode?
        var mappings: RemoteDeviceMappings

        private enum CodingKeys: String, CodingKey {
            case model, name, gainDB, g9n9nVoiceButtonMode, mappings
        }

        init(
            model: RemoteModel,
            name: String,
            gainDB: Double?,
            g9n9nVoiceButtonMode: G9N9NVoiceButtonMode?,
            mappings: RemoteDeviceMappings
        ) {
            self.model = model
            self.name = name
            self.gainDB = gainDB
            self.g9n9nVoiceButtonMode = g9n9nVoiceButtonMode
            self.mappings = mappings
        }

        /// The model and mapping are the entry; the rest is skipped on its own when unreadable.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            model = try container.decode(RemoteModel.self, forKey: .model)
            mappings = try container.decode(RemoteDeviceMappings.self, forKey: .mappings)
            name = container.decodeLossyIfPresent(String.self, forKey: .name) ?? ""
            gainDB = container.decodeLossyIfPresent(Double.self, forKey: .gainDB)
            g9n9nVoiceButtonMode = container.decodeLossyIfPresent(
                G9N9NVoiceButtonMode.self, forKey: .g9n9nVoiceButtonMode)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case format, formatVersion, exportedAt, appVersion, general, customApplications, remotes
    }

    init(
        exportedAt: Date,
        appVersion: String,
        general: General,
        customApplications: [CustomApplicationProfile],
        remotes: [Remote]
    ) {
        format = Self.formatIdentifier
        formatVersion = Self.currentFormatVersion
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.general = general
        self.customApplications = customApplications
        self.remotes = remotes
    }

    /// Only a missing or foreign header rejects the file; everything below it is read entry by entry.
    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self),
              let format = try? container.decode(String.self, forKey: .format),
              format == Self.formatIdentifier,
              let formatVersion = try? container.decode(Int.self, forKey: .formatVersion)
        else { throw SettingsBackupError.notASettingsFile }
        self.format = format
        self.formatVersion = formatVersion
        // Informational only, so an unreadable value is not worth reporting.
        exportedAt = try? container.decodeIfPresent(Date.self, forKey: .exportedAt)
        appVersion = try? container.decodeIfPresent(String.self, forKey: .appVersion)
        general = container.decodeLossyIfPresent(General.self, forKey: .general) ?? General()
        customApplications = container.decodeLossyIfPresent(
            LossyArray<CustomApplicationProfile>.self, forKey: .customApplications)?.elements ?? []
        remotes = container.decodeLossyIfPresent(LossyArray<Remote>.self, forKey: .remotes)?.elements ?? []
    }
}
