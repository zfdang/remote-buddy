import Foundation
import Testing
@testable import RemoteBuddy

@Suite("App launch tracking and completed update detection")
@MainActor
struct LaunchTrackingTests {
    @Test func detectsUpdateWhenBuildNumberIncreases() throws {
        let name = "launch-tracking-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)

        // First launch on build 80
        let firstLaunch = settings.recordLaunchAndDetectCompletedUpdate(currentBuild: "80", sparkleHadLaunchedBefore: false)
        #expect(!firstLaunch)

        // Same build launch
        let sameLaunch = settings.recordLaunchAndDetectCompletedUpdate(currentBuild: "80", sparkleHadLaunchedBefore: false)
        #expect(!sameLaunch)

        // Upgrade to build 81
        let upgradeLaunch = settings.recordLaunchAndDetectCompletedUpdate(currentBuild: "81", sparkleHadLaunchedBefore: false)
        #expect(upgradeLaunch)

        // Downgrade to build 79
        let downgradeLaunch = settings.recordLaunchAndDetectCompletedUpdate(currentBuild: "79", sparkleHadLaunchedBefore: false)
        #expect(!downgradeLaunch)
    }

    @Test func detectsCompletedUpdateOnFirstRunIfSparkleHadLaunchedBefore() throws {
        let name = "sparkle-migration-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)

        let completed = settings.recordLaunchAndDetectCompletedUpdate(currentBuild: "80", sparkleHadLaunchedBefore: true)
        #expect(completed)
    }

    @Test func deviceMappingsRemainIndependentOfUnboundDefaults() throws {
        let name = "device-mapping-priority-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.setBaseBinding(.init(action: .playPause, shortcut: nil),
            for: .volumeUp, trigger: .singleClick, profileID: nil)
        let first = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        let second = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        settings.selectRemoteProfile(first)
        settings.setBaseBinding(.init(action: .showDesktop, shortcut: nil),
            for: .volumeUp, trigger: .singleClick, profileID: first)
        let restored = AppSettings(defaults: defaults)
        #expect(restored.action(for: .volumeUp, profileID: first) == .showDesktop)
        #expect(restored.action(for: .volumeUp, profileID: second) == .volumeUp)
    }

    @Test func ignoresNonNumericBuildWithoutOverwritingLastLaunchedBuild() throws {
        let name = "launch-nonnumeric-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)

        #expect(!settings.recordLaunchAndDetectCompletedUpdate(currentBuild: "80", sparkleHadLaunchedBefore: false))
        #expect(!settings.recordLaunchAndDetectCompletedUpdate(currentBuild: "81-beta", sparkleHadLaunchedBefore: true))
        #expect(!settings.recordLaunchAndDetectCompletedUpdate(currentBuild: "", sparkleHadLaunchedBefore: false))
        #expect(settings.recordLaunchAndDetectCompletedUpdate(currentBuild: "81", sparkleHadLaunchedBefore: false))
    }
}
