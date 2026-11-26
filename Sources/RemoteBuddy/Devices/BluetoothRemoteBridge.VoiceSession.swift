import CoreBluetooth
import Foundation

extension BluetoothRemoteBridge {
    @discardableResult
    func requestMicrophoneOpen() -> Bool {
        guard !systemSuspension.isSuspended else { return false }
        guard let generation = currentGeneration(),
              ATVVSessionGate.canOpenMicrophone(
                  phase: lifecycle,
                  generation: generation,
                  capabilitiesConfirmed: capabilitiesConfirmed,
                  sampleRate: capabilities.sampleRate,
                  microphoneClosePending: microphoneClosePending
              ),
              !microphoneOpened,
              !streaming,
              !microphoneClosePending
        else {
            AppLogger.shared.write("ATVV MIC_OPEN host_request_rejected")
            return false
        }
        guard write(ATVVProtocol.microphoneOpen(
            version: capabilities.version,
            codec: capabilities.selectedCodec
        )) else {
            AppLogger.shared.write("ATVV MIC_OPEN host_request_write_failed")
            return false
        }
        cancelledMicrophoneOpenAt = nil
        microphoneOpened = true
        AppLogger.shared.write("ATVV MIC_OPEN host_request")
        return true
    }

    @discardableResult
    func requestMicrophoneExtend() -> Bool {
        guard microphoneOpened,
              streaming,
              !microphoneClosePending,
              let command = ATVVProtocol.microphoneExtend(
                  version: capabilities.version,
                  sessionID: sessionID
              ),
              write(command)
        else {
            AppLogger.shared.write("ATVV MIC_EXTEND rejected session=\(sessionID)")
            return false
        }
        AppLogger.shared.write("ATVV MIC_EXTEND request session=\(sessionID)")
        return true
    }

    @discardableResult
    func requestMicrophoneClose() -> Bool {
        guard microphoneOpened || streaming || microphoneClosePending else { return true }
        localMicrophoneCloseRequested = true
        microphoneKeepalive?.cancel()
        microphoneKeepalive = nil
        let currentSession = sessionID
        let cancelledOpenAt = ATVVSessionGate.cancelledOpenUptime(
            microphoneOpened: microphoneOpened,
            streaming: streaming
        )
        let didWrite = write(ATVVProtocol.microphoneClose(
            version: capabilities.version,
            sessionID: currentSession
        ))
        if didWrite {
            microphoneOpened = false
            microphoneClosePending = false
            microphoneCloseSessionID = nil
            cancelMicrophoneCloseWatchdog()
            cancelledMicrophoneOpenAt = cancelledOpenAt
            if streaming {
                scheduleStreamStopWatchdog(for: currentSession)
            }
        } else {
            microphoneClosePending = true
            microphoneCloseSessionID = currentSession
            if cancelledMicrophoneOpenAt == nil {
                cancelledMicrophoneOpenAt = cancelledOpenAt
            }
            scheduleMicrophoneCloseWatchdog(for: currentSession)
            AppLogger.shared.write(
                "ATVV MIC_CLOSE write_failed session=\(currentSession) pending=true"
            )
        }
        AppLogger.shared.write(
            "ATVV MIC_CLOSE request session=\(currentSession) written=\(didWrite)"
        )
        return didWrite
    }

    func scheduleStreamStopWatchdog(for session: UInt8) {
        guard streamStopWatchdog == nil else { return }
        let generation = currentGeneration()
        let token = UUID()
        streamStopWatchdogToken = token
        streamStopWatchdog = scheduleMicrophoneClose(5) { [weak self] in
            guard let self,
                  self.streaming,
                  self.streamStopWatchdogToken == token,
                  self.currentGeneration() == generation,
                  self.sessionID == session
            else { return }
            AppLogger.shared.write("ATVV STREAM_STOP timeout reason=close_unacknowledged session=\(session)")
            self.handleRemoteStreamStop(reason: .closeUnacknowledged)
        }
    }

    func cancelStreamStopWatchdog() {
        streamStopWatchdogToken = nil
        streamStopWatchdog?.cancel()
        streamStopWatchdog = nil
    }

    func scheduleMicrophoneCloseWatchdog(for session: UInt8) {
        guard microphoneCloseWatchdog == nil else { return }
        let generation = currentGeneration()
        let token = UUID()
        microphoneCloseWatchdogToken = token
        microphoneCloseWatchdog = scheduleMicrophoneClose(5) { [weak self] in
            guard let self,
                  self.microphoneClosePending,
                  self.microphoneCloseWatchdogToken == token,
                  self.currentGeneration() == generation,
                  self.microphoneCloseSessionID == session
            else { return }
            AppLogger.shared.write("ATVV MIC_CLOSE timeout reason=close_retry_exhausted session=\(session)")
            self.microphoneOpened = false
            self.microphoneClosePending = false
            self.microphoneCloseSessionID = nil
            self.cancelMicrophoneCloseWatchdog()
            self.stopStreaming(reason: .closeRetryExhausted)
            self.scheduleReconnect()
        }
    }

    func cancelMicrophoneCloseWatchdog() {
        microphoneCloseWatchdogToken = nil
        microphoneCloseWatchdog?.cancel()
        microphoneCloseWatchdog = nil
    }

    func suspendVoiceTransferState() {
        recordStreamStop(reason: .systemSuspended)
        let needsReconnect = microphoneClosePending ||
            microphoneOpened ||
            acknowledgedWrites.hasPendingWork ||
            unacknowledgedWrites.hasPendingWork
        let wasStreaming = streaming
        let hadVoiceStartNotified = voiceStartNotified
        activeStreamSessionID = nil
        microphoneOpened = false
        audioDecoder.reset()
        if hadVoiceStartNotified {
            voiceStartNotified = false
            delegate?.bluetoothBridgeDidStopVoice(self)
        }
        if wasStreaming {
            lastStopAt = nowUptime()
        }
        cancelMicrophoneCloseWatchdog()
        cancelStreamStopWatchdog()
        microphoneKeepalive?.cancel()
        microphoneKeepalive = nil
        microphoneKeepaliveCount = 0
        microphoneClosePending = false
        microphoneCloseSessionID = nil
        acknowledgedWrites.reset()
        unacknowledgedWrites.reset()
        if needsReconnect, shouldRun {
            AppLogger.shared.write("ATVV MIC_CLOSE suspended_incomplete result=reconnect_needed")
            scheduleReconnect()
        }
    }

    func resetSession(reason: BluetoothVoiceStopReason) {
        recordStreamStop(reason: reason)
        cancelMicrophoneCloseWatchdog()
        cancelStreamStopWatchdog()
        microphoneClosePending = false
        microphoneCloseSessionID = nil
        microphoneKeepalive?.cancel()
        microphoneKeepalive = nil
        microphoneKeepaliveCount = 0
        audioDecoder.reset()
        if voiceStartNotified {
            voiceStartNotified = false
            delegate?.bluetoothBridgeDidStopVoice(self)
        }
        microphoneOpened = false
        cancelledMicrophoneOpenAt = nil
        sessionID = 0
        activeStreamSessionID = nil
        lastVoiceStartAt = nil
        lastVoiceStopAt = nil
    }

    static func controlWriteType(for properties: CBCharacteristicProperties) -> CBCharacteristicWriteType? {
        if properties.contains(.write) { return .withResponse }
        if properties.contains(.writeWithoutResponse) { return .withoutResponse }
        return nil
    }

    @discardableResult
    func write(_ data: Data) -> Bool {
#if DEBUG
        if let testingControlWriteHandler {
            return testingControlWriteHandler(data)
        }
#endif
        guard peripheral != nil, let transmitCharacteristic else { return false }
        guard let type = Self.controlWriteType(for: transmitCharacteristic.properties) else { return false }
        if type == .withResponse { return acknowledgedWrites.enqueue(data) }
        return unacknowledgedWrites.enqueue(data)
    }

    func handleWriteReady(peripheral: CBPeripheral, generation: UInt64) {
        guard shouldRun, isCurrent(peripheral), currentGeneration() == generation else { return }
        unacknowledgedWrites.pump()
        if microphoneClosePending, microphoneCloseSessionID == sessionID {
            _ = requestMicrophoneClose()
        }
    }

    func handleWriteResponse(peripheral: CBPeripheral, generation: UInt64,
                             characteristic: CBCharacteristic, error: Error?) {
        guard shouldRun, isCurrent(peripheral), currentGeneration() == generation,
              characteristic === transmitCharacteristic else { return }
        acknowledgedWrites.acknowledge(success: error == nil)
        if microphoneClosePending, microphoneCloseSessionID == sessionID {
            _ = requestMicrophoneClose()
        }
    }

    func closeMicrophoneIfNeeded() {
        _ = requestMicrophoneClose()
    }

    func requestCapabilitiesIfPossible() {
        guard let generation = currentGeneration(),
              lifecycle.acceptsInitializationCallback(generation: generation)
        else { return }
        guard transmitCharacteristic != nil,
              let audioCharacteristic,
              let controlCharacteristic,
              subscribedUUIDs.contains(audioCharacteristic.uuid),
              subscribedUUIDs.contains(controlCharacteristic.uuid),
              let peripheral
        else { return }
        guard !capabilitiesRequested else { return }
        if !write(ATVVProtocol.getCapabilitiesV10) {
            AppLogger.shared.write("ATVV CAPABILITIES write_failed")
            if googleCandidate {
                failInitialization(LocalizedMessage("google.remote.unconfirmed_identity"))
            } else {
                scheduleReconnect(bypassCachedTarget: currentAttemptUsesCachedTarget)
            }
            return
        }
        capabilitiesRequested = true
        lifecycle = .awaitingCapabilities(generation)
        state = .discovering
        AppLogger.shared.write("ATVV CAPABILITIES requested name=\(DiagnosticRedactor.redactedDeviceName(peripheral.name ?? "MI RC"))")
    }

    func handleControl(_ data: Data) {
        let bytes = Array(data)
        guard let opcode = bytes.first,
              let generation = currentGeneration()
        else { return }

        switch opcode {
        case 0x0B:
            guard lifecycle.acceptsCapabilities(generation: generation) else {
                AppLogger.shared.write("ATVV CAPS ignored_stale_phase")
                return
            }
            guard let parsed = ATVVCapabilities.parse(data, allowingLegacyLayout: !googleCandidate) else {
                failInitialization(LocalizedMessage("connection.error.invalid_voice_response"))
                return
            }
            if googleCandidate && !googleReadiness.acceptCapabilities(parsed) {
                rejectUnsupportedAudio(LocalizedMessage("google.remote.unsupported_protocol"))
                return
            }
            if t1Candidate && !t1Readiness.acceptCapabilities(parsed) {
                rejectUnsupportedAudio(LocalizedMessage("connection.error.unsupported_16khz_codec"))
                return
            }
            deviceInformation.capabilities = parsed
            capabilities = parsed
            AppLogger.shared.write(
                "ATVV CAPS version=\(parsed.version) codec=\(parsed.selectedCodec) frame=\(parsed.frameSize)"
            )
            if !ATVVProtocol.supportsAudio(sampleRate: parsed.sampleRate) ||
                !ATVVProtocol.supportsFrameSize(parsed.frameSize) {
                rejectUnsupportedAudio(LocalizedMessage("connection.error.unsupported_16khz_codec"))
                return
            }
            capabilitiesConfirmed = true
            finishInitializationIfReady(generation: generation)
        case 0x08:
            guard lifecycle.acceptsProtocolData(generation: generation) else { return }
            let toggleStopRequested = delegate?.bluetoothBridgeShouldCloseStreamingOnRemoteOpenRequest(self) ?? false
            if ATVVSessionGate.shouldCloseStreamingOnRemoteOpenRequest(
                isT1Candidate: t1Candidate,
                isStreaming: streaming,
                allowsToggleStop: toggleStopRequested
            ) {
                if toggleStopRequested {
                    if delegate?.bluetoothBridgeIsClosingToggleVoice(self) == true,
                       streamStopWatchdog != nil || microphoneClosePending || !microphoneOpened {
                        AppLogger.shared.write("ATVV MIC_OPEN toggle_close_already_pending")
                        return
                    }
                    delegate?.bluetoothBridgeDidRequestStopToggleVoice(self)
                }
                if requestMicrophoneClose() {
                    let reason = t1Candidate ? "t1_second_press" : "toggle_second_press"
                    AppLogger.shared.write("ATVV MIC_CLOSE requested reason=\(reason)")
                } else {
                    AppLogger.shared.write("ATVV MIC_OPEN toggle_close_already_pending")
                }
                return
            }
            guard requestMicrophoneOpen() else {
                AppLogger.shared.write("ATVV MIC_OPEN remote_request_ignored")
                return
            }
            AppLogger.shared.write("ATVV MIC_OPEN remote_request")
        case 0x04:
            if googleCandidate && (bytes.count < 4 || bytes[2] != 0x02) {
                _ = requestMicrophoneClose()
                stopStreaming(reason: .unsupportedCodec)
                return
            }
            guard ATVVSessionGate.canOpenMicrophone(
                phase: lifecycle,
                generation: generation,
                capabilitiesConfirmed: capabilitiesConfirmed,
                sampleRate: capabilities.sampleRate,
                microphoneClosePending: microphoneClosePending
            ) else {
                AppLogger.shared.write("ATVV STREAM_START ignored_not_ready")
                return
            }
            if bytes.count >= 3 {
                let codec = bytes[2]
                capabilities = ATVVCapabilities(
                    version: capabilities.version,
                    codecs: capabilities.codecs,
                    interaction: bytes[1],
                    frameSize: capabilities.frameSize,
                    selectedCodec: codec,
                    sampleRate: codec == 0x02 ? 16_000 : 8_000
                )
            }
            guard ATVVProtocol.supportsAudio(sampleRate: capabilities.sampleRate) else {
                rejectUnsupportedAudio(LocalizedMessage("connection.error.unsupported_8khz_codec"))
                return
            }
            deviceInformation.capabilities = capabilities
            let incomingInteraction: UInt8? = bytes.count >= 2 ? bytes[1] : nil
            let explicitSessionID: UInt8? = bytes.count >= 4 ? bytes[3] : nil
            let receivedSessionID = explicitSessionID ?? sessionID
            if ATVVSessionGate.shouldIgnoreStreamAfterCancelledOpen(
                cancelledAt: cancelledMicrophoneOpenAt
            ) {
                write(ATVVProtocol.microphoneClose(
                    version: capabilities.version,
                    sessionID: receivedSessionID
                ))
                AppLogger.shared.write(
                    "ATVV STREAM_START ignored_cancelled session=\(receivedSessionID)"
                )
                return
            }
            cancelledMicrophoneOpenAt = nil
            if delegate?.bluetoothBridgeShouldStopToggleVoiceOnRemoteAudioStart(
                self,
                interaction: incomingInteraction,
                incomingSessionID: explicitSessionID
            ) == true {
                let alreadyClosing = delegate?.bluetoothBridgeIsClosingToggleVoice(self) == true
                if alreadyClosing,
                   explicitSessionID == nil || explicitSessionID == sessionID,
                   streamStopWatchdog != nil || microphoneClosePending || !microphoneOpened {
                    AppLogger.shared.write(
                        "ATVV STREAM_START ignored_closing session=\(receivedSessionID)"
                    )
                    return
                }
                if alreadyClosing, explicitSessionID != nil, explicitSessionID != sessionID {
                    // Re-arm the close watchdog when the remote bumps sessionID mid-close.
                    cancelStreamStopWatchdog()
                }
                sessionID = receivedSessionID
                if let explicitSessionID { activeStreamSessionID = explicitSessionID }
                delegate?.bluetoothBridgeDidRequestStopToggleVoice(self)
                let didClose = requestMicrophoneClose()
                if !streaming {
                    cancelledMicrophoneOpenAt = nowUptime()
                }
                AppLogger.shared.write(
                    "ATVV MIC_CLOSE requested reason=toggle_second_press_audio_start " +
                        "session=\(receivedSessionID) written=\(didClose)"
                )
                return
            }
            if ATVVStreamStartPolicy.shouldReplaceStream(
                isStreaming: streaming,
                activeSessionID: activeStreamSessionID,
                incomingSessionID: explicitSessionID
            ) {
                stopStreaming(reason: .sessionReplaced)
            }
            sessionID = receivedSessionID
            if let explicitSessionID { activeStreamSessionID = explicitSessionID }
            startStreaming()
        case 0x00:
            guard lifecycle.acceptsProtocolData(generation: generation) else { return }
            handleRemoteStreamStop(reason: .remoteNotification)
        case 0x0C:
            guard googleCandidate || t1Candidate, lifecycle.acceptsProtocolData(generation: generation) else { return }
            handleRemoteStreamStop(reason: .remoteMicrophoneRefused)
            state = .failed(
                t1Candidate
                    ? LocalizedMessage("t1.remote.microphone_refused")
                    : LocalizedMessage("google.remote.microphone_refused")
            )
        case 0x0A:
            guard lifecycle.acceptsProtocolData(generation: generation) else { return }
            guard bytes.count >= 7 else { return }
            let predictorBits = UInt16(bytes[4]) << 8 | UInt16(bytes[5])
            let predictor = Int(Int16(bitPattern: predictorBits))
            audioDecoder.synchronize(predictor: predictor, stepIndex: Int(bytes[6]))
        default:
            let payload = bytes.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
            AppLogger.shared.write(
                "ATVV CONTROL unknown opcode=\(String(format: "0x%02X", bytes[0])) bytes=\(bytes.count) payload=\(payload)"
            )
        }
    }

    func finishInitializationIfReady(generation: UInt64) {
        guard ATVVSessionGate.canTransitionToReady(
            capabilitiesConfirmed: capabilitiesConfirmed,
            isGoogleCandidate: googleCandidate,
            googleReady: googleReadiness.isReady,
            isT1Candidate: t1Candidate,
            t1Ready: t1Readiness.isReady,
            modelFormatResolved: modelFormatResolved
        ),
        lifecycle == .awaitingCapabilities(generation), let peripheral else { return }
        if t1Candidate && t1Readiness.isReady && identifiedModel == nil {
            identifiedModel = .t1Remote
            delegate?.bluetoothBridge(self, didIdentifyRemoteModel: .t1Remote)
        }
        initializationTimeoutWorkItem?.cancel()
        initializationTimeoutWorkItem = nil
        reconnectPolicy.reset()
        currentAttemptUsesCachedTarget = false
        lifecycle = .ready(generation)
        finishRemoteWakeRecovery(result: "ready")
        state = .ready(peripheral.name ?? (googleCandidate ? "G9N9N" : (t1Candidate ? "T1-Remote" : "MI RC")))
    }

    func scheduleMicrophoneKeepalive() {
        microphoneKeepalive?.cancel()
        microphoneKeepalive = nil
        guard googleCandidate || t1Candidate, streaming, !microphoneClosePending,
              streamStopWatchdog == nil,
              let generation = currentGeneration() else { return }
        microphoneKeepalive = scheduleMicrophoneClose(TimeInterval(VoiceAutoStopDuration.keepaliveIntervalSeconds)) { [weak self] in
            guard let self, self.streaming, !self.microphoneClosePending,
                  self.streamStopWatchdog == nil,
                  self.currentGeneration() == generation else { return }
            if self.microphoneKeepaliveCount >= self.maxMicrophoneKeepaliveExtensions {
                AppLogger.shared.write(
                    "ATVV MIC_EXTEND limit_reached session=\(self.sessionID) max_minutes=\(self.settings.voiceAutoStopDuration.minutes)"
                )
                _ = self.requestMicrophoneClose()
                return
            }
            self.microphoneKeepaliveCount += 1
            _ = self.requestMicrophoneExtend()
            self.scheduleMicrophoneKeepalive()
        }
    }

    func startStreaming() {
        guard !systemSuspension.isSuspended || streaming else {
            _ = requestMicrophoneClose()
            return
        }
        guard !streaming else { return }
        lastVoiceStopReason = nil
        streamStopRecorded = false
        localMicrophoneCloseRequested = false
        cancelStreamStopWatchdog()
        microphoneKeepaliveCount = 0
        let partialFrameBytes = audioDecoder.pendingByteCount
        if partialFrameBytes > 0 {
            AppLogger.shared.write(
                "ATVV FRAME discarded session=\(sessionID) reason=stream_start " +
                    "streaming_before=\(streaming) partial_frame_bytes=\(partialFrameBytes)"
            )
        }
        let capturedStartAt = nowUptime()
        guard audioDecoder.beginStream(onStart: { [weak self] in
            guard let self else { return }
            self.voiceStartNotified = true
            self.delegate?.bluetoothBridgeDidStartVoice(self)
        }) else { return }
        lastVoiceStartAt = capturedStartAt
        lastVoiceStopAt = nil
        lastStopAt = nil
        microphoneOpened = true
        scheduleMicrophoneKeepalive()
        AppLogger.shared.write("ATVV STREAM START session=\(sessionID)")
    }

    func recordStreamStop(reason: BluetoothVoiceStopReason) {
        guard streaming || voiceStartNotified, !streamStopRecorded else { return }
        streamStopRecorded = true
        if lastVoiceStopAt == nil {
            lastVoiceStopAt = nowUptime()
        }
        lastVoiceStopReason = reason
        voiceDiagnosticLogger(
            "ATVV STREAM STOP session=\(sessionID) reason=\(reason.rawValue) " +
                "close_requested=\(localMicrophoneCloseRequested) " +
                "partial_frame_bytes=\(audioDecoder.pendingByteCount)"
        )
    }

    func stopStreaming(reason: BluetoothVoiceStopReason) {
        recordStreamStop(reason: reason)
        activeStreamSessionID = nil
        microphoneKeepalive?.cancel()
        microphoneKeepalive = nil
        microphoneKeepaliveCount = 0
        cancelStreamStopWatchdog()
        guard streaming else { return }
        let gain = settings.gainDB(forBluetoothIdentifier: deviceIdentifier)
        audioDecoder.endStream(
            frameSize: capabilities.frameSize,
            gainDB: gain,
            onDecoded: { [weak self] samples in
                guard let self else { return }
                self.delegate?.bluetoothBridge(self, didDecode: samples)
            },
            onStop: { [weak self] in
                guard let self else { return }
                self.voiceStartNotified = false
                self.delegate?.bluetoothBridgeDidStopVoice(self)
            }
        )
        lastStopAt = nowUptime()
    }

    func handleRemoteStreamStop(reason: BluetoothVoiceStopReason) {
        recordStreamStop(reason: reason)
        microphoneOpened = false
        microphoneClosePending = false
        microphoneCloseSessionID = nil
        cancelMicrophoneCloseWatchdog()
        cancelStreamStopWatchdog()
        stopStreaming(reason: reason)
    }

    func handleAudio(_ data: Data) {
        guard let generation = currentGeneration(),
              ATVVSessionGate.canOpenMicrophone(
                phase: lifecycle,
                generation: generation,
                capabilitiesConfirmed: capabilitiesConfirmed,
                sampleRate: capabilities.sampleRate,
                microphoneClosePending: microphoneClosePending
              )
        else {
            AppLogger.shared.write("ATVV AUDIO ignored_not_ready")
            return
        }
        if ATVVSessionGate.shouldIgnoreStreamAfterCancelledOpen(
            cancelledAt: cancelledMicrophoneOpenAt
        ) {
            AppLogger.shared.write("ATVV AUDIO ignored_cancelled_open")
            return
        }
        cancelledMicrophoneOpenAt = nil
        if !streaming {
            let receivedAt = nowUptime()
            let cooldown = ATVVSessionGate.audioAfterStopCooldown(isT1Candidate: t1Candidate)
            if let lastStopAt, ATVVSessionGate.shouldIgnoreAudioAfterStop(
                stoppedAt: lastStopAt,
                now: receivedAt,
                cooldown: cooldown
            ) {
                let delayMilliseconds = max(
                    0,
                    Int(((receivedAt - lastStopAt) * 1_000).rounded())
                )
                AppLogger.shared.write(
                    "ATVV AUDIO ignored_after_stop session=\(sessionID) " +
                        "delay_ms=\(delayMilliseconds) bytes=\(data.count)"
                )
                return
            }
            startStreaming()
            AppLogger.shared.write("ATVV STREAM implicit_audio_race")
        }

        let accepted = audioDecoder.append(data, frameSize: capabilities.frameSize,
            gainDB: settings.gainDB(forBluetoothIdentifier: deviceIdentifier)) { [weak self] samples in
            guard let self else { return }
            self.delegate?.bluetoothBridge(self, didDecode: samples)
        }
        if !accepted {
            AppLogger.shared.write("ATVV AUDIO rejected reason=decode_backlog")
            _ = requestMicrophoneClose()
            stopStreaming(reason: .decodeBacklog)
        }
    }

    func rejectUnsupportedAudio(_ message: LocalizedMessage) {
        state = .failed(message)
        closeMicrophoneIfNeeded()
        resetSession(reason: .unsupportedAudio)
        scheduleReconnect(bypassCachedTarget: true)
    }

    func failInitialization(_ message: LocalizedMessage) {
        AppLogger.shared.write("BLE INITIALIZATION failed reason=\(message.key)")
        state = .failed(message)
        resetSession(reason: .initializationFailed)
        scheduleReconnect(bypassCachedTarget: true)
    }
}
