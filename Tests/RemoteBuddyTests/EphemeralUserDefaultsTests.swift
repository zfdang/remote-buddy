import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Ephemeral user defaults")
struct EphemeralUserDefaultsTests {
    @Test func storesAllSupportedTypesAndBridgesNumbersInMemory() throws {
        let defaults = EphemeralUserDefaults()
        let probeKey = "ephemeral-probe-\(UUID().uuidString)"
        let url = URL(fileURLWithPath: "/Applications/Remote Buddy.app")
        let payload = Data([0x01, 0x02, 0x03])

        defaults.set(true, forKey: "flag")
        defaults.set(42, forKey: "count")
        defaults.set(Float(1.5), forKey: "ratio")
        defaults.set(-6.25, forKey: "gain")
        defaults.set("hello", forKey: probeKey)
        defaults.set(payload, forKey: "bytes")
        defaults.set(["a", "b"], forKey: "list")
        defaults.set(["k": "v"], forKey: "dict")
        defaults.set(url, forKey: "appURL")

        #expect(defaults.bool(forKey: "flag") == true)
        #expect((defaults.object(forKey: "count") as? NSNumber)?.intValue == 42)
        #expect(defaults.integer(forKey: "count") == 42)
        #expect(defaults.string(forKey: "count") == "42")
        #expect(defaults.string(forKey: "flag") == nil)
        #expect(defaults.float(forKey: "ratio") == 1.5)
        #expect(defaults.double(forKey: "gain") == -6.25)
        #expect(defaults.string(forKey: probeKey) == "hello")
        #expect(defaults.data(forKey: "bytes") == payload)
        #expect(defaults.stringArray(forKey: "list") == ["a", "b"])
        #expect((defaults.dictionary(forKey: "dict") as? [String: String]) == ["k": "v"])
        #expect(defaults.url(forKey: "appURL") == url)

        defaults.register(defaults: ["fallback": "default-value", probeKey: "ignored-default"])
        #expect(defaults.string(forKey: "fallback") == "default-value")
        #expect(defaults.string(forKey: probeKey) == "hello")
        #expect(defaults.dictionaryRepresentation()["fallback"] as? String == "default-value")

        #expect(defaults !== UserDefaults.standard)
        #expect(UserDefaults.standard.object(forKey: probeKey) == nil)

        defaults.removeObject(forKey: probeKey)
        #expect(defaults.string(forKey: probeKey) == "ignored-default")
        defaults.removeObject(forKey: "bytes")
        #expect(defaults.object(forKey: "bytes") == nil)

        #expect((defaults.persistentDomain(forName: "any")?["count"] as? NSNumber)?.intValue == 42)
        defaults.setPersistentDomain(["replaced": 7], forName: "any")
        #expect(defaults.integer(forKey: "replaced") == 7)
        #expect(defaults.object(forKey: "count") == nil)

        defaults.removePersistentDomain(forName: "any")
        #expect(defaults.persistentDomain(forName: "any") == nil)
    }

    @Test func doesNotCreatePreferenceFilesOnDisk() throws {
        let preferencesDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences", isDirectory: true)
        let probeSuite = "ephemeral-disk-guard-\(UUID().uuidString)"
        let probePlist = preferencesDirectory.appendingPathComponent("\(probeSuite).plist")

        let defaults = try #require(EphemeralUserDefaults(suiteName: probeSuite))
        defaults.set("value", forKey: "key")
        defaults.set(123, forKey: "number")
        _ = defaults.synchronize()
        defaults.removePersistentDomain(forName: probeSuite)

        #expect(!FileManager.default.fileExists(atPath: probePlist.path))
    }

    @Test func repositoryAvoidsDiskBackedUserDefaultsSuites() throws {
        let root = try repositoryRoot()
        let allowed = [
            "Sources/RemoteBuddy/Onboarding/OnboardingInputSourceSwitcher.swift",
            "Sources/RemoteBuddy/Settings/EphemeralUserDefaults.swift",
            "Tests/RemoteBuddyTests/EphemeralUserDefaultsTests.swift",
        ]
        var unexpected: [String] = []

        for folder in ["Sources", "Tests"] {
            let folderURL = root.appendingPathComponent(folder, isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(
                at: folderURL,
                includingPropertiesForKeys: nil
            ) else { continue }
            for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
                let relativePath = fileURL.path.replacingOccurrences(of: root.path + "/", with: "")
                guard !allowed.contains(relativePath) else { continue }
                let content = try String(contentsOf: fileURL, encoding: .utf8)
                if content.contains("UserDefaults(suiteName:") {
                    unexpected.append(relativePath)
                }
            }
        }

        #expect(unexpected.isEmpty, "Unexpected UserDefaults(suiteName:) usages: \(unexpected)")
    }

    private func repositoryRoot(filePath: String = #filePath) throws -> URL {
        var current = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        while current.path != "/" {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent("Package.swift").path) {
                return current
            }
            current.deleteLastPathComponent()
        }
        throw NSError(domain: "EphemeralUserDefaultsTests", code: 1)
    }
}
