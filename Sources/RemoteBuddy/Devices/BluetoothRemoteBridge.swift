import CoreBluetooth
import Foundation

enum BluetoothBridgeState: Equatable {
    case stopped
    case bluetoothUnavailable(LocalizedMessage)
    case scanning
    case connecting
    case discovering
    case ready(String)
    case reconnecting
    case failed(LocalizedMessage)

    var message: LocalizedMessage {
        switch self {
        case .stopped: return LocalizedMessage("common.status.stopped")
        case .bluetoothUnavailable(let reason): return reason
        case .scanning: return LocalizedMessage("connection.status.searching")
        case .connecting: return LocalizedMessage("connection.status.connecting")
        case .discovering: return LocalizedMessage("connection.status.initializing_voice")
        case .ready: return LocalizedMessage("connection.status.connected_to_device")
        case .reconnecting: return LocalizedMessage("connection.status.reconnecting")
        case .failed(let reason): return reason
        }
    }

    var logDescription: String {
        switch self {
        case .stopped: return "stopped"
        case .bluetoothUnavailable(let reason): return "bluetooth_unavailable(\(reason.key))"
        case .scanning: return "scanning"
        case .connecting: return "connecting"
        case .discovering: return "discovering"
        case .ready(let name): return "ready(\(DiagnosticRedactor.redactedDeviceName(name)))"
        case .reconnecting: return "reconnecting"
        case .failed(let reason): return "failed(\(reason.key))"
        }
    }
}

@MainActor
protocol BluetoothRemoteBridgeDelegate: AnyObject {
    func bluetoothBridge(_ bridge: BluetoothRemoteBridge, didChange state: BluetoothBridgeState)
    func bluetoothBridgeDidStartVoice(_ bridge: BluetoothRemoteBridge)
    func bluetoothBridgeDidStopVoice(_ bridge: BluetoothRemoteBridge)
    func bluetoothBridge(_ bridge: BluetoothRemoteBridge, didDecode samples: [Int16])
    func bluetoothBridge(_ bridge: BluetoothRemoteBridge, didUpdateBatteryLevel level: Int?)
    func bluetoothBridge(_ bridge: BluetoothRemoteBridge, didIdentifyRemoteModel model: RemoteModel)
    func bluetoothBridge(_ bridge: BluetoothRemoteBridge, didUpdatePowerState state: RemotePowerState?)
    func bluetoothBridgeDeviceNameDidChange(_ bridge: BluetoothRemoteBridge)
    func bluetoothBridgeShouldCloseStreamingOnRemoteOpenRequest(_ bridge: BluetoothRemoteBridge) -> Bool
    func bluetoothBridgeShouldStopToggleVoiceOnRemoteAudioStart(
        _ bridge: BluetoothRemoteBridge,
        interaction: UInt8?,
        incomingSessionID: UInt8?
    ) -> Bool
    func bluetoothBridgeIsClosingToggleVoice(_ bridge: BluetoothRemoteBridge) -> Bool
    func bluetoothBridgeDidRequestStopToggleVoice(_ bridge: BluetoothRemoteBridge)
}

extension BluetoothRemoteBridgeDelegate {
    func bluetoothBridgeShouldCloseStreamingOnRemoteOpenRequest(_ bridge: BluetoothRemoteBridge) -> Bool {
        false
    }

    func bluetoothBridgeShouldStopToggleVoiceOnRemoteAudioStart(
        _ bridge: BluetoothRemoteBridge,
        interaction: UInt8?,
        incomingSessionID: UInt8?
    ) -> Bool {
        false
    }

    func bluetoothBridgeIsClosingToggleVoice(_ bridge: BluetoothRemoteBridge) -> Bool {
        false
    }

    func bluetoothBridgeDidRequestStopToggleVoice(_ bridge: BluetoothRemoteBridge) {}
}

@MainActor
final class BluetoothRemoteBridge: NSObject {
    static let defaultCapabilities = ATVVCapabilities(
        version: 0x0100,
        codecs: 0x02,
        interaction: 0x03,
        frameSize: 120,
        selectedCodec: 0x02,
        sampleRate: 16_000
    )

    let settings: AppSettings
    let allowsG9N9N: Bool
    let allowsT1Remote: Bool
    let adoptUnidentifiedATVVAsT1: () -> Bool
    var googleCandidate = false
    var t1Candidate = false
    var googleReadiness = G9N9NReadiness()
    var t1Readiness = T1RemoteReadiness()
    static let maxMicrophoneKeepaliveExtensions = 30
    var microphoneKeepalive: ScheduledOperation?
    var microphoneKeepaliveCount = 0
    var identifiedModel: RemoteModel?
    var reportedHIDIdentity: RemoteHIDIdentity?
    var onHIDIdentityUpdate: (() -> Void)?
    var deviceInformation = RemoteDeviceInformation() {
        didSet {
            if deviceInformation != oldValue { onDeviceInformationUpdate?() }
        }
    }
    var onDeviceInformationUpdate: (() -> Void)?
    weak var delegate: BluetoothRemoteBridgeDelegate?
    private(set) var targetIdentifier: UUID?
    let excludedIdentifiers: () -> Set<UUID>
    /// 已被判定为「别的产品」的标识；本桥此后一律不再连接，也不再走扫描回退。
    var rejectedIdentifiers = Set<UUID>()
    var central: CBCentralManager?
    var centralGeneration: UInt64?
    var peripheral: CBPeripheral?
    var peripheralDelegateProxy: BluetoothRemotePeripheralDelegateProxy?
    var transmitCharacteristic: CBCharacteristic?
    var audioCharacteristic: CBCharacteristic?
    var controlCharacteristic: CBCharacteristic?
    var batteryCharacteristic: CBCharacteristic?
    var batteryStatusCharacteristic: CBCharacteristic?
    var batteryLevelNeedsPolling = false
    var batteryStatusNeedsPolling = false
    var batteryRefreshWorkItem: DispatchWorkItem?
    var batteryPollingActive = false
    var hasObservedBatteryLevel = false
    var lastObservedBatteryLevel: Int?
    var hasObservedPowerState = false
    var lastObservedPowerState: RemotePowerState?
    var subscribedUUIDs = Set<CBUUID>()
    var scanSubscription: UUID?
    let scanWatchdog = BluetoothScanWatchdog()
    let reconnectWakeMonitor = BluetoothReconnectWakeMonitor()
    var remoteWakeStartedAt: TimeInterval?
    var reconnectWorkItem: DispatchWorkItem?
    let scheduleReconnect: (TimeInterval, DispatchWorkItem) -> Void
    var connectionTimeoutWorkItem: DispatchWorkItem?
    var initializationTimeoutWorkItem: DispatchWorkItem?
    let disconnectWatchdog = BluetoothDisconnectWatchdog()
    var capabilitiesRequested = false
    var capabilitiesConfirmed = false
    var modelFormatResolved = false
    var requestedReconnectDelay: TimeInterval?
    var reconnectPolicy = BluetoothReconnectPolicy()
    var currentAttemptUsesCachedTarget = false
    var generationCounter: UInt64 = 0
    var lifecycle: BluetoothLifecyclePhase = .stopped
    var shouldRun = false
    var systemSuspension = BluetoothSystemSuspensionState()
    var capabilities = BluetoothRemoteBridge.defaultCapabilities
    let audioDecoder: BluetoothAudioPipeline
    var voiceStartNotified = false
    var streaming: Bool { audioDecoder.isStreaming }
    var hasPendingVoiceWork: Bool { audioDecoder.hasPendingVoiceWork || voiceStartNotified }
    lazy var acknowledgedWrites = AcknowledgedBluetoothWriteQueue(
        send: { [weak self] data in
            guard let self, let peripheral = self.peripheral,
                  let characteristic = self.transmitCharacteristic else { return }
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
        },
        onFailure: { [weak self] in
            guard let self else { return }
            self.cancelMicrophoneCloseWatchdog()
            self.microphoneClosePending = false
            self.microphoneCloseSessionID = nil
            self.microphoneOpened = false
            self.stopStreaming(reason: .writeResponseFailure)
            AppLogger.shared.write("BLE WRITE failed reason=response_or_timeout")
            self.scheduleReconnect()
        }
    )
    lazy var unacknowledgedWrites = FlowControlledBluetoothWriteQueue(
        canSend: { [weak self] in
            guard let self, self.transmitCharacteristic != nil, let peripheral = self.peripheral else {
                return false
            }
            return peripheral.canSendWriteWithoutResponse
        },
        send: { [weak self] data in
            guard let self, let peripheral = self.peripheral,
                  let characteristic = self.transmitCharacteristic else { return }
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
        },
        onFailure: { [weak self] in
            guard let self else { return }
            self.cancelMicrophoneCloseWatchdog()
            self.microphoneClosePending = false
            self.microphoneCloseSessionID = nil
            self.microphoneOpened = false
            self.stopStreaming(reason: .flowControlTimeout)
            AppLogger.shared.write("BLE WRITE failed reason=flow_control_timeout")
            self.scheduleReconnect()
        }
    )
    let voiceDiagnosticLogger: (String) -> Void
    var lastVoiceStopReason: BluetoothVoiceStopReason?
    var streamStopRecorded = false
    var localMicrophoneCloseRequested = false
    // This is a requested-open flag; ATVV stream notifications establish actual streaming.
    var microphoneOpened = false
    var microphoneClosePending = false
    var microphoneCloseSessionID: UInt8?
    var microphoneCloseWatchdog: ScheduledOperation?
    let scheduleMicrophoneClose: OperationScheduler
    var microphoneCloseWatchdogToken: UUID?
    var streamStopWatchdog: ScheduledOperation?
    var streamStopWatchdogToken: UUID?
    var cancelledMicrophoneOpenAt: TimeInterval?
    var sessionID: UInt8 = 0
    var activeStreamSessionID: UInt8?
    var lastStopAt: TimeInterval?
    var lastVoiceStartAt: TimeInterval?
    var lastVoiceStopAt: TimeInterval?
    var nowUptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
#if DEBUG
    var testingControlWriteHandler: ((Data) -> Bool)?
#endif

    var isMicrophoneClosePending: Bool { microphoneClosePending }
    var isMicrophoneOpen: Bool { microphoneOpened }

#if DEBUG
    func enqueueUnacknowledgedWriteForTesting(_ data: Data) -> Bool {
        unacknowledgedWrites.enqueue(data)
    }

    func enqueueAcknowledgedWriteForTesting(_ data: Data) -> Bool {
        acknowledgedWrites.enqueue(data)
    }

    var hasPendingWriteWorkForTesting: Bool {
        acknowledgedWrites.hasPendingWork || unacknowledgedWrites.hasPendingWork
    }

    var isLifecycleReadyForTesting: Bool { lifecycle.isReady }
    var isConnectionCycleNeededForTesting: Bool { systemSuspension.connectionCycleNeeded }
    var reconnectFailureCountForTesting: Int { reconnectPolicy.consecutiveFailureCount }
    var cachedTargetFailureCountForTesting: Int { reconnectPolicy.cachedTargetFailureCount }
    var allowsCachedTargetRetrievalForTesting: Bool { reconnectPolicy.allowsCachedTargetRetrieval }
    var isBatteryPollingActiveForTesting: Bool { batteryPollingActive }

    @discardableResult
    func advanceCachedTargetRetrievalPermissionForTesting() -> Bool {
        reconnectPolicy.nextCachedTargetRetrievalPermission()
    }

    func simulateDiscoveryFailureReconnectForTesting(
        bypassCachedTarget: Bool,
        currentAttemptUsesCachedTarget: Bool
    ) {
        shouldRun = true
        self.currentAttemptUsesCachedTarget = currentAttemptUsesCachedTarget
        scheduleReconnect(bypassCachedTarget: bypassCachedTarget)
    }

    func simulatePowerOnRecoveryTransitionForTesting() {
        shouldRun = true
        generationCounter &+= 1
        let generation = generationCounter
        lifecycle = .waitingBluetoothPower(generation)
        _ = applyCentralRecoveryTransition(.poweredOn, generation: generation)
    }

    func simulateMicrophoneOpenedForTesting(_ opened: Bool) {
        microphoneOpened = opened
    }

    func simulateStreamStopForTesting() {
        handleRemoteStreamStop(reason: .remoteNotification)
    }

    func simulateLocalStopStreamingForTesting() {
        stopStreaming(reason: .localStop)
    }

    func simulateReadyStateForTesting(deviceName: String = "Test remote") {
        shouldRun = true
        generationCounter &+= 1
        lifecycle = .ready(generationCounter)
        state = .ready(deviceName)
    }

    func simulateT1ReadyStateForTesting(
        deviceName: String = "T1-Remote",
        nowUptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.nowUptime = nowUptime
        shouldRun = true
        generationCounter &+= 1
        t1Candidate = true
        capabilities = Self.defaultCapabilities
        capabilitiesConfirmed = true
        modelFormatResolved = true
        _ = t1Readiness.acceptCapabilities(Self.defaultCapabilities)
        _ = t1Readiness.acceptIdentity(.t1Remote)
        identifiedModel = .t1Remote
        lifecycle = .ready(generationCounter)
        state = .ready(deviceName)
    }

    func simulateChromecastReadyStateForTesting(
        deviceName: String = "Chromecast Remote",
        nowUptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.nowUptime = nowUptime
        shouldRun = true
        generationCounter &+= 1
        googleCandidate = true
        capabilities = Self.defaultCapabilities
        capabilitiesConfirmed = true
        modelFormatResolved = true
        _ = googleReadiness.acceptCapabilities(Self.defaultCapabilities)
        _ = googleReadiness.acceptIdentity(.chromecast)
        identifiedModel = .chromecastVoiceRemote
        lifecycle = .ready(generationCounter)
        state = .ready(deviceName)
    }

    func simulateControlPacketForTesting(_ data: Data) {
        handleControl(data)
    }

    func simulateAudioPacketForTesting(_ data: Data) {
        handleAudio(data)
    }

    func simulateBatteryPollingScheduleDuringSuspensionForTesting() {
        simulateReadyStateForTesting()
        batteryLevelNeedsPolling = true
        setSystemSuspended(true, reason: "test")
        if let generation = currentGeneration() {
            updateBatteryPollingSchedule(generation: generation)
        }
    }
#endif

    let serviceUUID = CBUUID(string: ATVVProtocol.serviceUUID)
    let transmitUUID = CBUUID(string: ATVVProtocol.transmitUUID)
    let audioUUID = CBUUID(string: ATVVProtocol.audioUUID)
    let controlUUID = CBUUID(string: ATVVProtocol.controlUUID)
    let batteryServiceUUID = CBUUID(string: "180F")
    let batteryLevelUUID = CBUUID(string: "2A19")
    let batteryLevelStatusUUID = CBUUID(string: "2BED")
    let deviceInformationServiceUUID = CBUUID(string: "180A")
    let modelNumberUUID = CBUUID(string: "2A24")
    let pnpIDUUID = CBUUID(string: "2A50")
    let firmwareRevisionUUID = CBUUID(string: "2A26")
    let hardwareRevisionUUID = CBUUID(string: "2A27")

    var deviceIdentifier: UUID? {
        peripheral?.identifier ?? targetIdentifier
    }

    /// Pin a discovery bridge to its verified device before it becomes a registered bridge.
    /// This identity survives peripheral teardown and must bypass discovery exclusions.
    @discardableResult
    func bindVerifiedIdentity(_ identifier: UUID) -> Bool {
        guard targetIdentifier == nil || targetIdentifier == identifier else { return false }
        targetIdentifier = identifier
        return true
    }

    func acceptsCandidateIdentifier(_ identifier: UUID) -> Bool {
        guard !rejectedIdentifiers.contains(identifier) else { return false }
        if let targetIdentifier { return identifier == targetIdentifier }
        return !excludedIdentifiers().contains(identifier)
    }

    /// Refresh the system snapshot without changing the bridge's connection or audio state.
    func currentSystemDeviceName() -> String? {
        guard shouldRun, let central, central.state == .poweredOn,
              let peripheral, case .ready = lifecycle
        else { return nil }
        return central.retrieveConnectedPeripherals(withServices: [serviceUUID])
            .first(where: { $0.identifier == peripheral.identifier })?.name
    }

    var state: BluetoothBridgeState = .stopped {
        didSet {
            guard oldValue != state else { return }
            delegate?.bluetoothBridge(self, didChange: state)
        }
    }

    init(
        settings: AppSettings,
        delegate: BluetoothRemoteBridgeDelegate,
        targetIdentifier: UUID? = nil,
        allowsG9N9N: Bool = false,
        allowsT1Remote: Bool = false,
        adoptUnidentifiedATVVAsT1: @escaping () -> Bool = { false },
        audioPipeline: BluetoothAudioPipeline = BluetoothAudioPipeline(),
        voiceDiagnosticLogger: @escaping (String) -> Void = { AppLogger.shared.write($0) },
        scheduleMicrophoneClose: @escaping OperationScheduler = ScheduledOperation.mainQueue,
        excludedIdentifiers: @escaping () -> Set<UUID> = { [] },
        scheduleReconnect: @escaping (TimeInterval, DispatchWorkItem) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    ) {
        self.settings = settings
        self.audioDecoder = audioPipeline
        self.voiceDiagnosticLogger = voiceDiagnosticLogger
        self.scheduleMicrophoneClose = scheduleMicrophoneClose
        self.allowsG9N9N = allowsG9N9N
        self.allowsT1Remote = allowsT1Remote
        self.adoptUnidentifiedATVVAsT1 = adoptUnidentifiedATVVAsT1
        self.delegate = delegate
        self.targetIdentifier = targetIdentifier
        self.excludedIdentifiers = excludedIdentifiers
        self.scheduleReconnect = scheduleReconnect
        super.init()
    }

    isolated deinit {
        // stop() publishes state and requires a live owner. Destruction releases
        // resources directly and never queues work capturing this dying bridge.
        reconnectWorkItem?.cancel()
        connectionTimeoutWorkItem?.cancel()
        initializationTimeoutWorkItem?.cancel()
        batteryRefreshWorkItem?.cancel()
        microphoneKeepalive?.cancel()
        streamStopWatchdog?.cancel()
        scanWatchdog.cancel()
        reconnectWakeMonitor.cancel()
        disconnectWatchdog.cancel()
        if let token = scanSubscription {
            SharedBluetoothScanner.shared.unsubscribe(token)
        }
        peripheral?.delegate = nil
        central?.delegate = nil
        if let central, let peripheral, peripheral.state != .disconnected {
            central.cancelPeripheralConnection(peripheral)
        }
    }

    func start() {
        shouldRun = true
        reconnectWorkItem?.cancel()
        reconnectPolicy.reset()
        guard !systemSuspension.isSuspended else {
            systemSuspension.markConnectionCycleNeeded()
            AppLogger.shared.write(
                "BLE SYSTEM_SUSPENSION phase=deferred result=paused reason=bridge_start"
            )
            return
        }
        beginConnectionCycle()
    }

    func stop() {
        shouldRun = false
        reconnectWorkItem?.cancel()
        stopBatteryPolling(reason: "bridge_stopped")
        reconnectPolicy.reset()
        stopScan()
        closeMicrophoneIfNeeded()
        resetSession(reason: .bridgeStopped)
        if let central, let peripheral, peripheral.state != .disconnected {
            central.cancelPeripheralConnection(peripheral)
        }
        // Do not depend on a disconnect callback after powered-off or teardown.
        finishAttempt(reconnectAfter: nil)
        state = .stopped
    }

    func reconnectNow() {
        guard shouldRun else { return }
        guard !systemSuspension.isSuspended else {
            systemSuspension.markConnectionCycleNeeded()
            AppLogger.shared.write(
                "BLE SYSTEM_SUSPENSION phase=deferred result=paused reason=reconnect_requested"
            )
            return
        }
        _ = systemSuspension.consumeConnectionCycleNeeded()
        reconnectWorkItem?.cancel()
        reconnectPolicy.reset()
        stopScan()
        if let central, let peripheral, peripheral.state != .disconnected {
            requestedReconnectDelay = 0.1
            lifecycle = .disconnecting(lifecycle.generation ?? generationCounter)
            publishReconnectingState()
            central.cancelPeripheralConnection(peripheral)
            startDisconnectTimeout()
            return
        }
        finishAttempt(reconnectAfter: 0.1)
    }

    /// 主动重建本桥的语音链路，重新从发现/连接开始。
    ///
    /// `reason` 是稳定枚举（`system_wake` / `session_activated`），只用于把「系统唤醒」和
    /// 「会话切回前台」两种触发区分开，不参与状态机判定。
    func recoverVoiceLink(reason: String) {
        guard shouldRun else {
            AppLogger.shared.write("BLE RECOVERY phase=skipped cause=bridge_stopped trigger=\(reason)")
            return
        }
        guard !systemSuspension.isSuspended else {
            systemSuspension.markConnectionCycleNeeded()
            AppLogger.shared.write(
                "BLE RECOVERY phase=deferred cause=system_suspended trigger=\(reason)"
            )
            return
        }
        let centralState = central.map { String($0.state.rawValue) } ?? "none"
        AppLogger.shared.write(
            "BLE RECOVERY phase=requested trigger=\(reason) state=\(state.logDescription) " +
                "lifecycle=\(String(describing: lifecycle)) " +
                "central_state=\(centralState) " +
                "generation=\(generationCounter)"
        )
        reconnectNow()
    }

    func setSystemSuspended(_ suspended: Bool, reason: String) {
        if suspended {
            guard systemSuspension.suspend(phase: lifecycle) else { return }
            stopBatteryPolling(reason: "system_suspended")
            stopScan()
            if !lifecycle.isReady {
                disconnectWatchdog.cancel()
                if let central,
                   let peripheral,
                   peripheral.state != .disconnected {
                    requestedReconnectDelay = nil
                    lifecycle = .disconnecting(lifecycle.generation ?? generationCounter)
                    central.cancelPeripheralConnection(peripheral)
                }
            }
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            connectionTimeoutWorkItem?.cancel()
            connectionTimeoutWorkItem = nil
            initializationTimeoutWorkItem?.cancel()
            initializationTimeoutWorkItem = nil
            AppLogger.shared.write(
                "BLE SYSTEM_SUSPENSION phase=started result=paused reason=\(reason) " +
                    "lifecycle=\(String(describing: lifecycle)) " +
                    "ready_preserved=\(lifecycle.isReady)"
            )
            return
        }

        guard systemSuspension.resume() else { return }
        if let generation = currentGeneration(), lifecycle.isReady {
            updateBatteryPollingSchedule(generation: generation)
        }
        AppLogger.shared.write(
            "BLE SYSTEM_SUSPENSION phase=completed result=resumed reason=\(reason) " +
                "connection_cycle_needed=\(systemSuspension.connectionCycleNeeded)"
        )
    }

    func resumeConnectionCycleIfNeeded(reason: String) {
        guard shouldRun, !lifecycle.isReady else { return }
        guard systemSuspension.consumeConnectionCycleNeeded() else { return }
        AppLogger.shared.write(
            "BLE SYSTEM_SUSPENSION phase=recovering result=requested reason=\(reason) " +
                "lifecycle=\(String(describing: lifecycle))"
        )
        reconnectNow()
    }
}
