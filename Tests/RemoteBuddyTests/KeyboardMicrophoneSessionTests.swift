import Testing
@testable import RemoteBuddy

@Suite("Keyboard microphone source ownership")
struct KeyboardMicrophoneSessionTests {
    @MainActor
    @Test func selectionIsOptInAndPersistsByDeviceUID() {
        let defaults = EphemeralUserDefaults()
        let settings = AppSettings(defaults: defaults)
        #expect(settings.keyboardMicrophoneUID.isEmpty)
        #expect(settings.keyboardMicrophoneToggleKey == .rightCommand)
        settings.keyboardMicrophoneUID = "test.microphone.uid"
        settings.keyboardMicrophoneToggleKey = .rightOption

        let restored = AppSettings(defaults: defaults)
        #expect(restored.keyboardMicrophoneUID == "test.microphone.uid")
        #expect(restored.keyboardMicrophoneToggleKey == .rightOption)
    }

    @Test func startsOnlyAfterSeeingAnIdleReader() {
        var session = KeyboardMicrophoneSession()
        let alreadyReading = session.update(readerActive: true, remoteActive: false)
        #expect(alreadyReading == .none)
        let idle = session.update(readerActive: false, remoteActive: false)
        #expect(idle == .none)
        let started = session.update(readerActive: true, remoteActive: false)
        #expect(started == .start)
        #expect(session.ownsAudio)
        let repeated = session.update(readerActive: true, remoteActive: false)
        #expect(repeated == .none)
        let stopped = session.update(readerActive: false, remoteActive: false)
        #expect(stopped == .stop)
        #expect(!session.ownsAudio)
    }

    @Test func remoteStopDoesNotSwitchToTheKeyboardMicWhileTheReaderDrains() {
        var session = KeyboardMicrophoneSession()
        _ = session.update(readerActive: false, remoteActive: false)
        let remote = session.update(readerActive: true, remoteActive: true)
        #expect(remote == .none)
        let draining = session.update(readerActive: true, remoteActive: false)
        #expect(draining == .none)
        #expect(!session.ownsAudio)
        _ = session.update(readerActive: false, remoteActive: false)
        let nextSession = session.update(readerActive: true, remoteActive: false)
        #expect(nextSession == .start)
    }

    @Test func stopSuppressesFurtherAudioUntilNextReaderActivation() {
        var session = KeyboardMicrophoneSession()
        _ = session.update(readerActive: false, remoteActive: false)
        _ = session.update(readerActive: true, remoteActive: false)
        let stopped = session.suppress()
        #expect(stopped == .stop)
        let pending = session.update(readerActive: true, remoteActive: false)
        #expect(pending == .none)
        _ = session.update(readerActive: false, remoteActive: false)
        let nextSession = session.update(readerActive: true, remoteActive: false)
        #expect(nextSession == .start)
    }

    @Test func remoteOwnershipStopsKeyboardDelivery() {
        var session = KeyboardMicrophoneSession()
        _ = session.update(readerActive: false, remoteActive: false)
        _ = session.update(readerActive: true, remoteActive: false)
        let claimed = session.update(readerActive: true, remoteActive: true)
        #expect(claimed == .stop)
        #expect(!session.ownsAudio)
    }
}
