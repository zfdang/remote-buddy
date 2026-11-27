import Foundation
import Combine
import Testing
@testable import RemoteBuddy

@Suite("Remote gain and automatic driver setup")
@MainActor
struct RemoteGainAndDriverTests {
    @Test func repeatedSliderValuesDoNotRewriteTheProfileLibrary() throws {
        let defaults = EphemeralUserDefaults()
        let settings = AppSettings(defaults: defaults)
        let profile = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        settings.selectRemoteProfile(profile)
        var profileUpdates = 0
        let subscription = settings.$remoteDeviceProfiles.dropFirst().sink { _ in profileUpdates += 1 }
        defer { subscription.cancel() }
        settings.setGainDB(8, for: profile)
        #expect(profileUpdates == 1)
        for _ in 0..<120 { settings.setGainDB(8, for: profile) }
        settings.gainDB = 8
        #expect(profileUpdates == 1)
        #expect(AppSettings(defaults: defaults).gainDB(for: profile) == 8)
    }

    @Test func gainsPersistIndependentlyAndFollowTheRecordingDevice() throws {
        let defaults = EphemeralUserDefaults()
        let settings = AppSettings(defaults: defaults)
        let firstBluetooth = UUID(), secondBluetooth = UUID()
        let first = settings.registerBluetoothRemote(identifier: firstBluetooth, model: .rc003)
        let second = settings.registerBluetoothRemote(identifier: secondBluetooth, model: .chromecastVoiceRemote)
        settings.selectRemoteProfile(first)
        settings.setGainDB(6, for: first)
        settings.setGainDB(18, for: second)
        #expect(settings.gainDB == 6)
        #expect(settings.gainDB(forBluetoothIdentifier: secondBluetooth) == 18)
        settings.selectRemoteProfile(second)
        #expect(settings.gainDB == 18)
        #expect(settings.gainDB(forBluetoothIdentifier: firstBluetooth) == 6)
        settings.gainDB = 12 // The voice-test slider edits only the selected remote.
        #expect(settings.gainDB(for: first) == 6)
        #expect(settings.gainDB(for: second) == 12)
        for invalid in [Double.nan, .infinity, -1, 25] { settings.setGainDB(invalid, for: first) }
        #expect(settings.gainDB(for: first) == 6)
        let restored = AppSettings(defaults: defaults)
        #expect(restored.gainDB(for: first) == 6)
        #expect(restored.gainDB(for: second) == 12)
        #expect(restored.gainDB == 12)
    }

    @Test func firstRemoteAdoptsThePreparedGainWithoutChangingLaterDeviceDefaults() throws {
        let defaults = EphemeralUserDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.gainDB = 18
        let first = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        settings.selectRemoteProfile(first)
        #expect(settings.gainDB(for: first) == 18)
        let second = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        settings.selectRemoteProfile(second)
        #expect(settings.gainDB == 10)
        #expect(settings.gainDB(for: first) == 18)
    }

    @Test func fixedOutputCannotBeOverriddenByStoredSelection() throws {
        let defaults = EphemeralUserDefaults()
        defaults.set("speaker", forKey: "selectedAudioDeviceUID")
        defaults.set("BlackHole2ch_UID", forKey: "lastKnownAudioDeviceUID")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.selectedAudioDeviceUID == BuddyMicrophoneDevicePolicy.deviceUID)
        #expect(!OnboardingAudioSelectionPolicy.isSupportedDevice(uid: "speaker", name: BuddyMicrophoneDevicePolicy.deviceName))
        #expect(!OnboardingAudioSelectionPolicy.isSupportedDevice(uid: "BlackHole2ch_UID", name: "BlackHole 2ch"))
    }

    @Test func microphoneSetupDistinguishesPreparationFromFailure() {
        #expect(OnboardingView.microphoneSetupState(installed: false, ready: false, preparing: true) == .preparing)
        #expect(OnboardingView.microphoneSetupState(installed: false, ready: false, preparing: false) == .missing)
        #expect(OnboardingView.microphoneSetupState(installed: true, ready: false, preparing: false) == .failed)
        #expect(OnboardingView.microphoneSetupState(installed: true, ready: true, preparing: false) == .ready)
    }

    @Test func driverStepRequiresAConfiguredOutput() {
        var capabilities = OnboardingCapabilities(bluetoothGranted: true, inputMonitoringGranted: true, accessibilityGranted: true, microphoneDriverInstalled: true, audioOutputSelected: true)
        #expect(!OnboardingFlowPolicy.canContinue(from: .permissions, voiceTool: .unselected,
            controlMethod: .physicalRemote, capabilities: capabilities))
        capabilities.audioReady = true
        #expect(OnboardingFlowPolicy.canContinue(from: .permissions, voiceTool: .unselected,
            controlMethod: .physicalRemote, capabilities: capabilities))
    }

    @Test func permissionsCheckIncludesAudioAndFifthStepSelectsTheTrigger() throws {
        let defaults = EphemeralUserDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.setOnboardingStep(.permissions)
        let device = AudioDeviceInfo(id: 1, uid: BuddyMicrophoneDevicePolicy.deviceUID,
            name: BuddyMicrophoneDevicePolicy.deviceName)
        let model = BridgeAppModel(settings: settings, initialAudioDevices: [device])
        let view = OnboardingView(model: model, permissionOverrides: .allGranted)
        #expect(!view.canContinue)
        view.continueFlow()
        #expect(settings.onboardingStep == .permissions)
        model.isAudioOutputReady = true
        #expect(view.canContinue)
        view.continueFlow()
        #expect(settings.onboardingStep == .remoteAvailability)
        settings.setOnboardingStep(.voiceTrigger)
        settings.voiceKeyMode = .suggestedShortcut
        #expect(view.canContinue)
        view.continueFlow()
        #expect(settings.onboardingStep == .voiceTool)
        settings.setOnboardingStep(try #require(settings.onboardingPurpose.previousStep(before: .voiceTool)))
        #expect(settings.onboardingStep == .voiceTrigger)
        #expect(settings.voiceKeyMode == .suggestedShortcut)
        #expect(OnboardingStep.visibleCases[4] == .voiceTrigger)
    }
}
