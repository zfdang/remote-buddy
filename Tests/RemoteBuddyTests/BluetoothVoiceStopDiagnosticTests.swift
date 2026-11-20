import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Bluetooth voice stop diagnostics")
@MainActor
struct BluetoothVoiceStopDiagnosticTests {
    private final class Delegate: BluetoothRemoteBridgeDelegate {
        var reasons: [BluetoothVoiceStopReason?] = []
        func bluetoothBridge(_ bridge: BluetoothRemoteBridge, didChange state: BluetoothBridgeState) {}
        func bluetoothBridgeDidStartVoice(_ bridge: BluetoothRemoteBridge) {}
        func bluetoothBridgeDidStopVoice(_ bridge: BluetoothRemoteBridge) { reasons.append(bridge.lastVoiceStopReason) }
        func bluetoothBridge(_ bridge: BluetoothRemoteBridge, didDecode samples: [Int16]) {}
        func bluetoothBridge(_ bridge: BluetoothRemoteBridge, didUpdateBatteryLevel level: Int?) {}
        func bluetoothBridge(_ bridge: BluetoothRemoteBridge, didIdentifyRemoteModel model: RemoteModel) {}
        func bluetoothBridge(_ bridge: BluetoothRemoteBridge, didUpdatePowerState state: RemotePowerState?) {}
        func bluetoothBridgeDeviceNameDidChange(_ bridge: BluetoothRemoteBridge) {}
    }

    @Test(arguments: [BluetoothVoiceStopReason.remoteNotification, .remoteMicrophoneRefused,
        .localStop, .bridgeStopped, .systemSuspended, .closeUnacknowledged, .closeRetryExhausted])
    func reportsTheObservedStopWithoutClaimingAPhysicalRelease(reason: BluetoothVoiceStopReason) async {
        let suite = "voice-stop-diagnostics-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = ControlledTestScheduler()
        let delegate = Delegate()
        let queue = DispatchQueue(label: "voice-stop-diagnostics")
        var logs: [String] = []
        let bridge = BluetoothRemoteBridge(settings: AppSettings(defaults: defaults), delegate: delegate,
            allowsT1Remote: true, audioPipeline: BluetoothAudioPipeline(queue: queue),
            voiceDiagnosticLogger: { logs.append($0) }, scheduleMicrophoneClose: clock.voiceSchedule)
        defer { bridge.stop() }
        bridge.testingControlWriteHandler = { _ in reason != .closeRetryExhausted }
        bridge.simulateT1ReadyStateForTesting(nowUptime: { Double(clock.now) / 1_000 })
        func flush() async {
            await withCheckedContinuation { continuation in
                queue.async { DispatchQueue.main.async { continuation.resume() } }
            }
        }
        bridge.simulateControlPacketForTesting(Data([0x04, 0x03, 0x02, 0x01]))
        await flush()
        switch reason {
        case .remoteNotification: bridge.simulateControlPacketForTesting(Data([0x00]))
        case .remoteMicrophoneRefused: bridge.simulateControlPacketForTesting(Data([0x0C]))
        case .localStop: bridge.simulateLocalStopStreamingForTesting()
        case .bridgeStopped: bridge.stop()
        case .systemSuspended: bridge.suspendVoiceTransferState()
        case .closeUnacknowledged, .closeRetryExhausted:
            _ = bridge.requestMicrophoneClose()
            clock.advance(to: 5_000)
        default: Issue.record("Unhandled test stop reason")
        }
        await flush()
        #expect(delegate.reasons == [reason])
        #expect(logs.count == 1)
        #expect(logs.first?.contains("reason=\(reason.rawValue)") == true)
        #expect(logs.first?.contains("close_requested=\(reason == .bridgeStopped || reason == .closeUnacknowledged || reason == .closeRetryExhausted)") == true)
        bridge.stop()
        #expect(logs.count == 1)
    }

    @Test func drainingAnOldStreamDoesNotSetTheNewStreamsStopReason() async {
        let suite = "voice-stop-overlap-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let delegate = Delegate()
        let queue = DispatchQueue(label: "voice-stop-overlap")
        var logs: [String] = []
        let bridge = BluetoothRemoteBridge(settings: AppSettings(defaults: defaults), delegate: delegate,
            allowsT1Remote: true, audioPipeline: BluetoothAudioPipeline(queue: queue),
            voiceDiagnosticLogger: { logs.append($0) })
        defer { bridge.stop() }
        bridge.testingControlWriteHandler = { _ in true }
        bridge.simulateT1ReadyStateForTesting()

        // Hold the old stream's completion until a new stream has already begun.
        queue.suspend()
        bridge.simulateControlPacketForTesting(Data([0x04, 0x03, 0x02, 0x01]))
        bridge.simulateLocalStopStreamingForTesting()
        #expect(bridge.lastVoiceStopReason == .localStop)
        bridge.simulateControlPacketForTesting(Data([0x04, 0x03, 0x02, 0x02]))
        #expect(bridge.lastVoiceStopReason == nil)
        queue.resume()
        await withCheckedContinuation { continuation in
            queue.async { DispatchQueue.main.async { continuation.resume() } }
        }

        #expect(bridge.lastVoiceStopReason == nil)
        #expect(logs.count == 1)
        bridge.simulateControlPacketForTesting(Data([0x00]))
        await withCheckedContinuation { continuation in
            queue.async { DispatchQueue.main.async { continuation.resume() } }
        }
        #expect(bridge.lastVoiceStopReason == .remoteNotification)
        #expect(logs.count == 2)
        #expect(logs[0].contains("session=1 reason=local_stop"))
        #expect(logs[1].contains("session=2 reason=remote_notification"))
    }

    @Test func rejectUnsupportedAudioAndFailInitializationResetVoiceState() async {
        let suite = "voice-stop-reject-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let delegate = Delegate()
        let queue = DispatchQueue(label: "voice-stop-reject")
        let bridge = BluetoothRemoteBridge(settings: AppSettings(defaults: defaults), delegate: delegate,
            allowsT1Remote: true, audioPipeline: BluetoothAudioPipeline(queue: queue))
        defer { bridge.stop() }
        bridge.simulateT1ReadyStateForTesting()
        func flush() async {
            await withCheckedContinuation { continuation in
                queue.async { DispatchQueue.main.async { continuation.resume() } }
            }
        }

        // 1. Audio started, then rejectUnsupportedAudio called -> must notify delegate stop with .unsupportedAudio
        bridge.simulateControlPacketForTesting(Data([0x04, 0x03, 0x02, 0x01]))
        await flush()
        #expect(bridge.hasPendingVoiceWork)
        bridge.rejectUnsupportedAudio(LocalizedMessage("test_unsupported"))
        await flush()
        #expect(delegate.reasons == [.unsupportedAudio])
        #expect(!bridge.hasPendingVoiceWork)

        // 2. Audio started, then failInitialization called -> must notify delegate stop with .initializationFailed
        bridge.simulateT1ReadyStateForTesting()
        bridge.simulateControlPacketForTesting(Data([0x04, 0x03, 0x02, 0x02]))
        await flush()
        #expect(bridge.hasPendingVoiceWork)
        bridge.failInitialization(LocalizedMessage("test_failed"))
        await flush()
        #expect(delegate.reasons == [.unsupportedAudio, .initializationFailed])
        #expect(!bridge.hasPendingVoiceWork)
    }
}
