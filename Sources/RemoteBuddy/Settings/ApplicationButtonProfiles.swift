import AppKit
import Foundation

/// Per-application button overrides for a single remote profile, chosen by the frontmost
/// application when a button press is resolved. Only buttons and triggers that differ from
/// the remote's base mapping are stored; unlisted buttons keep the remote's base mapping.
struct ApplicationButtonProfile: Codable, Equatable {
    var name: String?
    /// `RemoteButton.rawValue` -> `ButtonTrigger.rawValue` -> `ConfiguredButtonAction`.
    var buttons: [String: [String: ConfiguredButtonAction]]

    init(
        name: String? = nil,
        buttons: [String: [String: ConfiguredButtonAction]] = [:]
    ) {
        self.name = name
        self.buttons = buttons
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        buttons = try container.decodeIfPresent([String: [String: ConfiguredButtonAction]].self, forKey: .buttons) ?? [:]
    }

    var buttonOverrideCount: Int {
        buttons.values.reduce(0) { $0 + $1.count }
    }

    func action(for button: RemoteButton, trigger: ButtonTrigger) -> ConfiguredButtonAction? {
        buttons[button.rawValue]?[trigger.rawValue]
    }

    mutating func setAction(
        _ action: ConfiguredButtonAction?,
        for button: RemoteButton,
        trigger: ButtonTrigger
    ) {
        var triggers = buttons[button.rawValue] ?? [:]
        triggers[trigger.rawValue] = action
        buttons[button.rawValue] = triggers.isEmpty ? nil : triggers
    }
}

enum ApplicationButtonProfiles {
    static let defaultsKey = "applicationButtonProfiles"

    static func displayName(bundleID: String, profile: ApplicationButtonProfile?) -> String {
        if let name = profile?.name, !name.isEmpty { return name }
        return bundleID
    }

    /// Reads an `.app` bundle's identifier and user-visible display name.
    static func applicationIdentity(at url: URL) -> (bundleID: String, name: String)? {
        guard let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier,
              !bundleID.isEmpty
        else { return nil }
        let rawName = FileManager.default.displayName(atPath: url.path)
        let name = rawName.hasSuffix(".app") ? String(rawName.dropLast(4)) : rawName
        return (bundleID, name.isEmpty ? bundleID : name)
    }

    @MainActor
    static func currentFrontmostBundleIdentifier() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// Currently running desktop apps suitable for quick selection on the mapping page.
    @MainActor
    static func runningApplications(
        excluding excludedBundleIDs: Set<String>
    ) -> [(bundleID: String, name: String)] {
        let selfBundleID = Bundle.main.bundleIdentifier
        var seen: [String: String] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bundleID = app.bundleIdentifier,
                  !bundleID.isEmpty,
                  bundleID != selfBundleID,
                  !excludedBundleIDs.contains(bundleID),
                  seen[bundleID] == nil
            else { continue }
            let rawName = app.localizedName ?? bundleID
            let name = rawName.isEmpty ? bundleID : rawName
            seen[bundleID] = name
        }
        return seen
            .map { (bundleID: $0.key, name: $0.value) }
            .sorted { left, right in
                let order = left.name.localizedStandardCompare(right.name)
                if order != .orderedSame { return order == .orderedAscending }
                return left.bundleID < right.bundleID
            }
    }
}

extension AppSettings {
    /// Per-application overrides owned by `profileID` (or the selected remote when `nil` / matching).
    func applicationButtonProfiles(for profileID: UUID?) -> [String: ApplicationButtonProfile] {
        if let profileID,
           profileID != selectedRemoteProfileID,
           let profile = remoteDeviceProfiles.first(where: { $0.id == profileID }) {
            return profile.mappings.parsedApplicationButtonProfiles
        }
        return applicationButtonProfiles
    }

    /// Returns the frontmost application's override for `button` and `trigger` on `profileID`, if any.
    func applicationButtonOverride(
        for button: RemoteButton,
        trigger: ButtonTrigger,
        profileID: UUID?
    ) -> ConfiguredButtonAction? {
        let profiles = applicationButtonProfiles(for: profileID)
        guard !profiles.isEmpty,
              let bundleID = frontmostApplicationBundleIdentifier(),
              let profile = profiles[bundleID]
        else { return nil }
        return profile.action(for: button, trigger: trigger)
    }

    /// Action displayed/edited for `bundleID` on the selected remote's mapping page.
    func applicationScopedAction(
        bundleID: String,
        button: RemoteButton,
        trigger: ButtonTrigger
    ) -> ConfiguredButtonAction {
        applicationButtonProfiles[bundleID]?.action(for: button, trigger: trigger)
            ?? configuredBaseAction(for: button, trigger: trigger)
    }

    /// Saves an override for `bundleID` on the selected remote; matching the remote's base action removes it.
    func setApplicationScopedAction(
        _ action: ConfiguredButtonAction,
        bundleID: String,
        button: RemoteButton,
        trigger: ButtonTrigger
    ) {
        var profile = applicationButtonProfiles[bundleID] ?? ApplicationButtonProfile()
        let base = configuredBaseAction(for: button, trigger: trigger)
        profile.setAction(action == base ? nil : action, for: button, trigger: trigger)
        applicationButtonProfiles[bundleID] = profile
    }

    /// Explicitly removes any override for `button` and `trigger` from `bundleID` on the selected remote.
    func clearApplicationOverride(
        bundleID: String,
        button: RemoteButton,
        trigger: ButtonTrigger
    ) {
        guard var profile = applicationButtonProfiles[bundleID] else { return }
        profile.setAction(nil, for: button, trigger: trigger)
        applicationButtonProfiles[bundleID] = profile
    }

    func isApplicationOverride(
        bundleID: String,
        button: RemoteButton,
        trigger: ButtonTrigger
    ) -> Bool {
        applicationButtonProfiles[bundleID]?.action(for: button, trigger: trigger) != nil
    }

    func addApplicationButtonProfile(bundleID: String, name: String) {
        if var existing = applicationButtonProfiles[bundleID] {
            if existing.name?.isEmpty ?? true {
                existing.name = name
                applicationButtonProfiles[bundleID] = existing
            }
            return
        }
        applicationButtonProfiles[bundleID] = ApplicationButtonProfile(name: name)
    }

    func removeApplicationButtonProfile(bundleID: String) {
        applicationButtonProfiles.removeValue(forKey: bundleID)
    }

    var sortedApplicationButtonProfiles: [(bundleID: String, profile: ApplicationButtonProfile)] {
        applicationButtonProfiles
            .map { (bundleID: $0.key, profile: $0.value) }
            .sorted { left, right in
                let leftName = ApplicationButtonProfiles.displayName(bundleID: left.bundleID, profile: left.profile)
                let rightName = ApplicationButtonProfiles.displayName(bundleID: right.bundleID, profile: right.profile)
                let order = leftName.localizedStandardCompare(rightName)
                if order != .orderedSame { return order == .orderedAscending }
                return left.bundleID < right.bundleID
            }
    }
}
