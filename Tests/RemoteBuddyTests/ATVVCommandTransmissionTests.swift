import Foundation
import Testing
@testable import RemoteBuddy

@Suite("ATVV command transmission")
@MainActor
struct ATVVCommandTransmissionTests {
    private final class DummyDelegate: BluetoothRemoteBridgeDelegate {
        func bluetoothBridge(_ bridge: BluetoothRemoteBridge, didChange state: BluetoothBridgeState) {}
        func bluetoothBridgeDidStartVoice(_ bridge: BluetoothRemoteBridge) {}
        func bluetoothBridgeDidStopVoice(_ bridge: BluetoothRemoteBridge) {}
        func bluetoothBridge(_ bridge: BluetoothRemoteBridge, didDecode samples: [Int16]) {}
        func bluetoothBridge(_ bridge: BluetoothRemoteBridge, didUpdateBatteryLevel level: Int?) {}
        func bluetoothBridge(_ bridge: BluetoothRemoteBridge, didIdentifyRemoteModel model: RemoteModel) {}
        func bluetoothBridge(_ bridge: BluetoothRemoteBridge, didUpdatePowerState state: RemotePowerState?) {}
        func bluetoothBridgeDeviceNameDidChange(_ bridge: BluetoothRemoteBridge) {}
    }

    private func makeBridge(
        schedule: @escaping OperationScheduler = { _, work in
            let item = DispatchWorkItem(block: work)
            return ScheduledOperation { item.cancel() }
        }
    ) throws -> (BluetoothRemoteBridge, DummyDelegate, UserDefaults, String) {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let delegate = DummyDelegate()
        let bridge = BluetoothRemoteBridge(
            settings: AppSettings(defaults: defaults),
            delegate: delegate,
            targetIdentifier: UUID(),
            scheduleMicrophoneClose: schedule
        )
        return (bridge, delegate, defaults, suite)
    }

    @Test func submissionClassifiesMissingPeripheralAndQueueCongestionCleanly() throws {
        let (bridge, delegate, defaults, suite) = try makeBridge()
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = delegate

        #expect(bridge.submitControlWrite(ATVVProtocol.getCapabilitiesV10) == .rejected(.missingPeripheral))

        bridge.testingControlWriteHandler = { _ in false }
        bridge.simulateReadyStateForTesting()
        #expect(bridge.submitControlWrite(ATVVProtocol.getCapabilitiesV10) == .rejected(.queueRejected))

        bridge.testingControlWriteHandler = { _ in true }
        #expect(bridge.submitControlWrite(ATVVProtocol.getCapabilitiesV10) == .accepted)
    }

    @Test func failedMicOpenDoesNotMarkMicrophoneOpened() throws {
        let (bridge, delegate, defaults, suite) = try makeBridge()
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = delegate

        bridge.simulateChromecastReadyStateForTesting()
        bridge.testingControlWriteHandler = { _ in false }

        #expect(!bridge.requestMicrophoneOpen())
        #expect(!bridge.isMicrophoneOpen)

        bridge.testingControlWriteHandler = { _ in true }
        #expect(bridge.requestMicrophoneOpen())
        #expect(bridge.isMicrophoneOpen)
    }

    @Test func micClosePendingRetryRecoversOrClearsOnWatchdogTimeout() throws {
        let clock = ControlledTestScheduler()
        let (bridge, delegate, defaults, suite) = try makeBridge(schedule: clock.voiceSchedule)
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = delegate

        bridge.simulateChromecastReadyStateForTesting()
        bridge.testingControlWriteHandler = { _ in false }
        bridge.simulateMicrophoneOpenedForTesting(true)

        #expect(!bridge.requestMicrophoneClose())
        #expect(bridge.isMicrophoneClosePending)
        #expect(bridge.isMicrophoneOpen)

        clock.advance(to: 5_000)
        #expect(!bridge.isMicrophoneClosePending)
        #expect(!bridge.isMicrophoneOpen)
    }
}
