import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Chromecast G9N9N smart-toggle voice mode")
@MainActor
struct G9N9NSmartToggleTests {
    private func makeSmartToggleFixture(
        initialTimeMs: UInt64 = 1_000,
        voiceButtonMode: G9N9NVoiceButtonMode = .smartToggle,
        fnTapModeEnabled: Bool = false
    ) throws -> (
        model: BridgeAppModel,
        bridge: BluetoothRemoteBridge,
        clock: ControlledTestScheduler,
        flushAudio: () async -> Void,
        defaults: UserDefaults,
        writtenCommands: () -> [Data],
        keyEdges: () -> [Bool]
    ) {
        let defaults = EphemeralUserDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.voiceKeyMode = .rightOption
        settings.voiceFnTapModeEnabled = fnTapModeEnabled

        let bridgeID = UUID()
        let profileID = settings.registerBluetoothRemote(identifier: bridgeID, model: .chromecastVoiceRemote)
        settings.setG9N9NVoiceButtonMode(voiceButtonMode, for: profileID)
        settings.selectRemoteProfile(profileID)

        let micDevice = AudioDeviceInfo(
            id: 202,
            uid: settings.selectedAudioDeviceUID,
            name: "Test Remote Buddy Mic"
        )
        let model = BridgeAppModel(
            settings: settings,
            initialAudioDevices: [micDevice],
            permissionSnapshotProvider: {
                HIDPermissionSnapshot(inputMonitoringGranted: true, accessibilityGranted: true)
            }
        )
        model.started = true

        var recordedKeys: [Bool] = []
        model.voiceKeyStateSetter = { _, down in
            recordedKeys.append(down)
            return true
        }
        model.voiceTapTrigger = VoiceTapTrigger(selectedMode: { .rightOption }, setKey: { _, down in
            recordedKeys.append(down)
            return true
        })
        model.voiceInputDestinationCoordinator = VoiceInputDestinationCoordinator(snapshot: {
            VoiceInputDestinationSnapshot(
                bundleIdentifier: "test.editor",
                role: "AXTextArea",
                subrole: "",
                enabled: true,
                editable: true,
                protectedContent: false,
                semanticText: "input"
            )
        })
        model.preferredInputSourceMonitor = PreferredInputSourceMonitor(
            voiceTool: { .unselected },
            logger: { _ in }
        )
        let clock = ControlledTestScheduler()
        clock.advance(to: initialTimeMs)
        model.voiceFnTapSession = model.makeVoiceFnTapSession(schedule: clock.voiceSchedule)
        model.voiceFnTapSession.setEnabled(fnTapModeEnabled)

        let audioQueue = DispatchQueue(label: "g9n9n.smart.toggle.test.\(UUID().uuidString)")
        let flushAudio: () async -> Void = {
            await withCheckedContinuation { continuation in
                audioQueue.async {
                    DispatchQueue.main.async {
                        continuation.resume()
                    }
                }
            }
        }

        var commands: [Data] = []
        let bridge = BluetoothRemoteBridge(
            settings: settings,
            delegate: model,
            targetIdentifier: bridgeID,
            allowsG9N9N: true,
            audioPipeline: BluetoothAudioPipeline(queue: audioQueue),
            voiceDiagnosticLogger: { _ in },
            scheduleMicrophoneClose: clock.voiceSchedule
        )
        bridge.testingControlWriteHandler = { data in
            commands.append(data)
            return true
        }
        model.connections.bridges[bridgeID] = bridge
        bridge.simulateChromecastReadyStateForTesting(nowUptime: { Double(clock.now) / 1_000 })
        model.connections.states[ObjectIdentifier(bridge)] = .ready("Chromecast Remote")
        model.refreshBluetoothPresentation()
        model.cancelVirtualAudioReleaseIfPending(trigger: "smart_toggle_fixture")
        model.audio.output.simulateReadyForTesting(device: micDevice)

        return (
            model,
            bridge,
            clock,
            flushAudio,
            defaults, { commands }, { recordedKeys })
    }

    @Test func smartToggleStateMachineEnforcesThresholdsAndSecondPressTriggers() {
        var state = G9N9NSmartToggleState()
        let id = UUID()
        let otherID = UUID()

        #expect(!state.isActive)
        state.beginPhysicalPress(bridgeID: id, at: 10.0)
        #expect(state.isActive)
        #expect(state.ownerBridgeID == id)

        // Short tap (< 0.7s) from remoteNotification reopens; long hold (>= 0.7s) stops.
        #expect(state.shouldReopenOnPhysicalStop(
            bridgeID: id,
            stopReason: .remoteNotification,
            localCloseRequested: false,
            at: 10.25
        ))
        #expect(!state.shouldReopenOnPhysicalStop(
            bridgeID: id,
            stopReason: .remoteNotification,
            localCloseRequested: false,
            at: 10.75
        ))
        #expect(!state.shouldReopenOnPhysicalStop(
            bridgeID: id,
            stopReason: .localStop,
            localCloseRequested: false,
            at: 10.25
        ))
        #expect(!state.shouldReopenOnPhysicalStop(
            bridgeID: id,
            stopReason: .remoteNotification,
            localCloseRequested: true,
            at: 10.25
        ))
        #expect(!state.shouldReopenOnPhysicalStop(
            bridgeID: otherID,
            stopReason: .remoteNotification,
            localCloseRequested: false,
            at: 10.25
        ))

        // While pressed, 0x08/0x04 must not be treated as a second-press stop.
        #expect(!state.shouldStopOnRemoteOpenRequest(bridgeID: id))
        #expect(!state.shouldStopOnRemoteAudioStart(
            bridgeID: id,
            interaction: 0x03,
            activeSessionID: 1,
            incomingSessionID: 2
        ))

        // Transition to awaitingReopen: 04 00 02 (0x0C response) is admitted; 04 03 02 or 0x08 stops.
        state.enterAwaitingReopen(bridgeID: id)
        #expect(state.isAwaitingReopen)
        #expect(state.shouldStopOnRemoteOpenRequest(bridgeID: id))
        #expect(!state.shouldStopOnRemoteAudioStart(
            bridgeID: id,
            interaction: 0x00,
            activeSessionID: 0,
            incomingSessionID: 0
        ))
        #expect(state.shouldStopOnRemoteAudioStart(
            bridgeID: id,
            interaction: 0x03,
            activeSessionID: 0,
            incomingSessionID: 1
        ))

        // Enter handsFreeActive: second press via 0x08, interaction=0x03, or new session ID stops.
        let deadlineGen = state.enterHandsFreeActive(bridgeID: id)
        #expect(deadlineGen != nil)
        #expect(!state.isAwaitingReopen)
        #expect(state.shouldStopOnRemoteOpenRequest(bridgeID: id))
        #expect(state.shouldStopOnRemoteAudioStart(
            bridgeID: id,
            interaction: 0x03,
            activeSessionID: 0,
            incomingSessionID: 0
        ))
        #expect(state.shouldStopOnRemoteAudioStart(
            bridgeID: id,
            interaction: 0x00,
            activeSessionID: 0,
            incomingSessionID: 1
        ))
        #expect(!state.shouldStopOnRemoteAudioStart(
            bridgeID: id,
            interaction: 0x00,
            activeSessionID: 0,
            incomingSessionID: 0
        ))

        // Closing keeps rejecting any trailing AUDIO_START.
        #expect(state.enterClosing(bridgeID: id) != nil)
        #expect(state.shouldStopOnRemoteAudioStart(
            bridgeID: id,
            interaction: 0x00,
            activeSessionID: 0,
            incomingSessionID: 0
        ))

        state.reset()
        #expect(!state.isActive)
        #expect(state.ownerBridgeID == nil)
    }

    @Test func voiceButtonModeDefaultsSmartToggleAndPersistsForChromecastOnly() throws {
        let defaults = EphemeralUserDefaults()

        let settings = AppSettings(defaults: defaults)
        let googleID = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        let xiaomiID = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)

        #expect(settings.g9n9nVoiceButtonMode(for: googleID) == .smartToggle)
        #expect(settings.g9n9nVoiceButtonMode(for: xiaomiID) == .holdToTalk)

        settings.setG9N9NVoiceButtonMode(.holdToTalk, for: googleID)
        settings.setG9N9NVoiceButtonMode(.smartToggle, for: xiaomiID)
        #expect(settings.g9n9nVoiceButtonMode(for: googleID) == .holdToTalk)
        #expect(settings.g9n9nVoiceButtonMode(for: xiaomiID) == .holdToTalk)

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.g9n9nVoiceButtonMode(for: googleID) == .holdToTalk)
        #expect(reloaded.remoteDeviceProfiles.first(where: { $0.id == googleID })?.g9n9nVoiceButtonMode == .holdToTalk)

        reloaded.setG9N9NVoiceButtonMode(.smartToggle, for: googleID)
        #expect(reloaded.g9n9nVoiceButtonMode(for: googleID) == .smartToggle)
        #expect(reloaded.remoteDeviceProfiles.first(where: { $0.id == googleID })?.g9n9nVoiceButtonMode == nil)

        let localization = LocalizationStore(settings: reloaded)
        for key in [
            "connection.g9n9n.voice_button_mode.title",
            "connection.g9n9n.voice_button_mode.hold",
            "connection.g9n9n.voice_button_mode.smart_toggle",
            "connection.g9n9n.voice_button_mode.hold_help",
            "connection.g9n9n.voice_button_mode.smart_toggle_help",
        ] {
            localization.select(.english)
            let en = localization.text(key)
            localization.select(.simplifiedChinese)
            let zh = localization.text(key)
            #expect(en != key && zh != key && en != zh)
        }
    }

    @Test func shortTapReopensHandsFreeAndSecondPress0x08StopsCleanly() async throws {
        let fixture = try makeSmartToggleFixture(voiceButtonMode: .smartToggle)
        let (model, bridge, clock, flushAudio, _, writtenCommands, keyEdges) = fixture
        defer {
            model.started = false
            bridge.stop()
        }

        // 1. First physical press: 0x04 03 02 01 starts session and holds voice key down once.
        bridge.simulateControlPacketForTesting(Data([0x04, 0x03, 0x02, 0x01]))
        await flushAudio()
        #expect(model.isStreaming)
        #expect(model.voiceSession.isActive)
        #expect(model.voiceKeyLatch.isHeld)
        #expect(keyEdges() == [true])

        // 2. Quick release at +250ms (< 0.7s): 0x00 does NOT release key or stop dictation; sends 0x0C 00.
        clock.advance(to: 1_250)
        bridge.simulateControlPacketForTesting(Data([0x00]))
        await flushAudio()
        #expect(model.g9n9nSmartToggle.isAwaitingReopen)
        #expect(model.isStreaming)
        #expect(model.shouldKeepVirtualAudioActive)
        #expect(model.voiceKeyLatch.isHeld)
        #expect(keyEdges() == [true])
        #expect(writtenCommands() == [Data([0x0C, 0x00])])

        // 3. Hardware responds with 04 00 02 00: enters handsFreeActive without re-pressing key.
        clock.advance(to: 1_280)
        bridge.simulateControlPacketForTesting(Data([0x04, 0x00, 0x02, 0x00]))
        await flushAudio()
        guard case .handsFreeActive = model.g9n9nSmartToggle.phase else {
            Issue.record("Expected handsFreeActive phase after reopen")
            return
        }
        #expect(model.voiceSession.isActive)
        #expect(model.isStreaming)
        #expect(keyEdges() == [true])

        // 4. Second press sends 0x08 -> Host sends 0x0D 00 -> remote confirms 0x00 -> clean stop.
        clock.advance(to: 5_000)
        bridge.simulateControlPacketForTesting(Data([0x08]))
        guard case .closing = model.g9n9nSmartToggle.phase else {
            Issue.record("Expected closing phase after second press")
            return
        }
        #expect(writtenCommands() == [Data([0x0C, 0x00]), Data([0x0D, 0x00])])

        bridge.simulateControlPacketForTesting(Data([0x00]))
        await flushAudio()
        #expect(!model.g9n9nSmartToggle.isActive)
        #expect(!model.voiceSession.isActive)
        #expect(!model.isStreaming)
        #expect(!model.voiceKeyLatch.isHeld)
        #expect(!model.shouldKeepVirtualAudioActive)
        #expect(keyEdges() == [true, false])
    }

    @Test func secondPressAudioStart040302ClosesSessionInsteadOfReplacingStream() async throws {
        let fixture = try makeSmartToggleFixture(voiceButtonMode: .smartToggle)
        let (model, bridge, clock, flushAudio, _, writtenCommands, keyEdges) = fixture
        defer {
            model.started = false
            bridge.stop()
        }

        bridge.simulateControlPacketForTesting(Data([0x04, 0x03, 0x02, 0x01]))
        await flushAudio()
        #expect(model.isStreaming)
        #expect(model.g9n9nSmartToggle.isActive)
        clock.advance(to: 1_200)
        bridge.simulateControlPacketForTesting(Data([0x00]))
        await flushAudio()
        #expect(model.g9n9nSmartToggle.isAwaitingReopen)
        clock.advance(to: 1_230)
        bridge.simulateControlPacketForTesting(Data([0x04, 0x00, 0x02, 0x00]))
        await flushAudio()
        #expect(model.g9n9nSmartToggle.phase == .handsFreeActive(bridgeID: bridge.deviceIdentifier!))
        guard case .handsFreeActive = model.g9n9nSmartToggle.phase else {
            Issue.record("Expected handsFreeActive phase")
            return
        }

        // Second physical press sends 04 03 02 02 directly -> must send MIC_CLOSE (0x0D 02), NOT replace stream.
        clock.advance(to: 4_000)
        bridge.simulateControlPacketForTesting(Data([0x04, 0x03, 0x02, 0x02]))
        guard case .closing = model.g9n9nSmartToggle.phase else {
            Issue.record("Expected closing phase")
            return
        }
        #expect(writtenCommands() == [Data([0x0C, 0x00]), Data([0x0D, 0x02])])
        #expect(keyEdges() == [true])

        // Releasing 2nd press sends 0x00 -> completes stop without reopening again.
        clock.advance(to: 4_180)
        bridge.simulateControlPacketForTesting(Data([0x00]))
        await flushAudio()
        #expect(!model.g9n9nSmartToggle.isActive)
        #expect(!model.isStreaming)
        #expect(writtenCommands() == [Data([0x0C, 0x00]), Data([0x0D, 0x02])])
        #expect(keyEdges() == [true, false])
    }

    @Test func longHoldInSmartToggleModeStopsOnReleaseWithoutReopening() async throws {
        let fixture = try makeSmartToggleFixture(voiceButtonMode: .smartToggle)
        let (model, bridge, clock, flushAudio, _, writtenCommands, keyEdges) = fixture
        defer {
            model.started = false
            bridge.stop()
        }

        bridge.simulateControlPacketForTesting(Data([0x04, 0x03, 0x02, 0x01]))
        await flushAudio()
        #expect(keyEdges() == [true])

        // Hold for 850ms (>= 0.7s) then release.
        clock.advance(to: 1_850)
        bridge.simulateControlPacketForTesting(Data([0x00]))
        await flushAudio()

        #expect(writtenCommands().isEmpty)
        #expect(!model.g9n9nSmartToggle.isActive)
        #expect(!model.voiceSession.isActive)
        #expect(!model.isStreaming)
        #expect(keyEdges() == [true, false])
    }

    @Test func shortTapInHoldToTalkModeDoesNotReopen() async throws {
        let fixture = try makeSmartToggleFixture(voiceButtonMode: .holdToTalk)
        let (model, bridge, clock, flushAudio, _, writtenCommands, keyEdges) = fixture
        defer {
            model.started = false
            bridge.stop()
        }

        bridge.simulateControlPacketForTesting(Data([0x04, 0x03, 0x02, 0x01]))
        await flushAudio()
        clock.advance(to: 1_200)
        bridge.simulateControlPacketForTesting(Data([0x00]))
        await flushAudio()

        #expect(writtenCommands().isEmpty)
        #expect(!model.g9n9nSmartToggle.isActive)
        #expect(!model.isStreaming)
        #expect(keyEdges() == [true, false])
    }

    @Test func secondPressWhileAwaitingReopenCancelsAndRejectsLateAudioStart() async throws {
        let fixture = try makeSmartToggleFixture(voiceButtonMode: .smartToggle)
        let (model, bridge, clock, flushAudio, _, writtenCommands, keyEdges) = fixture
        defer {
            model.started = false
            bridge.stop()
        }

        bridge.simulateControlPacketForTesting(Data([0x04, 0x03, 0x02, 0x01]))
        await flushAudio()
        clock.advance(to: 1_200)
        bridge.simulateControlPacketForTesting(Data([0x00]))
        await flushAudio()
        #expect(model.g9n9nSmartToggle.isAwaitingReopen)
        #expect(writtenCommands() == [Data([0x0C, 0x00])])

        // Second press 0x08 arrives before 04 00 02: immediately stops session and sends 0x0D 01.
        clock.advance(to: 1_220)
        bridge.simulateControlPacketForTesting(Data([0x08]))
        #expect(!model.g9n9nSmartToggle.isActive)
        #expect(!model.isStreaming)
        #expect(keyEdges() == [true, false])
        #expect(writtenCommands() == [Data([0x0C, 0x00]), Data([0x0D, 0x01])])

        // Late 04 00 02 00 from the cancelled 0x0C open must be rejected & closed without restarting.
        clock.advance(to: 1_250)
        bridge.simulateControlPacketForTesting(Data([0x04, 0x00, 0x02, 0x00]))
        await flushAudio()
        #expect(!model.isStreaming)
        #expect(keyEdges() == [true, false])
        #expect(writtenCommands() == [Data([0x0C, 0x00]), Data([0x0D, 0x01]), Data([0x0D, 0x00])])
    }

    @Test func smartToggleWorksWithFnTapModeVoiceToolsAcrossReopenAndStop() async throws {
        let fixture = try makeSmartToggleFixture(
            voiceButtonMode: .smartToggle,
            fnTapModeEnabled: true
        )
        let (model, bridge, clock, flushAudio, _, writtenCommands, keyEdges) = fixture
        defer {
            model.started = false
            bridge.stop()
        }

        bridge.simulateControlPacketForTesting(Data([0x04, 0x03, 0x02, 0x01]))
        await flushAudio()
        clock.advance(to: 1_300)
        #expect(keyEdges() == [true, false])

        // Quick tap release reopens without sending stop tap yet.
        bridge.simulateControlPacketForTesting(Data([0x00]))
        await flushAudio()
        #expect(model.g9n9nSmartToggle.isAwaitingReopen)
        #expect(writtenCommands() == [Data([0x0C, 0x00])])
        #expect(keyEdges() == [true, false])

        // Hands-free reopen succeeds without sending a duplicate start tap.
        clock.advance(to: 1_330)
        bridge.simulateControlPacketForTesting(Data([0x04, 0x00, 0x02, 0x00]))
        await flushAudio()
        clock.advance(to: 1_600)
        #expect(keyEdges() == [true, false])

        // Second press stops and sends the single stop tap pulse.
        bridge.simulateControlPacketForTesting(Data([0x08]))
        bridge.simulateControlPacketForTesting(Data([0x00]))
        await flushAudio()
        clock.advance(to: 2_000)
        #expect(!model.isStreaming)
        #expect(keyEdges() == [true, false, true, false])
    }

    @Test func disconnectDuringHandsFreeClearsSmartToggleAndReleasesKey() async throws {
        let fixture = try makeSmartToggleFixture(voiceButtonMode: .smartToggle)
        let (model, bridge, clock, flushAudio, _, _, keyEdges) = fixture
        defer {
            model.started = false
            bridge.stop()
        }

        bridge.simulateControlPacketForTesting(Data([0x04, 0x03, 0x02, 0x01]))
        await flushAudio()
        #expect(model.isStreaming)
        #expect(model.g9n9nSmartToggle.isActive)
        clock.advance(to: 1_200)
        bridge.simulateControlPacketForTesting(Data([0x00]))
        await flushAudio()
        #expect(model.g9n9nSmartToggle.isAwaitingReopen)
        clock.advance(to: 1_230)
        bridge.simulateControlPacketForTesting(Data([0x04, 0x00, 0x02, 0x00]))
        await flushAudio()
        #expect(model.g9n9nSmartToggle.phase == .handsFreeActive(bridgeID: bridge.deviceIdentifier!))
        guard case .handsFreeActive = model.g9n9nSmartToggle.phase else {
            Issue.record("Expected handsFreeActive phase")
            return
        }

        model.bluetoothBridge(bridge, didChange: .reconnecting)
        #expect(!model.g9n9nSmartToggle.isActive)
        #expect(!model.voiceSession.isActive)
        #expect(!model.isStreaming)
        #expect(keyEdges() == [true, false])
    }

    @Test func holdDurationUsesProtocolStartTimestampAcrossDelayedStartDelivery() async throws {
        let fixture = try makeSmartToggleFixture(voiceButtonMode: .smartToggle)
        let (model, bridge, clock, flushAudio, _, writtenCommands, keyEdges) = fixture
        defer {
            model.started = false
            bridge.stop()
        }

        // Physical press starts at 1_000, but audio/HID start delivery completes 500ms later.
        bridge.simulateControlPacketForTesting(Data([0x04, 0x03, 0x02, 0x01]))
        clock.advance(to: 1_500)
        await flushAudio()
        #expect(model.isStreaming)

        // Release at 1_750 (750ms after 0x04, only 250ms after didStartVoice): must stop as long hold.
        clock.advance(to: 1_750)
        bridge.simulateControlPacketForTesting(Data([0x00]))
        await flushAudio()

        #expect(writtenCommands().isEmpty)
        #expect(!model.g9n9nSmartToggle.isActive)
        #expect(!model.isStreaming)
        #expect(keyEdges() == [true, false])
    }

    @Test func secondPress0x04FollowedBy0x08SendsSingleMicClose() async throws {
        let fixture = try makeSmartToggleFixture(voiceButtonMode: .smartToggle)
        let (model, bridge, clock, flushAudio, _, writtenCommands, keyEdges) = fixture
        defer {
            model.started = false
            bridge.stop()
        }

        bridge.simulateControlPacketForTesting(Data([0x04, 0x03, 0x02, 0x01]))
        await flushAudio()
        clock.advance(to: 1_200)
        bridge.simulateControlPacketForTesting(Data([0x00]))
        await flushAudio()
        clock.advance(to: 1_230)
        bridge.simulateControlPacketForTesting(Data([0x04, 0x00, 0x02, 0x00]))
        await flushAudio()

        // Hardware sends 0x04 first and 0x08 a few ms later: MIC_CLOSE must only be written once.
        clock.advance(to: 4_000)
        bridge.simulateControlPacketForTesting(Data([0x04, 0x03, 0x02, 0x02]))
        clock.advance(to: 4_020)
        bridge.simulateControlPacketForTesting(Data([0x08]))
        #expect(writtenCommands() == [Data([0x0C, 0x00]), Data([0x0D, 0x02])])

        bridge.simulateControlPacketForTesting(Data([0x00]))
        await flushAudio()
        #expect(!model.g9n9nSmartToggle.isActive)
        #expect(!model.isStreaming)
        #expect(keyEdges() == [true, false])
    }

    @Test func retransmittedAudioStartDuringClosingKeepsWatchdogIntact() async throws {
        let fixture = try makeSmartToggleFixture(voiceButtonMode: .smartToggle)
        let (model, bridge, clock, flushAudio, _, writtenCommands, keyEdges) = fixture
        defer {
            model.started = false
            bridge.stop()
        }

        bridge.simulateControlPacketForTesting(Data([0x04, 0x03, 0x02, 0x01]))
        await flushAudio()
        clock.advance(to: 1_200)
        bridge.simulateControlPacketForTesting(Data([0x00]))
        await flushAudio()
        clock.advance(to: 1_230)
        bridge.simulateControlPacketForTesting(Data([0x04, 0x00, 0x02, 0x00]))
        await flushAudio()

        clock.advance(to: 4_000)
        bridge.simulateControlPacketForTesting(Data([0x08]))
        bridge.simulateControlPacketForTesting(Data([0x04, 0x00, 0x02, 0x00]))
        #expect(writtenCommands() == [Data([0x0C, 0x00]), Data([0x0D, 0x00])])

        // Original 5s stream-stop watchdog must still fire if 0x00 never arrives.
        clock.advance(to: 9_000)
        await flushAudio()
        #expect(!model.g9n9nSmartToggle.isActive)
        #expect(!model.isStreaming)
        #expect(keyEdges() == [true, false])
    }
}
