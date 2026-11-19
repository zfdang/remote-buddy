import CoreBluetooth
import Foundation

extension BluetoothRemoteBridge {
    func stopScan() {
        scanWatchdog.cancel()
        reconnectWakeMonitor.cancel()
        if let scanSubscription {
            MainActor.assumeIsolated { SharedBluetoothScanner.shared.unsubscribe(scanSubscription) }
        }
        scanSubscription = nil
    }

    var canRecoverRemoteWake: Bool {
        targetIdentifier != nil && BluetoothReconnectWakePolicy.canRecover(
            phase: lifecycle, shouldRun: shouldRun, suspended: systemSuspension.isSuspended
        )
    }

    /// Called only for activity routed to this saved remote's HID profile.
    func recoverAfterRemoteActivity(reason: String) {
        guard canRecoverRemoteWake, central?.state == .poweredOn else { return }
        AppLogger.shared.write("BLE WAKE RECOVERY trigger=\(reason) phase=\(lifecycle) result=retry_now")
        remoteWakeStartedAt = ProcessInfo.processInfo.systemUptime
        reconnectPolicy.reset()
        startFreshConnectionCycle()
    }

    /// Recreate the central and proxy generation even when the system already
    /// owns the connection: the same CBPeripheral object can survive a retry.
    func recoverSystemConnectedRemote(reason: String) {
        guard canRecoverRemoteWake, let central, central.state == .poweredOn,
              let targetIdentifier,
              let candidate = central.retrieveConnectedPeripherals(withServices: [serviceUUID])
                .first(where: { $0.identifier == targetIdentifier }),
              acceptsCandidateIdentifier(candidate.identifier) else { return }
        let decision = VoiceRemoteAdmission.decide(identifier: candidate.identifier,
            targetIdentifier: targetIdentifier, advertisesVoiceService: true,
            name: candidate.name, advertisedName: nil, allowsG9N9N: allowsG9N9N,
            allowsT1Remote: allowsT1Remote, adoptUnidentifiedATVVAsT1: adoptUnidentifiedATVVAsT1())
        guard decision.isAdopted else {
            reject(candidate, reason: decision.logReason, source: "wake_system_connected")
            return
        }
        AppLogger.shared.write("BLE WAKE RECOVERY trigger=\(reason) phase=\(lifecycle) result=system_connected")
        remoteWakeStartedAt = ProcessInfo.processInfo.systemUptime
        reconnectPolicy.reset()
        startFreshConnectionCycle()
    }

    func monitorRemoteWake() {
        guard canRecoverRemoteWake else { return }
        let generation = lifecycle.generation
        reconnectWakeMonitor.arm(isCurrent: { [weak self] in
            guard let self else { return false }
            return self.canRecoverRemoteWake && self.lifecycle.generation == generation
        }, checkConnected: { [weak self] in
            self?.recoverSystemConnectedRemote(reason: "system_connected_poll")
        })
    }

    func finishRemoteWakeRecovery(result: String) {
        guard let startedAt = remoteWakeStartedAt else { return }
        remoteWakeStartedAt = nil
        let elapsed = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
        AppLogger.shared.write("BLE WAKE RECOVERY phase=completed result=\(result) elapsed_ms=\(elapsed)")
    }

    func beginConnectionCycle() {
        guard shouldRun else { return }
        guard !systemSuspension.isSuspended else {
            systemSuspension.markConnectionCycleNeeded()
            return
        }
        guard central == nil else { return }
        generationCounter &+= 1
        let generation = generationCounter
        lifecycle = .scanning(generation)
        let manager = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )
        central = manager
        centralGeneration = generation
        if manager.state == .poweredOn {
            discoverOrScan(using: manager, generation: generation)
        }
    }

    func discoverOrScan(using central: CBCentralManager, generation: UInt64) {
        guard shouldRun,
              !systemSuspension.isSuspended,
              self.central === central,
              lifecycle == .scanning(generation),
              central.state == .poweredOn
        else { return }
        resetPeripheral()

        BluetoothDiscoverySequence.run(
            cachedTarget: { () -> CBPeripheral? in
                guard reconnectPolicy.nextCachedTargetRetrievalPermission(),
                      let identifier = targetIdentifier else { return nil }
                return central.retrievePeripherals(withIdentifiers: [identifier]).first
            },
            connectedCandidates: {
                let candidates = central.retrieveConnectedPeripherals(withServices: [serviceUUID])
                    .filter { acceptsCandidateIdentifier($0.identifier) }
                if !candidates.isEmpty {
                    AppLogger.shared.write(
                        "BLE SYSTEM CONNECTED CANDIDATES count=\(candidates.count) names=" +
                            candidates.map { DiagnosticRedactor.redactedDeviceName($0.name) }.joined(separator: ",")
                    )
                }
                return candidates
            },
            adopt: { candidate, source in
                guard acceptsCandidateIdentifier(candidate.identifier) else { return false }
                return adopt(
                    candidate,
                    using: central,
                    generation: generation,
                    source: source.rawValue,
                    advertisesVoiceService: true,
                    advertisedName: nil,
                    usesCachedTarget: source == .cachedTarget
                )
            },
            scan: {
                let wasScanning = scanSubscription != nil
                state = .scanning
                stopScan()
                scanSubscription = MainActor.assumeIsolated {
                    SharedBluetoothScanner.shared.subscribe { [weak self, weak central] advertisement in
                        guard let self, let central, self.central === central,
                              !self.systemSuspension.isSuspended,
                              self.lifecycle == .scanning(generation), self.peripheral == nil,
                              self.acceptsCandidateIdentifier(advertisement.identifier) else { return }
                        let serviceMatch = (advertisement.data[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
                            .contains(self.serviceUUID) == true
                        let decision = VoiceRemoteAdmission.decide(identifier: advertisement.identifier,
                            targetIdentifier: self.targetIdentifier, advertisesVoiceService: serviceMatch,
                            name: advertisement.name, advertisedName: advertisement.name,
                            allowsG9N9N: self.allowsG9N9N,
                            allowsT1Remote: self.allowsT1Remote,
                            adoptUnidentifiedATVVAsT1: self.adoptUnidentifiedATVVAsT1())
                        switch decision {
                        case .adoptSavedIdentity, .adoptRecognizedName: break
                        default: return
                        }
                        guard let candidate = central.retrievePeripherals(withIdentifiers: [advertisement.identifier]).first else { return }
                        _ = self.adopt(candidate, using: central, generation: generation, source: "shared_scan",
                            advertisesVoiceService: serviceMatch, advertisedName: advertisement.name)
                    }
                }
                scanWatchdog.arm(isCurrent: { [weak self, weak central] in
                    guard let self, let central else { return false }
                    return self.shouldRun && !self.systemSuspension.isSuspended &&
                        self.central === central && self.lifecycle == .scanning(generation) &&
                        self.peripheral == nil && central.state == .poweredOn
                }, rediscover: { [weak self, weak central] in
                    guard let self, let central else { return }
                    self.discoverOrScan(using: central, generation: generation)
                })
                if !wasScanning {
                    AppLogger.shared.write("BLE SCANNING")
                }
                monitorRemoteWake()
            }
        )
    }

    /// 三条发现路径——已保存标识、系统已连接设备、扫描广播——**必须共用这一份判定**。
    /// 分成三份写就会出现「某条路径漏掉/误收」这类只在特定配对状态下复现的缺陷。
    @discardableResult
    func adopt(
        _ candidate: CBPeripheral,
        using central: CBCentralManager,
        generation: UInt64,
        source: String,
        advertisesVoiceService: Bool,
        advertisedName: String?,
        usesCachedTarget: Bool = false
    ) -> Bool {
        let decision = VoiceRemoteAdmission.decide(
            identifier: candidate.identifier,
            targetIdentifier: targetIdentifier,
            advertisesVoiceService: advertisesVoiceService,
            name: candidate.name,
            advertisedName: advertisedName,
            allowsG9N9N: allowsG9N9N,
            allowsT1Remote: allowsT1Remote,
            adoptUnidentifiedATVVAsT1: adoptUnidentifiedATVVAsT1()
        )
        switch decision {
        case .adoptSavedIdentity, .adoptRecognizedName:
            let cachedProfile = settings.remoteDeviceProfiles.first {
                $0.bluetoothIdentifier == candidate.identifier
            }
            let resolvedName = VoiceRemoteAdmission.resolvedName(
                advertisedName: advertisedName,
                peripheralName: candidate.name
            )
            googleCandidate = allowsG9N9N && (
                G9N9NProtocol.isCandidateName(resolvedName) ||
                cachedProfile?.model.isChromecastRemote == true
            )
            t1Candidate = !googleCandidate && allowsT1Remote && (
                T1RemoteProtocol.isCandidateName(resolvedName) ||
                cachedProfile?.model.isT1Remote == true ||
                (adoptUnidentifiedATVVAsT1() &&
                    XiaomiVoiceRemoteNameMatcher.recognizedName(resolvedName) == nil)
            )
            connect(
                candidate,
                using: central,
                generation: generation,
                source: source,
                usesCachedTarget: usesCachedTarget
            )
            return true
        case .ignore:
            return false
        case .rejectForeignProduct, .rejectUnrecognizedName, .rejectUnnamed:
            reject(candidate, reason: decision.logReason, source: source)
            return false
        }
    }

    /// 明确记录并拒绝一台设备，此后本桥不再尝试连接它。
    ///
    /// 必须是显式日志：设备名对不上、名字不认识、根本没拿到名字，这三种情况在没有原因字段的
    /// 日志里长得完全一样，无法二分「为什么这台遥控器没被接管」。
    func reject(_ candidate: CBPeripheral, reason: String, source: String) {
        guard rejectedIdentifiers.insert(candidate.identifier).inserted else { return }
        AppLogger.shared.write(
            "BLE REJECTED reason=\(reason) source=\(source) name=\(DiagnosticRedactor.redactedDeviceName(candidate.name))"
        )
    }

    func connect(
        _ candidate: CBPeripheral,
        using central: CBCentralManager,
        generation: UInt64,
        source: String,
        usesCachedTarget: Bool = false
    ) {
        guard shouldRun,
              !systemSuspension.isSuspended,
              self.central === central,
              peripheral == nil,
              lifecycle == .scanning(generation)
        else { return }
        stopScan()
        peripheral = candidate
        currentAttemptUsesCachedTarget = usesCachedTarget
        let proxy = BluetoothRemotePeripheralDelegateProxy(generation: generation, owner: self)
        peripheralDelegateProxy = proxy
        candidate.delegate = proxy
        lifecycle = .connecting(generation)
        state = .connecting
        startConnectionTimeout(generation: generation)
        central.connect(candidate, options: nil)
        AppLogger.shared.write("BLE CONNECTING source=\(source) name=\(DiagnosticRedactor.redactedDeviceName(candidate.name))")
    }

    func resetPeripheral(reason: BluetoothVoiceStopReason = .peripheralReset) {
        acknowledgedWrites.reset()
        unacknowledgedWrites.reset()
        disconnectWatchdog.cancel()
        stopBatteryPolling(reason: "peripheral_reset")
        deviceInformation = RemoteDeviceInformation()
        peripheral?.delegate = nil
        peripheral = nil
        peripheralDelegateProxy = nil
        requestedReconnectDelay = nil
        transmitCharacteristic = nil
        audioCharacteristic = nil
        controlCharacteristic = nil
        batteryCharacteristic = nil
        batteryStatusCharacteristic = nil
        batteryLevelNeedsPolling = false
        batteryStatusNeedsPolling = false
        hasObservedBatteryLevel = false
        lastObservedBatteryLevel = nil
        hasObservedPowerState = false
        lastObservedPowerState = nil
        subscribedUUIDs.removeAll()
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
        initializationTimeoutWorkItem?.cancel()
        initializationTimeoutWorkItem = nil
        capabilitiesRequested = false
        capabilitiesConfirmed = false
        modelFormatResolved = false
        googleReadiness = G9N9NReadiness()
        t1Readiness = T1RemoteReadiness()
        t1Candidate = false
        identifiedModel = nil
        reportedHIDIdentity = nil
        capabilities = Self.defaultCapabilities
        currentAttemptUsesCachedTarget = false
        resetSession(reason: reason)
        audioDecoder.reset(peripheral: true)
    }

    func isCurrent(_ candidate: CBPeripheral) -> Bool {
        guard let peripheral else { return false }
        return peripheral === candidate
    }

    func currentGeneration() -> UInt64? {
        lifecycle.generation
    }

    func startInitializationTimeout(generation: UInt64) {
        initializationTimeoutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.shouldRun,
                  !self.systemSuspension.isSuspended,
                  self.currentGeneration() == generation,
                  self.lifecycle == .discovering(generation) ||
                    self.lifecycle == .awaitingCapabilities(generation)
            else { return }
            let timeoutKey: String
            if self.googleCandidate && !self.googleReadiness.identityConfirmed {
                timeoutKey = "google.remote.unconfirmed_identity"
            } else if self.t1Candidate && self.capabilitiesConfirmed && !self.t1Readiness.identityConfirmed {
                timeoutKey = "t1.remote.unconfirmed_identity"
            } else {
                timeoutKey = "connection.error.voice_service_timeout"
            }
            self.failInitialization(LocalizedMessage(timeoutKey))
        }
        initializationTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    func startDisconnectTimeout() {
        guard case let .disconnecting(generation) = lifecycle else { return }
        disconnectWatchdog.arm(isCurrent: { [weak self] in
            self?.shouldRun == true && self?.lifecycle == .disconnecting(generation)
        }, onTimeout: { [weak self] in
            guard let self else { return }
            AppLogger.shared.write("BLE DISCONNECT TIMEOUT")
            self.finishAttempt(reconnectAfter: self.requestedReconnectDelay ?? 0.5)
        })
    }

    func startConnectionTimeout(generation: UInt64) {
        connectionTimeoutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.shouldRun,
                  !self.systemSuspension.isSuspended,
                  self.currentGeneration() == generation,
                  self.lifecycle == .connecting(generation)
            else { return }
            AppLogger.shared.write("BLE CONNECT TIMEOUT")
            self.connectionTimeoutWorkItem = nil
            self.scheduleReconnect(bypassCachedTarget: self.currentAttemptUsesCachedTarget)
        }
        connectionTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    func publishReconnectingState() {
        // Keep the actionable failure visible until the next connection attempt starts.
        if case .failed = state { return }
        state = .reconnecting
    }

    func scheduleReconnect(bypassCachedTarget: Bool = false) {
        guard shouldRun else { return }
        guard !systemSuspension.isSuspended else {
            disconnectWatchdog.cancel()
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            if let central, let peripheral, peripheral.state != .disconnected {
                central.cancelPeripheralConnection(peripheral)
            }
            finishAttempt(reconnectAfter: 0)
            return
        }
        reconnectWorkItem?.cancel()
        publishReconnectingState()
        // Only count failures toward the blind-cached pause budget when the attempt itself came from `.cachedTarget`.
        let delay = nextAutomaticReconnectDelay(
            bypassCachedTarget: bypassCachedTarget || currentAttemptUsesCachedTarget,
            failedCachedTargetAttempt: currentAttemptUsesCachedTarget
        )
        if let central, let peripheral, peripheral.state != .disconnected {
            requestedReconnectDelay = delay
            lifecycle = .disconnecting(lifecycle.generation ?? generationCounter)
            central.cancelPeripheralConnection(peripheral)
            startDisconnectTimeout()
            return
        }
        finishAttempt(reconnectAfter: delay)
    }

    func nextAutomaticReconnectDelay(
        bypassCachedTarget: Bool,
        failedCachedTargetAttempt: Bool
    ) -> TimeInterval {
        let delay = reconnectPolicy.nextAutomaticDelay(
            bypassCachedTarget: bypassCachedTarget,
            failedCachedTargetAttempt: failedCachedTargetAttempt,
            jitterUnit: Double.random(in: 0 ... 1)
        )
        let cachedIdentifierBypassed = targetIdentifier != nil &&
            !reconnectPolicy.allowsCachedTargetRetrieval
        let cachedPaused = targetIdentifier != nil &&
            reconnectPolicy.cachedTargetFailureCount >= BluetoothReconnectPolicy.maximumCachedTargetFailures
        AppLogger.shared.write(
            "BLE RECONNECT scheduled failure_count=\(reconnectPolicy.consecutiveFailureCount) " +
                "delay_ms=\(Int((delay * 1_000).rounded())) " +
                "cached_identifier_bypassed=\(cachedIdentifierBypassed) " +
                "cached_failures=\(reconnectPolicy.cachedTargetFailureCount) " +
                "cached_paused=\(cachedPaused)"
        )
        return delay
    }

    func reconnectDelayAfterFailure(bypassCachedTarget: Bool) -> TimeInterval? {
        guard shouldRun else { return nil }
        guard !systemSuspension.isSuspended else {
            systemSuspension.markConnectionCycleNeeded()
            return 0
        }
        return requestedReconnectDelay ?? nextAutomaticReconnectDelay(
            bypassCachedTarget: bypassCachedTarget,
            failedCachedTargetAttempt: currentAttemptUsesCachedTarget
        )
    }

    func finishAttempt(reconnectAfter delay: TimeInterval?, stopReason: BluetoothVoiceStopReason = .peripheralReset) {
        finishRemoteWakeRecovery(result: "interrupted")
        let finishedGeneration = lifecycle.generation ?? generationCounter
        stopScan()
        requestedReconnectDelay = nil
        resetPeripheral(reason: stopReason)

        guard shouldRun, let delay else {
            central?.delegate = nil
            central = nil
            centralGeneration = nil
            lifecycle = .stopped
            return
        }

        guard !systemSuspension.isSuspended else {
            central?.delegate = nil
            central = nil
            centralGeneration = nil
            systemSuspension.markConnectionCycleNeeded()
            lifecycle = .stopped
            publishReconnectingState()
            AppLogger.shared.write(
                "BLE RECONNECT deferred reason=system_suspended"
            )
            return
        }

        publishReconnectingState()
        lifecycle = .waitingReconnect(finishedGeneration)
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.shouldRun,
                  !self.systemSuspension.isSuspended,
                  self.lifecycle == .waitingReconnect(finishedGeneration)
            else { return }
            self.reconnectWorkItem = nil
            self.startFreshConnectionCycle()
        }
        reconnectWorkItem = work
        scheduleReconnect(delay, work)
        monitorRemoteWake()
    }
}
