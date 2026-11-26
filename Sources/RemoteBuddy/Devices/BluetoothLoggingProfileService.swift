import AppKit
import Foundation

enum BluetoothLoggingProfileStatus: String, Equatable, Sendable {
    case unknown
    case installed
    case notInstalled = "not_installed"
}

enum BluetoothLoggingProfileService {
    static let profileResourceName = "RemoteBuddy-G9N9N-BluetoothLogging"
    static let profileSubdirectory = "Profiles"
    static let profileFileName = "\(profileResourceName).mobileconfig"

    static func bundledProfileURL(
        in bundle: Bundle = RemoteBuddyResourceBundle.mainOrDevelopment
    ) -> URL? {
        bundle.url(
            forResource: profileResourceName,
            withExtension: "mobileconfig",
            subdirectory: profileSubdirectory
        ) ?? bundle.url(forResource: profileResourceName, withExtension: "mobileconfig")
    }

    /// Parses `profiles list -output stdout-xml` output to check whether any
    /// installed configuration profile enables private data for `com.apple.bluetooth`.
    static func isBluetoothPrivateLoggingInstalled(profilesXMLData: Data) -> Bool {
        guard !profilesXMLData.isEmpty,
              let plist = try? PropertyListSerialization.propertyList(
                  from: profilesXMLData,
                  options: [],
                  format: nil
              ) as? [String: Any]
        else {
            return false
        }
        for value in plist.values {
            guard let profiles = value as? [[String: Any]] else { continue }
            for profile in profiles {
                guard let items = profile["ProfileItems"] as? [[String: Any]] else { continue }
                for item in items {
                    guard (item["PayloadType"] as? String) == "com.apple.system.logging",
                          let content = item["PayloadContent"] as? [String: Any]
                    else { continue }
                    if let bluetooth = (content["Subsystems"] as? [String: Any])?["com.apple.bluetooth"] as? [String: Any] {
                        if enablesPrivateDebugLogging(bluetooth["DEFAULT-OPTIONS"] as? [String: Any]) ||
                            enablesPrivateDebugLogging(bluetooth["BTLEServer"] as? [String: Any]) {
                            return true
                        }
                    }
                }
            }
        }
        return false
    }

    private static func enablesPrivateDebugLogging(_ options: [String: Any]?) -> Bool {
        guard let options,
              (options["Enable-Private-Data"] as? Bool) == true,
              let level = options["Level"] as? [String: Any],
              let enableLevel = level["Enable"] as? String
        else {
            return false
        }
        return enableLevel.caseInsensitiveCompare("Debug") == .orderedSame
    }

    static func status(fromProfilesXMLData profilesXMLData: Data) -> BluetoothLoggingProfileStatus {
        guard !profilesXMLData.isEmpty,
              let plist = try? PropertyListSerialization.propertyList(
                  from: profilesXMLData,
                  options: [],
                  format: nil
              ) as? [String: Any]
        else {
            return .unknown
        }
        if isBluetoothPrivateLoggingInstalled(profilesXMLData: profilesXMLData) {
            return .installed
        }
        // Non-root `profiles list` omits system-scoped (`_computerlevel`) profiles.
        // Only treat an absence as `.notInstalled` when the computer-level list itself
        // was included in the query output; otherwise absence proves `.unknown`.
        return plist.keys.contains("_computerlevel") ? .notInstalled : .unknown
    }

    static func detectInstalledStatus() async -> BluetoothLoggingProfileStatus {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/profiles")
            process.arguments = ["list", "-output", "stdout-xml"]
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return .unknown
            }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return .unknown }
            return status(fromProfilesXMLData: data)
        }.value
    }

    @MainActor
    @discardableResult
    static func openBundledProfileForInstallation(
        in bundle: Bundle = RemoteBuddyResourceBundle.mainOrDevelopment,
        workspaceOpen: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) -> Bool {
        guard let sourceURL = bundledProfileURL(in: bundle) else {
            AppLogger.shared.write("BTLE_LOG_PROFILE open_failed reason=resource_missing")
            return false
        }
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(profileFileName)
        do {
            let data = try Data(contentsOf: sourceURL)
            try data.write(to: destinationURL, options: .atomic)
        } catch {
            AppLogger.shared.write(
                "BTLE_LOG_PROFILE open_failed reason=copy_failed error=\(error.localizedDescription)"
            )
            return false
        }
        let opened = workspaceOpen(destinationURL)
        AppLogger.shared.write("BTLE_LOG_PROFILE open result=\(opened)")
        return opened
    }

    @MainActor
    static func openDeviceManagementSettings(
        workspaceOpen: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        let candidates = [
            "x-apple.systempreferences:com.apple.Profiles-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.profiles",
        ].compactMap(URL.init(string:))
        for url in candidates where workspaceOpen(url) {
            return
        }
    }
}
