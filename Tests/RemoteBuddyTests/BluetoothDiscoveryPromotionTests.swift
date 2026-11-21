import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Bluetooth discovery promotion")
@MainActor
struct BluetoothDiscoveryPromotionTests {
    @Test func dailyRuntimeStopsDiscoveryWithoutStoppingRegisteredBridges() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.onboardingCompletedVersion = AppSettings.currentOnboardingVersion
        let model = BridgeAppModel(settings: settings)
        let identifier = UUID()
        _ = settings.registerBluetoothRemote(identifier: identifier, model: .rc003)
        let registered = BluetoothRemoteBridge(settings: settings, delegate: model, targetIdentifier: identifier)
        let discovery = BluetoothRemoteBridge(settings: settings, delegate: model)
        model.connections.bridges[identifier] = registered
        model.connections.discoveryBridge = discovery
        model.connections.states[ObjectIdentifier(discovery)] = .scanning
        model.started = true
        defer { model.started = false }
        #expect(!model.shouldDiscoverNewBluetoothRemotes)
        model.synchronizeBluetoothDiscovery()
        #expect(model.connections.discoveryBridge == nil)
        #expect(model.connections.states[ObjectIdentifier(discovery)] == nil)
        #expect(model.connections.bridges[identifier] === registered)
        model.refreshRemoteDiscovery()
        #expect(model.connections.discoveryBridge == nil)
    }

    @Test func discoveryRemainsAvailableForFirstDeviceSetupAndOnboardingSteps() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.onboardingCompletedVersion = AppSettings.currentOnboardingVersion
        let model = BridgeAppModel(settings: settings)
        #expect(model.shouldDiscoverNewBluetoothRemotes)
        _ = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        #expect(!model.shouldDiscoverNewBluetoothRemotes)
        settings.onboardingCompletedVersion = 0
        for step: OnboardingStep in [.remoteAvailability, .remote, .controls] {
            settings.onboardingStep = step
            #expect(model.shouldDiscoverNewBluetoothRemotes)
        }
        settings.onboardingStep = .voiceTest
        #expect(!model.shouldDiscoverNewBluetoothRemotes)
    }

    @Test(arguments: ["step", "completion", "profile"])
    func settingsPublisherStopsDiscoveryAfterValuesAreCommitted(change: String) async throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.onboardingCompletedVersion = change == "profile" ? AppSettings.currentOnboardingVersion : 0
        settings.onboardingStep = .controls
        if change != "profile" { _ = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003) }
        let model = BridgeAppModel(settings: settings)
        let discovery = BluetoothRemoteBridge(settings: settings, delegate: model)
        model.connections.discoveryBridge = discovery
        model.connections.states[ObjectIdentifier(discovery)] = .scanning
        model.started = true
        defer { model.started = false }
        #expect(model.shouldDiscoverNewBluetoothRemotes)
        switch change {
        case "step": settings.onboardingStep = .voiceTest
        case "completion": settings.onboardingCompletedVersion = AppSettings.currentOnboardingVersion
        default: _ = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        }
        #expect(!model.shouldDiscoverNewBluetoothRemotes)
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.connections.discoveryBridge == nil)
        #expect(model.connections.states[ObjectIdentifier(discovery)] == nil)
    }

    @Test func registrationPinsTheKnownBridgeIdentity() throws {
        let suite = "bluetooth-registration-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let model = BridgeAppModel(settings: settings)
        let identifier = UUID()
        let bridge = BluetoothRemoteBridge(settings: settings, delegate: model,
            excludedIdentifiers: { Set(model.connections.bridges.keys) })
        // Exercise registration's known-bridge identity fallback without a CBPeripheral.
        model.connections.bridges[identifier] = bridge
        model.connections.discoveryBridge = bridge
        #expect(bridge.targetIdentifier == nil)
        #expect(!bridge.acceptsCandidateIdentifier(identifier))
        let profileID = try #require(model.registerBluetoothBridgeIfNeeded(bridge))
        #expect(settings.profileID(forBluetoothIdentifier: identifier) == profileID)
        #expect(bridge.targetIdentifier == identifier)
        #expect(bridge.deviceIdentifier == identifier)
        #expect(bridge.acceptsCandidateIdentifier(identifier))
        #expect(model.connections.discoveryBridge == nil)
    }

    @Test func promotedDiscoveryBridgeRetainsItsDeviceAndCanReconnect() throws {
        let suite = "bluetooth-promotion-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let model = BridgeAppModel(settings: settings)
        let identifier = UUID()
        let other = UUID()
        let bridge = BluetoothRemoteBridge(settings: settings, delegate: model,
            excludedIdentifiers: { Set(model.connections.bridges.keys) })
        model.connections.discoveryBridge = bridge
        #expect(bridge.deviceIdentifier == nil)
        #expect(bridge.acceptsCandidateIdentifier(identifier))

        // Simulate the verified handshake identity, without creating a Bluetooth manager.
        #expect(bridge.bindVerifiedIdentity(identifier))
        let profileID = try #require(model.registerBluetoothBridgeIfNeeded(bridge))
        #expect(model.connections.discoveryBridge == nil)
        #expect(model.connections.bridges[identifier] === bridge)
        #expect(settings.profileID(forBluetoothIdentifier: identifier) == profileID)

        // No peripheral is retained here, just as after sleep/disconnect teardown.
        #expect(bridge.deviceIdentifier == identifier)
        #expect(bridge.targetIdentifier == identifier)
        #expect(bridge.acceptsCandidateIdentifier(identifier))
        #expect(!bridge.acceptsCandidateIdentifier(other))
        #expect(VoiceRemoteAdmission.decide(identifier: identifier,
            targetIdentifier: bridge.targetIdentifier, advertisesVoiceService: false,
            name: "Renamed remote", advertisedName: nil) == .adoptSavedIdentity)
        #expect(!bridge.bindVerifiedIdentity(other))
        #expect(bridge.deviceIdentifier == identifier)
        #expect(model.registerBluetoothBridgeIfNeeded(bridge) == profileID)
    }

    @Test func discoveryStillExcludesRegisteredDevicesAndBoundBridgeAllowsScanFallback() throws {
        let suite = "bluetooth-exclusions-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let model = BridgeAppModel(settings: settings)
        let identifier = UUID()
        let other = UUID()
        let discovery = BluetoothRemoteBridge(settings: settings, delegate: model,
            excludedIdentifiers: { [identifier] })
        #expect(!discovery.acceptsCandidateIdentifier(identifier))
        #expect(discovery.acceptsCandidateIdentifier(other))

        let registered = BluetoothRemoteBridge(settings: settings, delegate: model,
            targetIdentifier: identifier, excludedIdentifiers: { [identifier, other] })
        #expect(registered.acceptsCandidateIdentifier(identifier))
        #expect(!registered.acceptsCandidateIdentifier(other))
        // Saved identity does not bypass the foreign-product rejection.
        #expect(!VoiceRemoteAdmission.decide(identifier: identifier,
            targetIdentifier: registered.targetIdentifier, advertisesVoiceService: true,
            name: "Chromecast Remote", advertisedName: nil).isAdopted)
    }
}
