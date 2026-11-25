import CoreBluetooth
import Foundation

@MainActor
final class BluetoothRemotePeripheralDelegateProxy: NSObject, @preconcurrency CBPeripheralDelegate {
    let generation: UInt64
    weak var owner: BluetoothRemoteBridge?

    init(generation: UInt64, owner: BluetoothRemoteBridge) {
        self.generation = generation
        self.owner = owner
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        owner?.handleWriteResponse(peripheral: peripheral, generation: generation,
                                   characteristic: characteristic, error: error)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        owner?.handleWriteReady(peripheral: peripheral, generation: generation)
    }

    func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
        owner?.handleNameUpdate(peripheral: peripheral, generation: generation)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        owner?.handleDiscoveredServices(
            peripheral: peripheral,
            generation: generation,
            error: error
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        owner?.handleDiscoveredCharacteristics(
            peripheral: peripheral,
            generation: generation,
            service: service,
            error: error
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        owner?.handleNotificationState(
            peripheral: peripheral,
            generation: generation,
            characteristic: characteristic,
            error: error
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        owner?.handleCharacteristicValue(
            peripheral: peripheral,
            generation: generation,
            characteristic: characteristic,
            error: error
        )
    }
}

extension BluetoothRemoteBridge: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard self.central === central, let generation = centralGeneration else { return }
        AppLogger.shared.write(
            "BLE CENTRAL state=\(central.state.rawValue) " +
                "lifecycle=\(String(describing: lifecycle)) " +
                "generation=\(generation)"
        )
        switch central.state {
        case .poweredOn:
            applyCentralRecovery(
                .poweredOn,
                central: central,
                generation: generation
            )
        case .poweredOff:
            applyCentralRecovery(
                .poweredOff,
                central: central,
                generation: generation
            )
            resetPeripheral(reason: .bluetoothPoweredOff)
            state = .bluetoothUnavailable(LocalizedMessage(BluetoothStatusKeys.off))
        case .unauthorized:
            applyCentralRecovery(
                .unauthorized,
                central: central,
                generation: generation
            )
            state = .bluetoothUnavailable(LocalizedMessage(BluetoothStatusKeys.permissionDenied))
        case .unsupported:
            applyCentralRecovery(
                .unsupported,
                central: central,
                generation: generation
            )
            state = .bluetoothUnavailable(LocalizedMessage(BluetoothStatusKeys.unsupported))
        case .resetting:
            applyCentralRecovery(
                .resetting,
                central: central,
                generation: generation
            )
            resetPeripheral(reason: .bluetoothResetting)
            state = .bluetoothUnavailable(LocalizedMessage("bluetooth.status.resetting"))
        case .unknown:
            state = .bluetoothUnavailable(LocalizedMessage("bluetooth.status.initializing"))
        @unknown default:
            state = .bluetoothUnavailable(LocalizedMessage(BluetoothStatusKeys.unavailable))
        }
    }

    func applyCentralRecoveryTransition(
        _ event: BluetoothCentralRecoveryEvent,
        generation: UInt64
    ) -> BluetoothCentralRecoveryTransition {
        let transition = BluetoothCentralRecoveryPolicy.transition(
            from: lifecycle,
            generation: generation,
            event: event,
            shouldRun: shouldRun
        )
        if transition.shouldCancelScheduledReconnect {
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
        }
        lifecycle = transition.phase
        if transition.shouldResetReconnectPolicy {
            reconnectPolicy.reset()
        }
        return transition
    }

    func applyCentralRecovery(
        _ event: BluetoothCentralRecoveryEvent,
        central: CBCentralManager,
        generation: UInt64
    ) {
        let transition = applyCentralRecoveryTransition(event, generation: generation)
        if transition.shouldReleaseCentral {
            resetPeripheral(reason: .centralReleased)
            stopScan()
            central.delegate = nil
            self.central = nil
            centralGeneration = nil
            lifecycle = .stopped
            return
        }
        guard !systemSuspension.isSuspended else {
            if transition.shouldStartFreshConnectionCycle || transition.shouldDiscover {
                systemSuspension.markConnectionCycleNeeded()
            }
            stopScan()
            return
        }
        if transition.shouldStartFreshConnectionCycle {
            startFreshConnectionCycle()
            return
        }
        if transition.shouldDiscover {
            discoverOrScan(using: central, generation: generation)
        }
    }

    func startFreshConnectionCycle() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        guard !systemSuspension.isSuspended else {
            systemSuspension.markConnectionCycleNeeded()
            stopScan()
            return
        }
        stopScan()
        central?.delegate = nil
        central = nil
        centralGeneration = nil
        lifecycle = .stopped
        beginConnectionCycle()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.central === central else { return }
        guard shouldRun else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        guard isCurrent(peripheral),
              let generation = centralGeneration,
              lifecycle.acceptsDidConnect(generation: generation)
        else { return }
        if VoiceRemoteAdmission.rejectsConnectedProduct(
            name: peripheral.name,
            allowsG9N9N: allowsG9N9N,
            allowsT1Remote: allowsT1Remote
        ) {
            reject(peripheral, reason: "foreign_product", source: "did_connect")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        guard !systemSuspension.isSuspended else {
            systemSuspension.markConnectionCycleNeeded()
            lifecycle = .disconnecting(generation)
            central.cancelPeripheralConnection(peripheral)
            AppLogger.shared.write("BLE CONNECT deferred reason=system_suspended")
            return
        }
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
        lifecycle = .discovering(generation)
        state = .discovering
        startInitializationTimeout(generation: generation)
        peripheral.discoverServices([
            serviceUUID,
            batteryServiceUUID,
            deviceInformationServiceUUID,
        ])
        AppLogger.shared.write("BLE CONNECTED name=\(DiagnosticRedactor.redactedDeviceName(peripheral.name))")
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard self.central === central,
              isCurrent(peripheral),
              let generation = centralGeneration,
              lifecycle.acceptsDidFailToConnect(generation: generation)
        else { return }
        AppLogger.shared.write(
            "BLE CONNECT FAILED " + AppLogger.optionalErrorFields(error)
        )
        let delay = reconnectDelayAfterFailure(
            bypassCachedTarget: currentAttemptUsesCachedTarget
        )
        finishAttempt(reconnectAfter: delay)
        if !shouldRun { state = .stopped }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard self.central === central,
              isCurrent(peripheral),
              let generation = centralGeneration,
              lifecycle.acceptsDisconnect(generation: generation)
        else { return }
        handleDisconnect(error: error)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        timestamp: CFAbsoluteTime,
        isReconnecting: Bool,
        error: Error?
    ) {
        guard self.central === central,
              isCurrent(peripheral),
              let generation = centralGeneration,
              lifecycle.acceptsDisconnect(generation: generation)
        else { return }
        handleDisconnect(error: error, isReconnecting: isReconnecting)
    }

    func handleDisconnect(error: Error?, isReconnecting: Bool? = nil) {
        let shouldBypassCachedTarget: Bool
        switch lifecycle {
        case .connecting, .discovering, .awaitingCapabilities:
            shouldBypassCachedTarget = true
        default:
            shouldBypassCachedTarget = false
        }
        AppLogger.shared.write(
            "BLE DISCONNECTED phase=\(lifecycle) is_reconnecting=\(isReconnecting.map(String.init) ?? "unknown") " +
                AppLogger.optionalErrorFields(error)
        )
        let delay = reconnectDelayAfterFailure(
            bypassCachedTarget: shouldBypassCachedTarget || currentAttemptUsesCachedTarget
        )
        finishAttempt(reconnectAfter: delay, stopReason: .disconnected)
        if !shouldRun { state = .stopped }
    }
}

extension BluetoothRemoteBridge {
    func handleNameUpdate(peripheral: CBPeripheral, generation: UInt64) {
        guard shouldRun, isCurrent(peripheral), lifecycle == .ready(generation) else { return }
        delegate?.bluetoothBridgeDeviceNameDidChange(self)
    }

    func handleDiscoveredServices(
        peripheral: CBPeripheral,
        generation: UInt64,
        error: Error?
    ) {
        guard shouldRun,
              !systemSuspension.isSuspended,
              isCurrent(peripheral),
              currentGeneration() == generation,
              lifecycle.acceptsInitializationCallback(generation: generation)
        else { return }
        if let error {
            if googleCandidate, G9N9NProtocol.requiresPairing(error) {
                failInitialization(LocalizedMessage("google.remote.pairing_required"))
                return
            }
            state = .failed(
                LocalizedMessage(
                    "connection.error.voice_service_discovery_failed",
                    arguments: [error.localizedDescription]
                )
            )
            scheduleReconnect(bypassCachedTarget: true)
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            state = .failed(LocalizedMessage("connection.error.voice_service_missing"))
            scheduleReconnect(bypassCachedTarget: true)
            return
        }
        peripheral.discoverCharacteristics(
            [transmitUUID, audioUUID, controlUUID],
            for: service
        )
        if let batteryService = peripheral.services?.first(where: { $0.uuid == batteryServiceUUID }) {
            peripheral.discoverCharacteristics(
                [batteryLevelUUID, batteryLevelStatusUUID],
                for: batteryService
            )
        }
        if let deviceInformationService = peripheral.services?.first(where: {
            $0.uuid == deviceInformationServiceUUID
        }) {
            peripheral.discoverCharacteristics([modelNumberUUID, pnpIDUUID, firmwareRevisionUUID, hardwareRevisionUUID], for: deviceInformationService)
        } else if googleCandidate {
            failInitialization(LocalizedMessage("google.remote.unconfirmed_identity"))
        } else {
            modelFormatResolved = true
            finishInitializationIfReady(generation: generation)
        }
    }

    func handleDiscoveredCharacteristics(
        peripheral: CBPeripheral,
        generation: UInt64,
        service: CBService,
        error: Error?
    ) {
        let isOptionalService = service.uuid == batteryServiceUUID ||
            service.uuid == deviceInformationServiceUUID
        guard shouldRun,
              (!systemSuspension.isSuspended || lifecycle.isReady),
              isCurrent(peripheral),
              currentGeneration() == generation,
              isOptionalService
                ? lifecycle.acceptsNotificationUpdate(generation: generation)
                : lifecycle.acceptsInitializationCallback(generation: generation)
        else { return }
        if service.uuid == batteryServiceUUID {
            if let error {
                AppLogger.shared.write(
                    "BLE BATTERY characteristic_discovery_failed " +
                        AppLogger.errorFields(error)
                )
                delegate?.bluetoothBridge(self, didUpdateBatteryLevel: nil)
                delegate?.bluetoothBridge(self, didUpdatePowerState: nil)
                return
            }
            guard let characteristics = service.characteristics else {
                delegate?.bluetoothBridge(self, didUpdateBatteryLevel: nil)
                delegate?.bluetoothBridge(self, didUpdatePowerState: nil)
                return
            }
            if let characteristic = characteristics.first(where: { $0.uuid == batteryLevelUUID }) {
                batteryCharacteristic = characteristic
                peripheral.readValue(for: characteristic)
                let supportsNotifications = characteristic.properties.contains(.notify) ||
                    characteristic.properties.contains(.indicate)
                batteryLevelNeedsPolling = BluetoothBatteryPollingPolicy.shouldPoll(
                    supportsNotifications: supportsNotifications,
                    isNotifying: characteristic.isNotifying
                )
                if supportsNotifications {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            } else {
                delegate?.bluetoothBridge(self, didUpdateBatteryLevel: nil)
            }
            if let characteristic = characteristics.first(where: { $0.uuid == batteryLevelStatusUUID }) {
                batteryStatusCharacteristic = characteristic
                peripheral.readValue(for: characteristic)
                let supportsNotifications = characteristic.properties.contains(.notify) ||
                    characteristic.properties.contains(.indicate)
                batteryStatusNeedsPolling = BluetoothBatteryPollingPolicy.shouldPoll(
                    supportsNotifications: supportsNotifications,
                    isNotifying: characteristic.isNotifying
                )
                if supportsNotifications {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            } else {
                delegate?.bluetoothBridge(self, didUpdatePowerState: nil)
            }
            updateBatteryPollingSchedule(generation: generation)
            return
        }
        if service.uuid == deviceInformationServiceUUID {
            if let error {
                if googleCandidate, G9N9NProtocol.requiresPairing(error) {
                    failInitialization(LocalizedMessage("google.remote.pairing_required"))
                    return
                }

                AppLogger.shared.write(
                    "BLE MODEL characteristic_discovery_failed " +
                        AppLogger.errorFields(error)
                )
                if googleCandidate {
                    failInitialization(LocalizedMessage("google.remote.unconfirmed_identity"))
                    return
                }
                modelFormatResolved = true
                finishInitializationIfReady(generation: generation)
                return
            }
            let characteristics = service.characteristics ?? []
            let hasModelNumber = characteristics.contains(where: { $0.uuid == modelNumberUUID })
            let hasPnPID = characteristics.contains(where: { $0.uuid == pnpIDUUID })
            if googleCandidate && !hasPnPID {
                failInitialization(LocalizedMessage("google.remote.unconfirmed_identity"))
                return
            }
            if !hasModelNumber && !googleCandidate {
                modelFormatResolved = true
                finishInitializationIfReady(generation: generation)
            }
            for characteristic in characteristics where
                characteristic.uuid == modelNumberUUID || characteristic.uuid == pnpIDUUID ||
                characteristic.uuid == firmwareRevisionUUID || characteristic.uuid == hardwareRevisionUUID {
                peripheral.readValue(for: characteristic)
            }
            return
        }
        if let error {
            if googleCandidate, G9N9NProtocol.requiresPairing(error) {
                failInitialization(LocalizedMessage("google.remote.pairing_required"))
                return
            }
            state = .failed(
                LocalizedMessage(
                    "connection.error.voice_channel_discovery_failed",
                    arguments: [error.localizedDescription]
                )
            )
            scheduleReconnect(bypassCachedTarget: true)
            return
        }
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case transmitUUID:
                transmitCharacteristic = characteristic
            case audioUUID:
                audioCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            case controlUUID:
                controlCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            default:
                continue
            }
        }
        guard transmitCharacteristic != nil,
              audioCharacteristic != nil,
              controlCharacteristic != nil
        else {
            state = .failed(LocalizedMessage("connection.error.voice_channel_incomplete"))
            scheduleReconnect(bypassCachedTarget: true)
            return
        }
        requestCapabilitiesIfPossible()
    }

    func handleNotificationState(
        peripheral: CBPeripheral,
        generation: UInt64,
        characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard shouldRun,
              (!systemSuspension.isSuspended || lifecycle.isReady),
              isCurrent(peripheral),
              currentGeneration() == generation,
              lifecycle.acceptsNotificationUpdate(generation: generation)
        else { return }
        let isOptionalCharacteristic = characteristic.uuid == batteryLevelUUID ||
            characteristic.uuid == batteryLevelStatusUUID
        if isOptionalCharacteristic {
            let supportsNotifications = characteristic.properties.contains(.notify) ||
                characteristic.properties.contains(.indicate)
            let needsPolling = BluetoothBatteryPollingPolicy.shouldPoll(
                supportsNotifications: supportsNotifications,
                isNotifying: error == nil && characteristic.isNotifying
            )
            if characteristic.uuid == batteryLevelUUID {
                batteryLevelNeedsPolling = needsPolling
            } else {
                batteryStatusNeedsPolling = needsPolling
            }
            if let error {
                AppLogger.shared.write(
                    "BLE BATTERY notification_failed uuid=\(characteristic.uuid.uuidString) " +
                        AppLogger.errorFields(error)
                )
            }
            updateBatteryPollingSchedule(generation: generation)
            return
        }
        if let error {
            if googleCandidate, G9N9NProtocol.requiresPairing(error) {
                failInitialization(LocalizedMessage("google.remote.pairing_required"))
                return
            }
            state = .failed(
                LocalizedMessage(
                    "connection.error.voice_channel_subscription_failed",
                    arguments: [error.localizedDescription]
                )
            )
            scheduleReconnect(bypassCachedTarget: true)
            return
        }
        guard characteristic.uuid == audioUUID || characteristic.uuid == controlUUID else {
            return
        }
        guard characteristic.isNotifying else {
            subscribedUUIDs.remove(characteristic.uuid)
            failInitialization(LocalizedMessage("connection.error.voice_channel_subscription_inactive"))
            return
        }
        subscribedUUIDs.insert(characteristic.uuid)
        requestCapabilitiesIfPossible()
    }

    func handleCharacteristicValue(
        peripheral: CBPeripheral,
        generation: UInt64,
        characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard shouldRun,
              isCurrent(peripheral),
              currentGeneration() == generation
        else { return }
        if let error {
            AppLogger.shared.write(
                "BLE GATT read_failed uuid=\(characteristic.uuid.uuidString) " + AppLogger.errorFields(error)
            )
            if googleCandidate, G9N9NProtocol.requiresPairing(error),
               characteristic.uuid == pnpIDUUID || characteristic.uuid == audioUUID || characteristic.uuid == controlUUID {
                failInitialization(LocalizedMessage("google.remote.pairing_required"))
                return
            }
            if characteristic.uuid == batteryLevelUUID {
                AppLogger.shared.write(
                    "BLE BATTERY read_failed " + AppLogger.errorFields(error)
                )
                hasObservedBatteryLevel = false
                lastObservedBatteryLevel = nil
                delegate?.bluetoothBridge(self, didUpdateBatteryLevel: nil)
            } else if characteristic.uuid == batteryLevelStatusUUID {
                AppLogger.shared.write(
                    "BLE POWER read_failed " + AppLogger.errorFields(error)
                )
                hasObservedPowerState = false
                lastObservedPowerState = nil
                delegate?.bluetoothBridge(self, didUpdatePowerState: nil)
            } else if characteristic.uuid == pnpIDUUID, googleCandidate {
                if G9N9NProtocol.requiresPairing(error) {
                    failInitialization(LocalizedMessage("google.remote.pairing_required"))
                    return
                }
                AppLogger.shared.write(
                    "BLE PNP G9N9N read_failed " + AppLogger.errorFields(error)
                )
                failInitialization(LocalizedMessage("google.remote.unconfirmed_identity"))
            } else if characteristic.uuid == pnpIDUUID, t1Candidate {
                AppLogger.shared.write(
                    "BLE PNP T1 read_failed " + AppLogger.errorFields(error)
                )
                failInitialization(LocalizedMessage("t1.remote.unconfirmed_identity"))
            } else if characteristic.uuid == modelNumberUUID {
                AppLogger.shared.write(
                    "BLE MODEL read_failed " + AppLogger.errorFields(error)
                )
                if !googleCandidate {
                    modelFormatResolved = true
                    finishInitializationIfReady(generation: generation)
                }
            }
            return
        }
        guard let data = characteristic.value else { return }
        if characteristic.uuid == pnpIDUUID {
            reportedHIDIdentity = RemoteHIDIdentity.fromPnP(data)
            deviceInformation.identity = reportedHIDIdentity
            deviceInformation.hidVersion = RemoteHIDIdentity.productVersionFromPnP(data) ?? deviceInformation.hidVersion
            AppLogger.shared.write("BLE PNP observed \(RemoteHIDIdentity.pnpLogFields(from: data))")
            if googleCandidate {
                guard googleReadiness.acceptIdentity(reportedHIDIdentity) else {
                    failInitialization(LocalizedMessage("google.remote.unconfirmed_identity"))
                    return
                }
                identifiedModel = .chromecastVoiceRemote
                delegate?.bluetoothBridge(self, didIdentifyRemoteModel: .chromecastVoiceRemote)
                finishInitializationIfReady(generation: generation)
            } else if allowsT1Remote, (t1Candidate || reportedHIDIdentity == .t1Remote) {
                let cachedProfile = settings.remoteDeviceProfiles.first {
                    $0.bluetoothIdentifier == peripheral.identifier
                }
                guard let identity = reportedHIDIdentity else {
                    AppLogger.shared.write("BLE PNP T1 identity_rejected")
                    failInitialization(LocalizedMessage("t1.remote.unconfirmed_identity"))
                    return
                }
                let allowCustomT1Identity = T1RemoteReadiness.shouldAllowCustomIdentity(
                    adoptUnidentifiedATVVAsT1: adoptUnidentifiedATVVAsT1(),
                    isTargetedPeripheral: targetIdentifier == peripheral.identifier,
                    savedModelIsT1Remote: cachedProfile?.model.isT1Remote == true,
                    savedCustomIdentity: cachedProfile?.compatibleHIDBinding?.identity,
                    reportedIdentity: identity
                )
                guard t1Readiness.acceptIdentity(identity, allowCustomIdentity: allowCustomT1Identity) else {
                    AppLogger.shared.write("BLE PNP T1 identity_rejected")
                    failInitialization(LocalizedMessage("t1.remote.unconfirmed_identity"))
                    return
                }
                t1Candidate = true
                identifiedModel = .t1Remote
                delegate?.bluetoothBridge(self, didIdentifyRemoteModel: .t1Remote)
                finishInitializationIfReady(generation: generation)
            }
            onHIDIdentityUpdate?()
            return
        }
        if characteristic.uuid == firmwareRevisionUUID {
            deviceInformation.firmwareRevision = RemoteDeviceInformation.deviceString(data)
            AppLogger.shared.write(RemoteDeviceInformation.firmwareLogLine(from: data))
            return
        }
        if characteristic.uuid == hardwareRevisionUUID {
            deviceInformation.hardwareRevision = RemoteDeviceInformation.deviceString(data)
            AppLogger.shared.write(RemoteDeviceInformation.hardwareLogLine(from: data))
            return
        }
        if characteristic.uuid == batteryLevelUUID {
            let level = data.first.map(Int.init)
            guard !hasObservedBatteryLevel || lastObservedBatteryLevel != level else { return }
            hasObservedBatteryLevel = true
            lastObservedBatteryLevel = level
            AppLogger.shared.write("BLE BATTERY level=\(level.map(String.init) ?? "unknown")")
            delegate?.bluetoothBridge(self, didUpdateBatteryLevel: level)
            return
        }
        if characteristic.uuid == batteryLevelStatusUUID {
            let powerState = RemotePowerState.decodeBatteryLevelStatus(data)
            guard !hasObservedPowerState || lastObservedPowerState != powerState else { return }
            hasObservedPowerState = true
            lastObservedPowerState = powerState
            AppLogger.shared.write(
                "BLE POWER state=\(powerState?.logValue ?? "unavailable")"
            )
            delegate?.bluetoothBridge(self, didUpdatePowerState: powerState)
            return
        }
        if characteristic.uuid == modelNumberUUID {
            deviceInformation.modelNumber = RemoteDeviceInformation.deviceString(data)
            guard let modelNumber = String(data: data, encoding: .utf8) else {
                AppLogger.shared.write("BLE MODEL unreadable")
                if !googleCandidate {
                    modelFormatResolved = true
                    finishInitializationIfReady(generation: generation)
                }
                return
            }
            let normalizedModelNumber = modelNumber.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if googleCandidate {
                AppLogger.shared.write("BLE MODEL observed modelNumber=\(normalizedModelNumber)")
                return
            }
            let identifiedCatalogModel = RemoteModel.identified(by: modelNumber)
            if let identifiedCatalogModel,
               !identifiedCatalogModel.isT1Remote,
               !identifiedCatalogModel.isChromecastRemote {
                t1Candidate = false
            }
            if t1Candidate {
                AppLogger.shared.write(
                    "BLE MODEL T1 observed modelNumber=\(DiagnosticRedactor.redactedDeviceName(normalizedModelNumber))"
                )
                modelFormatResolved = true
                finishInitializationIfReady(generation: generation)
                return
            }

            modelFormatResolved = true
            if let model = identifiedCatalogModel {
                // 原始型号串必须一起记：广播名与型号**不是**一一对应（本机这台广播名是
                // 「小米蓝牙语音遥控器」，DIS 报的却是 RC003），只有原始串能支撑型号目录。
                AppLogger.shared.write(
                    "BLE MODEL identified=\(model.rawValue) modelNumber=\(normalizedModelNumber)"
                )
                identifiedModel = model
                delegate?.bluetoothBridge(self, didIdentifyRemoteModel: model)
            } else {
                AppLogger.shared.write("BLE MODEL unrecognized modelNumber=\(normalizedModelNumber)")
            }
            finishInitializationIfReady(generation: generation)
            return
        }
        if characteristic.uuid == controlUUID {
            guard lifecycle.acceptsCapabilities(generation: generation) ||
                    lifecycle.acceptsProtocolData(generation: generation)
            else { return }
            handleControl(data)
        } else if characteristic.uuid == audioUUID {
            guard lifecycle.acceptsProtocolData(generation: generation) else { return }
            handleAudio(data)
        }
    }
}
