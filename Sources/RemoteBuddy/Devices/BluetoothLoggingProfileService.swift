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

    private static func isTruthyFlag(_ value: Any?) -> Bool {
        if let flag = value as? Bool {
            return flag
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let text = value as? String {
            switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes":
                return true
            default:
                return false
            }
        }
        return false
    }

    private static func enablesPrivateDebugLogging(_ options: [String: Any]?) -> Bool {
        guard let options,
              isTruthyFlag(options["Enable-Private-Data"]),
              let level = options["Level"] as? [String: Any],
              let enableLevel = level["Enable"] as? String
        else {
            return false
        }
        return enableLevel.caseInsensitiveCompare("Debug") == .orderedSame
    }

    private static func enablesBluetoothPrivateDebugLogging(inPayloadContent content: [String: Any]) -> Bool {
        guard let bluetooth = (content["Subsystems"] as? [String: Any])?["com.apple.bluetooth"] as? [String: Any] else {
            return false
        }
        return enablesPrivateDebugLogging(bluetooth["DEFAULT-OPTIONS"] as? [String: Any]) ||
            enablesPrivateDebugLogging(bluetooth["BTLEServer"] as? [String: Any])
    }

    static func status(fromSystemProfilerXMLData xmlData: Data) -> BluetoothLoggingProfileStatus {
        guard !xmlData.isEmpty,
              let root = try? PropertyListSerialization.propertyList(
                  from: xmlData,
                  options: [],
                  format: nil
              ) as? [[String: Any]],
              root.contains(where: { ($0["_dataType"] as? String) == "SPConfigurationProfileDataType" })
        else {
            return .unknown
        }
        for entry in root where (entry["_dataType"] as? String) == "SPConfigurationProfileDataType" {
            let scopes = entry["_items"] as? [[String: Any]] ?? []
            for scope in scopes {
                let profiles = scope["_items"] as? [[String: Any]] ?? []
                for profile in profiles {
                    let payloads = profile["_items"] as? [[String: Any]] ?? []
                    for payload in payloads {
                        guard (payload["_name"] as? String) == "com.apple.system.logging" else { continue }
                        let content: [String: Any]?
                        if let dict = payload["spconfigprofile_payload_data"] as? [String: Any] {
                            content = dict
                        } else if let text = payload["spconfigprofile_payload_data"] as? String,
                                  let data = text.data(using: .utf8),
                                  let parsed = try? PropertyListSerialization.propertyList(
                                      from: data,
                                      options: [],
                                      format: nil
                                  ) as? [String: Any] {
                            content = parsed
                        } else {
                            content = nil
                        }
                        if let content, enablesBluetoothPrivateDebugLogging(inPayloadContent: content) {
                            return .installed
                        }
                    }
                }
            }
        }
        return .notInstalled
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

    private static func runProcess(_ executablePath: String, arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return data
    }

    static func detectInstalledStatus() async -> BluetoothLoggingProfileStatus {
        await Task.detached(priority: .utility) {
            // `system_profiler SPConfigurationProfileDataType -xml` reports both device-level
            // and user-level configuration profiles without requiring root privileges.
            if let profilerData = runProcess(
                "/usr/sbin/system_profiler",
                arguments: ["SPConfigurationProfileDataType", "-xml"]
            ) {
                let profilerStatus = status(fromSystemProfilerXMLData: profilerData)
                if profilerStatus != .unknown {
                    return profilerStatus
                }
            }
            if let profilesData = runProcess(
                "/usr/bin/profiles",
                arguments: ["list", "-output", "stdout-xml"]
            ) {
                return status(fromProfilesXMLData: profilesData)
            }
            return .unknown
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
