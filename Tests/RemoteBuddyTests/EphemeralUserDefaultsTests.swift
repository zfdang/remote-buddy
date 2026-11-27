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
        defaults.set(false, forKey: "disabledFlag")
        defaults.set(42, forKey: "count")
        defaults.set(Float(1.5), forKey: "ratio")
        defaults.set(-6.25, forKey: "gain")
        defaults.set("hello", forKey: probeKey)
        defaults.set(payload, forKey: "bytes")
        defaults.set(["a", "b"], forKey: "list")
        defaults.set(["k": "v"], forKey: "dict")
        defaults.set(url, forKey: "appURL")

        #expect(defaults.bool(forKey: "flag") == true)
        #expect(defaults.bool(forKey: "disabledFlag") == false)
        #expect((defaults.object(forKey: "count") as? NSNumber)?.intValue == 42)
        #expect(defaults.integer(forKey: "count") == 42)
        #expect(defaults.string(forKey: "count") == "42")
        #expect(defaults.string(forKey: "flag") == "1")
        #expect(defaults.string(forKey: "disabledFlag") == "0")
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

    @Test func matchesFoundationStringFormattingForBooleans() {
        let trueKey = "ephemeral-bool-true-\(UUID().uuidString)"
        let falseKey = "ephemeral-bool-false-\(UUID().uuidString)"
        let foundation = UserDefaults()
        foundation.register(defaults: [trueKey: true, falseKey: false])

        let ephemeral = EphemeralUserDefaults()
        ephemeral.set(true, forKey: "typedTrue")
        ephemeral.set(false, forKey: "typedFalse")
        ephemeral.set(true as Any, forKey: "anyTrue")
        ephemeral.set(false as Any, forKey: "anyFalse")

        #expect(foundation.string(forKey: trueKey) == "1")
        #expect(foundation.string(forKey: falseKey) == "0")
        #expect(ephemeral.string(forKey: "typedTrue") == foundation.string(forKey: trueKey))
        #expect(ephemeral.string(forKey: "typedFalse") == foundation.string(forKey: falseKey))
        #expect(ephemeral.string(forKey: "anyTrue") == foundation.string(forKey: trueKey))
        #expect(ephemeral.string(forKey: "anyFalse") == foundation.string(forKey: falseKey))
    }

    @Test func doesNotLeakWritesIntoStandardDomainOrAppPreferences() throws {
        let probePrefix = "ephemeral-isolation-\(UUID().uuidString)"
        let probeSuite = "ephemeral-suite-\(UUID().uuidString)"

        let keyAnyString = "\(probePrefix)-any-string"
        let keyAnyData = "\(probePrefix)-any-data"
        let keyAnyArray = "\(probePrefix)-any-array"
        let keyAnyDict = "\(probePrefix)-any-dict"
        let keyAnyNumber = "\(probePrefix)-any-number"
        let keyInt = "\(probePrefix)-int"
        let keyFloat = "\(probePrefix)-float"
        let keyDouble = "\(probePrefix)-double"
        let keyBoolTrue = "\(probePrefix)-bool-true"
        let keyBoolFalse = "\(probePrefix)-bool-false"
        let keyURL = "\(probePrefix)-url"
        let keyRegistered = "\(probePrefix)-registered"
        let keyDomain = "\(probePrefix)-domain"
        let keyKVC = "\(probePrefix)-kvc"
        let keyKVCBatch = "\(probePrefix)-kvc-batch"
        let allKeys = [
            keyAnyString, keyAnyData, keyAnyArray, keyAnyDict, keyAnyNumber,
            keyInt, keyFloat, keyDouble, keyBoolTrue, keyBoolFalse, keyURL,
            keyRegistered, keyDomain, keyKVC, keyKVCBatch,
        ]

        let defaultInstance = EphemeralUserDefaults()
        let suitedInstance = try #require(EphemeralUserDefaults(suiteName: probeSuite))
        let domainInstance = try #require(EphemeralUserDefaults(suiteName: probeSuite))

        for defaults in [defaultInstance, suitedInstance] {
            defaults.set("value" as Any, forKey: keyAnyString)
            defaults.set(Data([0xAA, 0xBB]) as Any, forKey: keyAnyData)
            defaults.set(["one", "two"] as Any, forKey: keyAnyArray)
            defaults.set(["nested": "item"] as Any, forKey: keyAnyDict)
            defaults.set(NSNumber(value: 99) as Any, forKey: keyAnyNumber)
            defaults.set(123, forKey: keyInt)
            defaults.set(Float(2.5), forKey: keyFloat)
            defaults.set(3.75, forKey: keyDouble)
            defaults.set(true, forKey: keyBoolTrue)
            defaults.set(false, forKey: keyBoolFalse)
            defaults.set(URL(fileURLWithPath: "/Applications/Remote Buddy.app"), forKey: keyURL)
            defaults.register(defaults: [keyRegistered: "registered"])
            defaults.setValue("kvc-value", forKey: keyKVC)
            defaults.setValuesForKeys([keyKVCBatch: 321])
            _ = defaults.synchronize()
        }
        domainInstance.setPersistentDomain([keyDomain: "from-domain"], forName: probeSuite)
        _ = domainInstance.synchronize()

        // Verify isolation against real standard/application preferences BEFORE cleanup.
        _ = UserDefaults.standard.synchronize()
        let standardRepresentation = UserDefaults.standard.dictionaryRepresentation()
        let appDomain = Bundle.main.bundleIdentifier.flatMap {
            UserDefaults.standard.persistentDomain(forName: $0)
        }
        for key in allKeys {
            #expect(UserDefaults.standard.object(forKey: key) == nil)
            #expect(standardRepresentation[key] == nil)
            #expect(CFPreferencesCopyAppValue(key as CFString, kCFPreferencesCurrentApplication) == nil)
            #expect(appDomain?[key] == nil)
        }

        #expect(suitedInstance.integer(forKey: keyInt) == 123)
        #expect(suitedInstance.bool(forKey: keyBoolTrue) == true)
        #expect(suitedInstance.bool(forKey: keyBoolFalse) == false)
        #expect(suitedInstance.url(forKey: keyURL) == URL(fileURLWithPath: "/Applications/Remote Buddy.app"))
        #expect(suitedInstance.string(forKey: keyKVC) == "kvc-value")
        #expect(suitedInstance.integer(forKey: keyKVCBatch) == 321)
        #expect(domainInstance.string(forKey: keyDomain) == "from-domain")

        defaultInstance.removePersistentDomain(forName: probeSuite)
        suitedInstance.removePersistentDomain(forName: probeSuite)
        domainInstance.removePersistentDomain(forName: probeSuite)
        #expect(suitedInstance.persistentDomain(forName: probeSuite) == nil)
        #expect(domainInstance.persistentDomain(forName: probeSuite) == nil)
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
