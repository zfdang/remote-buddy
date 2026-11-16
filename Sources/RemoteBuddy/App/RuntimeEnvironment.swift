import Foundation

enum RuntimeEnvironment {
    static let isRunningTests = detectsTests()

    static func detectsTests(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        processName: String = ProcessInfo.processInfo.processName
    ) -> Bool {
        processName == "swiftpm-testing-helper" || processName == "xctest" ||
            arguments.contains { $0.contains(".xctest") || $0.contains("swiftpm-testing-helper") } ||
            ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]
                .contains { environment[$0] != nil }
    }

    /// Even an explicit `.standard` must not let a unit test change app preferences.
    static func isolatedDefaultsIfNeeded(_ defaults: UserDefaults) -> UserDefaults {
        isRunningTests && defaults === UserDefaults.standard ? TemporaryDefaults() : defaults
    }

    private final class TemporaryDefaults: UserDefaults {
        private let domain = "RemoteBuddy.tests." + UUID().uuidString

        init() {
            super.init(suiteName: domain)!
        }

        deinit { removePersistentDomain(forName: domain) }
    }
}
