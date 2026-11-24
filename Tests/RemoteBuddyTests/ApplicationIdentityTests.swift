import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Application identity")
struct ApplicationIdentityTests {
    @Test func fallbackMatchesTheShippedBundleIdentifier() throws {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
            let parent = root.deletingLastPathComponent()
            try #require(parent != root)
            root = parent
        }
        let resources = root.appendingPathComponent("Resources")
        let data = try Data(contentsOf: resources.appendingPathComponent("Info.plist"))
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["CFBundleIdentifier"] as? String == ApplicationInstanceGuard.fallbackBundleIdentifier)
    }

    @Test func presetApplicationRemoteMicBundleIdentifierMatchesInfoIdentifier() throws {
        #expect(PresetApplication.remoteMic.bundleIdentifier == ApplicationInstanceGuard.fallbackBundleIdentifier)
    }

    @Test func shippedInfoPlistDisablesSparkleAutomaticChecks() throws {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
            let parent = root.deletingLastPathComponent()
            try #require(parent != root)
            root = parent
        }
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["SUEnableAutomaticChecks"] as? Bool == false)
    }
}
