@preconcurrency import AVFoundation
import AudioExceptionGuard
import AudioToolbox
import CoreAudio
import Foundation

final class VirtualAudioOutput: @unchecked Sendable {
    struct OutputState {
        var ready = false
        var healthy = false
        var engineRunning = false
        var playerPlaying = false
        var selectedDevice: AudioDeviceInfo?
        var actualDevice: AudioDeviceInfo?
        var status = LocalizedMessage("audio.output.none_selected")
        var route = "default_input={unknown} default_output={unknown} default_system_output={unknown}"
    }

    struct PendingDeliveryCounters {
        var buffers = 0
        var samples = 0
    }

    struct DrainRequest: @unchecked Sendable {
        let source: String
        let operationID: UInt64
        let startedAtUptime: TimeInterval
        let requestedOnMainThread: Bool
        let deadline: TimeInterval?
        let completion: (VirtualAudioDrainOutcome) -> Void
    }

    var engine: AVAudioEngine?
    var player: AVAudioPlayerNode?
    var engineConfigurationObserver: NSObjectProtocol?
    var engineConfigurationGeneration: UInt64 = 0
    let rejectedWriteLock = NSLock()
    var rejectedWriteCount = 0
    var lastRejectedWriteLogUptime = -TimeInterval.infinity
    let playbackLock = NSLock()
    var pendingVoiceBufferCount = 0
    var pendingVoiceSampleCount = 0
    var pendingPreRollSampleCount = 0
    var preRollSampleBudget = 0
    var playbackGeneration: UInt64 = 0
    var playbackCounters = VirtualAudioPlaybackCounters()
    var playbackCountersByDeliveryGeneration: [Int: VirtualAudioPlaybackCounters] = [:]
    var pendingByDeliveryGeneration: [Int: PendingDeliveryCounters] = [:]
    let audibilityCache = AudibilityCache()
    var pendingDrainLogContexts: [String] = []
    var drainRequests: [DrainRequest] = []
    var drainGeneration: UInt64 = 0
    var nextDrainOperationID: UInt64 = 0
    let logger: (String) -> Void
    let scheduleDrainDeadline: OperationScheduler
    let uptime: () -> TimeInterval
    let engineQueue: DispatchQueue
    let engineQueueKey = DispatchSpecificKey<Void>()
    var nextConfigurationOperationID: UInt64 = 0
    let outputStateLock = NSLock()
    var outputState = OutputState()
    var cachedOutputState: OutputState {
        outputStateLock.lock()
        defer { outputStateLock.unlock() }
        return outputState
    }

    // This lock protects values only. Never hold it across AVAudioEngine or HAL calls.
    func updateOutputState(_ update: (inout OutputState) -> Void) {
        outputStateLock.lock()
        let previousID = outputState.selectedDevice?.id
        update(&outputState)
        let newID = outputState.selectedDevice?.id
        outputStateLock.unlock()
        if previousID != newID {
            invalidateAudibilityCache()
        }
    }
    private let sourceFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    var selectedDevice: AudioDeviceInfo? { cachedOutputState.selectedDevice }
    private(set) var status: LocalizedMessage {
        get { cachedOutputState.status }
        set { updateOutputState { $0.status = newValue } }
    }
    var onConfigurationChange: (() -> Void)?

    init(
        logger: @escaping (String) -> Void = { AppLogger.shared.write($0) },
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        scheduleDrainDeadline: @escaping OperationScheduler = ScheduledOperation.mainQueue,
        engineQueue: DispatchQueue = DispatchQueue(
            label: "RemoteBuddy.audioOutput.engine",
            qos: .userInitiated
        )
    ) {
        self.logger = logger
        self.uptime = uptime
        self.scheduleDrainDeadline = scheduleDrainDeadline
        self.engineQueue = engineQueue
        engineQueue.setSpecific(key: engineQueueKey, value: ())
    }

    deinit {
        // stop() deliberately queues work on the main-thread path; a weak queued
        // teardown cannot run after destruction, so destruction uses synchronous ownership.
        if DispatchQueue.getSpecific(key: engineQueueKey) != nil {
            stopOnEngineQueue()
        } else {
            engineQueue.sync { stopOnEngineQueue() }
        }
    }

    /// Counts one buffer as queued for playback. Together with
    /// `scheduledVoiceBufferDidFinish` this drives the pending-buffer count that
    /// draining waits on, so it is the single seam a test can use to arm drain
    /// bookkeeping without a live output device.
    func registerPendingVoiceBuffer() {
        playbackLock.lock()
        pendingVoiceBufferCount += 1
        playbackLock.unlock()
    }

    var pendingVoiceBufferCountForDiagnostics: Int {
        playbackLock.lock()
        defer { playbackLock.unlock() }
        return pendingVoiceBufferCount
    }

    var hasAllocatedOutputResources: Bool {
        cachedOutputState.selectedDevice != nil
    }

    var isConfigurationHealthyForDiagnostics: Bool {
        cachedOutputState.healthy
    }

    func configureAsync(deviceUID: String, completion: @escaping @Sendable (Bool) -> Void) {
        playbackLock.lock()
        nextConfigurationOperationID &+= 1
        let operationID = nextConfigurationOperationID
        playbackLock.unlock()
        let requestedAt = uptime()
        logger("AUDIO CONFIGURE operation_id=\(operationID) phase=requested result=pending queue=audio_output")
        engineQueue.async { [weak self] in
            guard let self else { return }
            let startedAt = self.uptime()
            self.logger(
                "AUDIO CONFIGURE operation_id=\(operationID) phase=started result=pending queue=audio_output " +
                    "queue_wait_ms=\(max(0, Int((startedAt - requestedAt) * 1_000)))"
            )
            let configured = self.configureOnEngineQueue(deviceUID: deviceUID, operationID: operationID)
            self.logger(
                "AUDIO CONFIGURE operation_id=\(operationID) phase=completed " +
                    "result=\(configured ? "ready" : "failed") reason=\(configured ? "ready" : "configure_failed") " +
                    "status_key=\(self.status.key) queue=audio_output " +
                    "elapsed_ms=\(max(0, Int((self.uptime() - requestedAt) * 1_000)))"
            )
            completion(configured)
        }
    }

    @discardableResult
    private func configureOnEngineQueue(deviceUID: String, operationID: UInt64) -> Bool {
        dispatchPrecondition(condition: .onQueue(engineQueue))
        let startedAtUptime = uptime()
        let elapsedMilliseconds = {
            max(0, Int((self.uptime() - startedAtUptime) * 1_000))
        }
        let logStage = { (stage: String) in
            self.logger(
                "AUDIO CONFIGURE operation_id=\(operationID) phase=applying result=pending " +
                    "stage=\(stage) queue=audio_output elapsed_ms=\(elapsedMilliseconds())"
            )
        }
        let previousState = diagnosticState()
        logStage("stop_previous")
        stopOnEngineQueue()
        guard !deviceUID.isEmpty else {
            status = LocalizedMessage("audio.output.none_selected")
            logger(
                "AUDIO CONFIGURE skipped reason=no_selected_device queue=audio_output " +
                    "elapsed_ms=\(elapsedMilliseconds()) previous={\(previousState)}"
            )
            return false
        }
        logStage("enumerate_devices")
        let availableDevices = CoreAudioDeviceCatalog.outputDevices()
        guard let device = availableDevices.first(where: { $0.uid == deviceUID }) else {
            status = LocalizedMessage("audio.output.selected_unavailable")
            logger(
                "AUDIO CONFIGURE failed reason=selected_device_unavailable " +
                    "queue=audio_output elapsed_ms=\(elapsedMilliseconds()) " +
                    "available={\(CoreAudioDeviceCatalog.outputDevicesDiagnostic(availableDevices))}"
            )
            return false
        }
        logger(
            "AUDIO CONFIGURE begin queue=audio_output target={\(CoreAudioDeviceCatalog.deviceDiagnostic(device))} " +
                "elapsed_ms=\(elapsedMilliseconds()) " +
                "previous={\(previousState)}"
        )

        logStage("repair_audibility")
        let audibilityRepair = CoreAudioDeviceCatalog.ensureVirtualAudioDeviceAudible(device)
        invalidateAudibilityCache()
        if audibilityRepair.applicable {
            logger(
                "AUDIO AUDIBILITY repair " +
                    "device_kind=\(VirtualAudioDeviceDiagnosticKind.classify(device).rawValue) " +
                    "unmute_attempted=\(audibilityRepair.unmuteAttempted) " +
                    "volume_restore_attempted=\(audibilityRepair.volumeRestoreAttempted) " +
                    "write_failed=\(audibilityRepair.writeFailed) " +
                    "before={\(audibilityRepair.before.diagnostic)} " +
                    "after={\(audibilityRepair.after.diagnostic)} " +
                    "result=\(audibilityRepair.isReady ? "ready" : "below_minimum")"
            )
        }
        guard audibilityRepair.isReady else {
            status = LocalizedMessage("audio.output.selected_unavailable")
            logger(
                "AUDIO CONFIGURE failed reason=virtual_device_level_below_minimum " +
                    "queue=audio_output elapsed_ms=\(elapsedMilliseconds()) " +
                    "device_kind=\(VirtualAudioDeviceDiagnosticKind.classify(device).rawValue)"
            )
            return false
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        var outputUnit: AudioUnit?
        let setupSucceeded = RemoteBuddyTryAudioOperation {
            engine.attach(player)
            outputUnit = engine.outputNode.audioUnit
        }

        logStage("open_output_unit")
        guard setupSucceeded, let outputUnit else {
            status = LocalizedMessage("audio.output.core_audio_open_failed")
            logger(
                "AUDIO CONFIGURE failed reason=no_output_unit queue=audio_output " +
                    "elapsed_ms=\(elapsedMilliseconds()) target={\(CoreAudioDeviceCatalog.deviceDiagnostic(device))}"
            )
            return false
        }
        var deviceID = device.id
        logStage("select_device")
        var result: OSStatus = -1
        let succeeded = RemoteBuddyTryAudioOperation {
            result = AudioUnitSetProperty(
            outputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }
        guard succeeded && result == noErr else {
            status = LocalizedMessage("audio.output.select_failed", arguments: [String(result)])
            logger(
                "AUDIO CONFIGURE failed reason=set_current_device " +
                    "queue=audio_output elapsed_ms=\(elapsedMilliseconds()) " +
                    "target={\(CoreAudioDeviceCatalog.deviceDiagnostic(device))} " +
                    AppLogger.errorFields(domain: "os_status", code: Int(result))
            )
            return false
        }

        var accepted = false
        defer {
            if !accepted {
                _ = RemoteBuddyTryAudioOperation { player.stop() }
                _ = RemoteBuddyTryAudioOperation { engine.stop() }
            }
        }
        do {
            try AudioEngineSafety.perform {
                logStage("connect_mixer")
                engine.connect(player, to: engine.mainMixerNode, format: self.sourceFormat)
                logStage("prepare_engine")
                engine.prepare()
                logStage("start_engine")
                try engine.start()
            }
            logStage("start_player")
            guard AudioPlayerNodeSafety.play(player) else {
                _ = RemoteBuddyTryAudioOperation { player.stop() }
                _ = RemoteBuddyTryAudioOperation { engine.stop() }
                status = LocalizedMessage("audio.output.selected_unavailable")
                logger(
                    "AUDIO ERROR player_start_exception " +
                        "queue=audio_output elapsed_ms=\(elapsedMilliseconds()) " +
                        "target={\(CoreAudioDeviceCatalog.deviceDiagnostic(device))}"
                )
                return false
            }
            self.engine = engine
            self.player = player
            updateOutputState { $0.selectedDevice = device }
            logStage("verify_output")
            refreshOutputStateOnEngineQueue()
            guard isReadyForVoicePlayback else {
                // Capture before teardown clears the engine and selected/actual route.
                let snapshot = diagnosticSnapshot()
                logger(
                    "AUDIO CONFIGURE failed reason=verify_output queue=audio_output " +
                        "elapsed_ms=\(elapsedMilliseconds()) " +
                        "engine_running=\(snapshot.engineRunning) player_playing=\(snapshot.playerPlaying) " +
                        "bound_to_selected=\(snapshot.boundToSelectedDevice.map(String.init) ?? "unknown") " +
                        "audibility_healthy=\(snapshot.audibilityHealthy) state={\(diagnosticState())}"
                )
                stopOnEngineQueue()
                status = LocalizedMessage("audio.output.selected_unavailable")
                return false
            }
            accepted = true
            observeConfigurationChanges(for: engine)
            status = LocalizedMessage("audio.output.current_format", arguments: [device.name])
            logger(
                "AUDIO READY target={\(CoreAudioDeviceCatalog.deviceDiagnostic(device))} " +
                    "elapsed_ms=\(elapsedMilliseconds()) " +
                    "queue=audio_output state={\(diagnosticState())}"
            )
            return true
        } catch {
            status = LocalizedMessage(
                "audio.output.start_failed",
                arguments: [error.localizedDescription]
            )
            logger(
                "AUDIO ERROR start_failed " + AppLogger.errorFields(error) + " " +
                    "queue=audio_output elapsed_ms=\(elapsedMilliseconds()) " +
                    "target={\(CoreAudioDeviceCatalog.deviceDiagnostic(device))} state={\(diagnosticState())}"
            )
            return false
        }
    }

    var isReadyForVoicePlayback: Bool {
        cachedOutputState.ready
    }

    var actualDevice: AudioDeviceInfo? {
        cachedOutputState.actualDevice
    }

    private func makeBuffer(samples: [Int16]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty else { return nil }
        var buffer: AVAudioPCMBuffer?
        let succeeded = RemoteBuddyTryAudioOperation {
            buffer = AVAudioPCMBuffer(
                pcmFormat: self.sourceFormat,
                frameCapacity: AVAudioFrameCount(samples.count)
            )
        }
        guard succeeded,
              let buffer,
              let channel = buffer.floatChannelData?[0]
        else { return nil }

        for index in samples.indices {
            channel[index] = PCMNormalization.sample(samples[index])
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }

    @discardableResult
    func enqueue(samples: [Int16], deliveryGeneration: Int = 0, isPreRoll: Bool = false) -> Bool {
        guard !samples.isEmpty else {
            logRejectedWrite(reason: "empty_samples")
            return false
        }
        guard isPlaybackReady else {
            logRejectedWrite(reason: "playback_not_ready")
            return false
        }
        guard samples.count <= (isPreRoll ? VoicePlaybackQueueCapacity.maximumPreRollSamples : VoicePlaybackQueueCapacity.maximumSamples) else {
            logRejectedWrite(reason: "oversized_batch")
            return false
        }
        let chunks = VoicePlaybackQueueCapacity.chunks(samples)
        let buffers = chunks.compactMap { makeBuffer(samples: $0) }
        guard buffers.count == chunks.count else {
            logRejectedWrite(reason: "buffer_creation_failed_or_oversized")
            return false
        }
        rejectedWriteLock.lock()
        let rejectedCount = rejectedWriteCount
        rejectedWriteCount = 0
        rejectedWriteLock.unlock()
        if rejectedCount > 0 {
            AppLogger.shared.write("AUDIO WRITE resumed rejected_count=\(rejectedCount) state={\(basicDiagnosticState())}")
        }
        playbackLock.lock()
        let generation = playbackGeneration
        let sampleCount = samples.count
        guard VoicePlaybackQueueCapacity.admits(pending: pendingVoiceSampleCount, incoming: sampleCount,
            pendingPreRoll: pendingPreRollSampleCount, isPreRoll: isPreRoll, preRollBudget: preRollSampleBudget) else {
            playbackLock.unlock()
            logRejectedWrite(reason: "queue_capacity")
            return false
        }
        pendingVoiceBufferCount += buffers.count
        pendingVoiceSampleCount += sampleCount
        if isPreRoll {
            pendingPreRollSampleCount += sampleCount
            preRollSampleBudget = max(preRollSampleBudget, pendingPreRollSampleCount)
        }
        playbackCounters.scheduledBuffers += buffers.count
        playbackCounters.scheduledSamples += sampleCount
        playbackCountersByDeliveryGeneration[deliveryGeneration, default: .init()].scheduledBuffers += buffers.count
        playbackCountersByDeliveryGeneration[deliveryGeneration, default: .init()].scheduledSamples += sampleCount
        pendingByDeliveryGeneration[deliveryGeneration, default: .init()].buffers += buffers.count
        pendingByDeliveryGeneration[deliveryGeneration, default: .init()].samples += sampleCount
        playbackLock.unlock()
        engineQueue.async { [weak self] in
            guard let self else { return }
            self.playbackLock.lock()
            let isCurrent = generation == self.playbackGeneration
            self.playbackLock.unlock()
            // A preceding stop or explicit flush already accounted for an interrupted buffer.
            guard isCurrent else { return }
            guard let player = self.player else {
                self.stopOnEngineQueue()
                return
            }
            for (chunk, buffer) in zip(chunks, buffers) {
                let scheduled = AudioPlayerNodeSafety.schedule(player, buffer: buffer) { [weak self] _ in
                    self?.scheduledVoiceBufferDidFinish(sampleCount: chunk.count, generation: generation,
                        deliveryGeneration: deliveryGeneration, isPreRoll: isPreRoll)
                }
                if !scheduled {
                    AppLogger.shared.write("AUDIO ERROR schedule_exception")
                    self.stopOnEngineQueue()
                    self.onConfigurationChange?()
                    return
                }
            }
        }
        return true
    }

    var pendingPlaybackDuration: TimeInterval {
        playbackLock.lock()
        defer { playbackLock.unlock() }
        let sampleRate = sourceFormat.sampleRate > 0 ? sourceFormat.sampleRate : 16_000
        return Double(pendingVoiceSampleCount) / sampleRate
    }

    func stop() {
        if DispatchQueue.getSpecific(key: engineQueueKey) != nil {
            stopOnEngineQueue()
        } else if Thread.isMainThread {
            updateOutputState {
                $0.ready = false
                $0.healthy = false
                $0.engineRunning = false
                $0.playerPlaying = false
            }
            engineQueue.async { [weak self] in
                self?.stopOnEngineQueue()
            }
        } else {
            engineQueue.sync {
                stopOnEngineQueue()
            }
        }
    }

    func invalidateAudibilityCache() {
        audibilityCache.invalidate()
    }

    func stopOnEngineQueue() {
        invalidateAudibilityCache()
        updateOutputState { $0.ready = false; $0.healthy = false; $0.engineRunning = false; $0.playerPlaying = false }
        playbackLock.lock()
        let interruptedContexts = pendingVoiceBufferCount > 0 ? pendingDrainLogContexts : []
        let interruptedBuffers = pendingVoiceBufferCount
        let interruptedSamples = pendingVoiceSampleCount
        playbackCounters.interruptedBuffers += pendingVoiceBufferCount
        playbackCounters.interruptedSamples += pendingVoiceSampleCount
        recordPendingDeliveriesAsInterrupted()
        pendingVoiceBufferCount = 0
        pendingVoiceSampleCount = 0
        pendingPreRollSampleCount = 0
        preRollSampleBudget = 0
        playbackGeneration &+= 1
        pendingDrainLogContexts.removeAll()
        // Same contract as flushPlayer: stopping answers the drain waiter exactly
        // once, after the teardown below, instead of dropping it with the
        // generation bump.
        let interruptedDrains = drainRequests
        drainRequests.removeAll(keepingCapacity: true)
        drainGeneration &+= 1
        playbackLock.unlock()
        for context in interruptedContexts {
            AppLogger.shared.write("AUDIO PLAYBACK interrupted \(context)")
        }
        removeEngineConfigurationObserver()
        if let player { _ = RemoteBuddyTryAudioOperation { player.stop() } }
        if let engine { _ = RemoteBuddyTryAudioOperation { engine.stop() } }
        player = nil
        engine = nil
        updateOutputState {
            $0.selectedDevice = nil
            $0.actualDevice = nil
            $0.ready = false
            $0.healthy = false
            $0.engineRunning = false
            $0.playerPlaying = false
        }
        completeDrainRequests(
            interruptedDrains,
            outcome: .forced,
            phase: "completed",
            result: "forced",
            reason: "output_stop",
            pendingBuffers: 0,
            pendingSamples: 0,
            interruptedBuffers: interruptedBuffers,
            interruptedSamples: interruptedSamples
        )
    }

    private func observeConfigurationChanges(for engine: AVAudioEngine) {
        engineConfigurationGeneration &+= 1
        let generation = engineConfigurationGeneration
        engineConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self, weak engine] _ in
            self?.engineQueue.async { [weak self, weak engine] in
                guard let self,
                      let engine,
                      self.engine === engine,
                      self.engineConfigurationGeneration == generation
                else { return }
                self.refreshOutputStateOnEngineQueue()
                self.logger(
                    "AUDIO ENGINE configuration_changed generation=\(generation) " +
                        "phase=observed result=pending queue=audio_output"
                )
                self.onConfigurationChange?()
            }
        }
    }

    private func removeEngineConfigurationObserver() {
        if let engineConfigurationObserver {
            NotificationCenter.default.removeObserver(engineConfigurationObserver)
            self.engineConfigurationObserver = nil
        }
        engineConfigurationGeneration &+= 1
    }

    private var isPlaybackReady: Bool {
        let state = cachedOutputState
        return state.ready && VirtualAudioHealthPolicy.isPlaybackReady(
            hasSelectedDevice: state.selectedDevice != nil,
            engineRunning: state.engineRunning,
            playerPlaying: state.playerPlaying
        )
    }

    private func refreshOutputStateOnEngineQueue() {
        dispatchPrecondition(condition: .onQueue(engineQueue))
        let selected = selectedDevice
        let actual = currentOutputDevice()
        let running = engine?.isRunning == true
        let playing = player?.isPlaying == true
        let audibility = CoreAudioDeviceCatalog.virtualAudioAudibilitySnapshot(for: selected)
        let route = CoreAudioDeviceCatalog.routeDiagnostic()
        let healthy = VirtualAudioHealthPolicy.isConfigurationHealthy(
            hasSelectedDevice: selected != nil,
            engineRunning: running,
            playerPlaying: playing,
            boundToSelectedDevice: selected?.id == actual?.id
        ) && !audibility.requiresAudibilityRepair
        updateOutputState {
            $0.actualDevice = actual
            $0.engineRunning = running
            $0.playerPlaying = playing
            $0.ready = healthy
            $0.healthy = healthy
            $0.route = route
        }
    }

    private func currentOutputDevice() -> AudioDeviceInfo? {
        guard let outputUnit = engine?.outputNode.audioUnit else { return nil }
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var result: OSStatus = -1
        let succeeded = RemoteBuddyTryAudioOperation {
            result = AudioUnitGetProperty(
            outputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            &size
            )
        }
        guard succeeded && result == noErr else { return nil }
        return CoreAudioDeviceCatalog.deviceInfo(for: deviceID)
    }

    private func logRejectedWrite(reason: String) {
        rejectedWriteLock.lock()
        rejectedWriteCount += 1
        let count = rejectedWriteCount
        let now = uptime()
        let shouldLog = now - lastRejectedWriteLogUptime >= 1
        if shouldLog { lastRejectedWriteLogUptime = now }
        rejectedWriteLock.unlock()
        guard shouldLog else { return }
        AppLogger.shared.write(
            "AUDIO WRITE rejected count=\(count) reason=\(reason) " +
                "state={\(diagnosticState())}"
        )
    }
}
