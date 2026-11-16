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
        let clock = ControlledTestScheduler()
        let delegate = Delegate()
        let queue = DispatchQueue(label: "voice-stop-diagnostics")
        var logs: [String] = []
        let bridge = BluetoothRemoteBridge(settings: AppSettings(), delegate: delegate,
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
}
