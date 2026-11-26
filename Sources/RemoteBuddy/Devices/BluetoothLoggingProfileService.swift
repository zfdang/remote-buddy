import AppKit
import Foundation
import os

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

    private static func arrayItems(in dict: [String: Any]) -> [[String: Any]]? {
        guard let rawItems = dict["_items"] else {
            return []
        }
        return rawItems as? [[String: Any]]
    }

    private static func parseSystemProfilerPayloadData(_ rawValue: Any?) -> [String: Any]? {
        if let dict = rawValue as? [String: Any] {
            return dict
        }
        if let text = rawValue as? String,
           let data = text.data(using: .utf8),
           let parsed = try? PropertyListSerialization.propertyList(
               from: data,
               options: [],
               format: nil
           ) as? [String: Any] {
            return parsed
        }
        return nil
    }

    private static func inspectBluetoothLoggingSupport(inPayloadContent content: [String: Any]) -> Bool? {
        guard let rawSubsystems = content["Subsystems"] else {
            return false
        }
        guard let subsystems = rawSubsystems as? [String: Any] else {
            return nil
        }
        guard let rawBluetooth = subsystems["com.apple.bluetooth"] else {
            return false
        }
        guard let bluetooth = rawBluetooth as? [String: Any] else {
            return nil
        }
        for key in ["DEFAULT-OPTIONS", "BTLEServer"] {
            if let entry = bluetooth[key], !(entry is [String: Any]) {
                return nil
            }
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
              ) as? [[String: Any]]
        else {
            return .unknown
        }
        let entries = root.filter { ($0["_dataType"] as? String) == "SPConfigurationProfileDataType" }
        guard !entries.isEmpty else {
            return .unknown
        }
        var sawIndeterminateLoggingData = false
        for entry in entries {
            guard let scopes = arrayItems(in: entry) else {
                sawIndeterminateLoggingData = true
                continue
            }
            for scope in scopes {
                guard let profiles = arrayItems(in: scope) else {
                    sawIndeterminateLoggingData = true
                    continue
                }
                for profile in profiles {
                    guard let payloads = arrayItems(in: profile) else {
                        sawIndeterminateLoggingData = true
                        continue
                    }
                    for payload in payloads {
                        guard let rawName = payload["_name"] as? String else {
                            if payload["_name"] != nil {
                                sawIndeterminateLoggingData = true
                            }
                            continue
                        }
                        guard rawName == "com.apple.system.logging" else { continue }
                        guard let content = parseSystemProfilerPayloadData(payload["spconfigprofile_payload_data"]),
                              let supportsBluetoothLogging = inspectBluetoothLoggingSupport(inPayloadContent: content)
                        else {
                            sawIndeterminateLoggingData = true
                            continue
                        }
                        if supportsBluetoothLogging {
                            return .installed
                        }
                    }
                }
            }
        }
        return sawIndeterminateLoggingData ? .unknown : .notInstalled
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

    private static func runProcess(
        _ executablePath: String,
        arguments: [String],
        activeProcess: OSAllocatedUnfairLock<Process?>? = nil
    ) -> Data? {
        guard !Task.isCancelled else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        activeProcess?.withLock { $0 = process }
        defer { activeProcess?.withLock { if $0 === process { $0 = nil } } }
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard !Task.isCancelled, process.terminationStatus == 0 else { return nil }
        return data
    }

    static func resolveInstalledStatus(
        systemProfilerData: () -> Data?,
        profilesData: () -> Data?
    ) -> BluetoothLoggingProfileStatus {
        // `system_profiler SPConfigurationProfileDataType -xml` reports both device-level
        // and user-level configuration profiles without requiring root privileges.
        if let profilerData = systemProfilerData() {
            let profilerStatus = status(fromSystemProfilerXMLData: profilerData)
            if profilerStatus != .unknown {
                return profilerStatus
            }
        }
        if let profilesData = profilesData() {
            return status(fromProfilesXMLData: profilesData)
        }
        return .unknown
    }

    static func detectInstalledStatus() async -> BluetoothLoggingProfileStatus {
        let activeProcess = OSAllocatedUnfairLock<Process?>(initialState: nil)
        return await withTaskCancellationHandler {
            await Task.detached(priority: .utility) {
                resolveInstalledStatus(
                    systemProfilerData: {
                        runProcess(
                            "/usr/sbin/system_profiler",
                            arguments: ["SPConfigurationProfileDataType", "-xml"],
                            activeProcess: activeProcess
                        )
                    },
                    profilesData: {
                        runProcess(
                            "/usr/bin/profiles",
                            arguments: ["list", "-output", "stdout-xml"],
                            activeProcess: activeProcess
                        )
                    }
                )
            }.value
        } onCancel: {
            activeProcess.withLock { $0 }?.terminate()
        }
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
