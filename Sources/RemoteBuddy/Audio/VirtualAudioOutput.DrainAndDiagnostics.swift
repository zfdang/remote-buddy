@preconcurrency import AVFoundation
import AudioExceptionGuard
import CoreAudio
import Foundation

extension VirtualAudioOutput {
    func endSession() {
        flushPlayer()
    }

    func endSessionAfterDraining(
        source: String = "unspecified",
        operationID: UInt64? = nil,
        maximumDelay: TimeInterval? = 0.75,
        completion: @escaping () -> Void
    ) {
        endSessionAfterDraining(
            source: source,
            operationID: operationID,
            maximumDelay: maximumDelay
        ) { _ in
            completion()
        }
    }

    func endSessionAfterDraining(
        source: String = "unspecified",
        operationID: UInt64? = nil,
        maximumDelay: TimeInterval? = 0.75,
        completion: @escaping (VirtualAudioDrainOutcome) -> Void
    ) {
        playbackLock.lock()
        nextDrainOperationID &+= 1
        let resolvedOperationID = operationID ?? nextDrainOperationID
        let now = uptime()
        let request = DrainRequest(
            source: source,
            operationID: resolvedOperationID,
            startedAtUptime: now,
            requestedOnMainThread: Thread.isMainThread,
            deadline: maximumDelay.map { now + max(0, $0) },
            completion: completion
        )
        let shouldCompleteImmediately = pendingVoiceBufferCount == 0
        let wasWaiting = !drainRequests.isEmpty
        let pendingBuffers = pendingVoiceBufferCount
        let pendingSamples = pendingVoiceSampleCount
        let generation: UInt64?
        if shouldCompleteImmediately {
            // A completion already waiting for the main queue owns the zero-pending transition.
            // Append to it instead of flushing a newly queued session or invoking early.
            drainRequests.append(request)
            generation = nil
        } else {
            drainGeneration &+= 1
            drainRequests.append(request)
            generation = drainGeneration
        }
        let deadlines = drainRequests.compactMap(\.deadline)
        let sharedDeadline = deadlines.count == drainRequests.count ? deadlines.max() : nil
        playbackLock.unlock()

        logger(
            "AUDIO DRAIN operation_id=\(resolvedOperationID) source=\(source) " +
                "phase=requested result=pending pending_buffers=\(pendingBuffers) " +
                "pending_samples=\(pendingSamples) timeout_ms=\(Self.milliseconds(maximumDelay)) " +
                "joined_existing=\(wasWaiting)"
        )

        if shouldCompleteImmediately && !wasWaiting {
            playbackLock.lock()
            let requests = drainRequests
            drainRequests.removeAll(keepingCapacity: true)
            drainGeneration &+= 1
            playbackLock.unlock()
            completeDrainRequests(
                requests,
                outcome: .normal,
                phase: "completed",
                result: "normal",
                reason: "no_pending",
                pendingBuffers: 0,
                pendingSamples: 0
            )
            return
        }
        if let sharedDeadline, let generation {
            _ = scheduleDrainDeadline(max(0, sharedDeadline - now)) { [weak self] in
                self?.finishDrainIfNeeded(generation: generation)
            }
        }
    }

    func cancelPendingDrain() {
        playbackLock.lock()
        let cancelledRequests = drainRequests
        let pendingBuffers = pendingVoiceBufferCount
        let pendingSamples = pendingVoiceSampleCount
        drainRequests.removeAll(keepingCapacity: true)
        drainGeneration &+= 1
        playbackLock.unlock()
        completeDrainRequests(
            cancelledRequests,
            outcome: .forced,
            phase: "cancelled",
            result: "cancelled",
            reason: "explicit_cancel",
            pendingBuffers: pendingBuffers,
            pendingSamples: pendingSamples
        )
    }

    func logWhenPendingVoiceAudioDrains(context: String) {
        playbackLock.lock()
        let alreadyDrained = pendingVoiceBufferCount == 0
        if !alreadyDrained {
            pendingDrainLogContexts.append(context)
        }
        playbackLock.unlock()
        if alreadyDrained {
            AppLogger.shared.write("AUDIO PLAYBACK drained \(context) pending_buffers=0")
        }
    }

    func flushPlayer() {
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
        // Taken before the teardown below so a nested `stop()` cannot pick it up a second
        // time, and invoked afterwards so it never runs against a half-restarted player.
        // An interruption is an outcome and must answer the waiter exactly once: dropping
        // it here strands the caller on a drain that can never report back, because the
        // fallback timer armed by `endSessionAfterDraining` is invalidated by the
        // generation bump below.
        let interruptedDrains = drainRequests
        drainRequests.removeAll(keepingCapacity: true)
        drainGeneration &+= 1
        playbackLock.unlock()
        for context in interruptedContexts {
            AppLogger.shared.write("AUDIO PLAYBACK interrupted \(context)")
        }
        let restartPlayer: @Sendable () -> Void = { [weak self] in
            guard let self,
                  let player = self.player,
                  self.engine?.isRunning == true
            else { return }
            guard AudioPlayerNodeSafety.reset(player), AudioPlayerNodeSafety.play(player) else {
                AppLogger.shared.write("AUDIO ERROR player_restart_exception state={\(self.diagnosticState())}")
                self.stopOnEngineQueue()
                self.onConfigurationChange?()
                return
            }
        }
        if DispatchQueue.getSpecific(key: engineQueueKey) != nil {
            restartPlayer()
        } else {
            engineQueue.async(execute: restartPlayer)
        }
        completeDrainRequests(
            interruptedDrains,
            outcome: .forced,
            phase: "completed",
            result: "forced",
            reason: "player_flush",
            pendingBuffers: 0,
            pendingSamples: 0,
            interruptedBuffers: interruptedBuffers,
            interruptedSamples: interruptedSamples
        )
    }

    func scheduledVoiceBufferDidFinish(
        sampleCount: Int,
        generation: UInt64,
        deliveryGeneration: Int,
        isPreRoll: Bool = false
    ) {
        var completionGeneration: UInt64?
        var drainedContexts: [String] = []
        playbackLock.lock()
        guard generation == playbackGeneration else {
            playbackLock.unlock()
            return
        }
        pendingVoiceBufferCount = max(0, pendingVoiceBufferCount - 1)
        pendingVoiceSampleCount = max(0, pendingVoiceSampleCount - sampleCount)
        if isPreRoll { pendingPreRollSampleCount = max(0, pendingPreRollSampleCount - sampleCount) }
        playbackCounters.playedBuffers += 1
        playbackCounters.playedSamples += sampleCount
        playbackCountersByDeliveryGeneration[deliveryGeneration, default: .init()].playedBuffers += 1
        playbackCountersByDeliveryGeneration[deliveryGeneration, default: .init()].playedSamples += sampleCount
        if var pending = pendingByDeliveryGeneration[deliveryGeneration] {
            pending.buffers = max(0, pending.buffers - 1)
            pending.samples = max(0, pending.samples - sampleCount)
            if pending.buffers == 0 && pending.samples == 0 {
                pendingByDeliveryGeneration.removeValue(forKey: deliveryGeneration)
            } else {
                pendingByDeliveryGeneration[deliveryGeneration] = pending
            }
        }
        if pendingVoiceBufferCount == 0 {
            preRollSampleBudget = 0
            drainedContexts = pendingDrainLogContexts
            pendingDrainLogContexts.removeAll()
            if !drainRequests.isEmpty {
                completionGeneration = drainGeneration
            }
        }
        playbackLock.unlock()
        for context in drainedContexts {
            AppLogger.shared.write("AUDIO PLAYBACK drained \(context) pending_buffers=0")
        }
        guard let completionGeneration else { return }
        DispatchQueue.main.async { [weak self] in
            self?.finishDrainedSessionIfNeeded(
                generation: completionGeneration
            )
        }
    }

    func finishDrainedSessionIfNeeded(
        generation: UInt64
    ) {
        playbackLock.lock()
        let shouldFinish = generation == drainGeneration && pendingVoiceBufferCount == 0
        let requests = shouldFinish ? drainRequests : []
        if shouldFinish {
            drainRequests.removeAll(keepingCapacity: true)
            drainGeneration &+= 1
        }
        playbackLock.unlock()
        guard shouldFinish else { return }
        completeDrainRequests(
            requests,
            outcome: .normal,
            phase: "completed",
            result: "normal",
            reason: "buffers_drained",
            pendingBuffers: 0,
            pendingSamples: 0
        )
    }

    func finishDrainIfNeeded(generation: UInt64) {
        playbackLock.lock()
        let shouldFinish = generation == drainGeneration && !drainRequests.isEmpty
        let requests = shouldFinish ? drainRequests : []
        let pendingBuffers = pendingVoiceBufferCount
        let pendingSamples = pendingVoiceSampleCount
        if shouldFinish {
            drainRequests.removeAll(keepingCapacity: true)
            drainGeneration &+= 1
        }
        playbackLock.unlock()
        guard shouldFinish else { return }
        flushPlayer()
        completeDrainRequests(
            requests,
            outcome: .forced,
            phase: "completed",
            result: "forced",
            reason: "deadline",
            pendingBuffers: 0,
            pendingSamples: 0,
            interruptedBuffers: pendingBuffers,
            interruptedSamples: pendingSamples
        )
    }

    func completeDrainRequests(
        _ requests: [DrainRequest],
        outcome: VirtualAudioDrainOutcome,
        phase: String,
        result: String,
        reason: String,
        pendingBuffers: Int,
        pendingSamples: Int,
        interruptedBuffers: Int = 0,
        interruptedSamples: Int = 0
    ) {
        logDrainRequests(
            requests,
            phase: phase,
            result: result,
            reason: reason,
            pendingBuffers: pendingBuffers,
            pendingSamples: pendingSamples,
            interruptedBuffers: interruptedBuffers,
            interruptedSamples: interruptedSamples
        )
        requests.forEach { request in
            guard request.requestedOnMainThread, !Thread.isMainThread else {
                request.completion(outcome)
                return
            }
            DispatchQueue.main.async {
                request.completion(outcome)
            }
        }
    }

    private func logDrainRequests(
        _ requests: [DrainRequest],
        phase: String,
        result: String,
        reason: String,
        pendingBuffers: Int,
        pendingSamples: Int,
        interruptedBuffers: Int = 0,
        interruptedSamples: Int = 0
    ) {
        let now = uptime()
        for request in requests {
            let elapsedMilliseconds = max(0, Int((now - request.startedAtUptime) * 1_000))
            logger(
                "AUDIO DRAIN operation_id=\(request.operationID) source=\(request.source) " +
                    "phase=\(phase) result=\(result) reason=\(reason) " +
                    "elapsed_ms=\(elapsedMilliseconds) pending_buffers=\(pendingBuffers) " +
                    "pending_samples=\(pendingSamples) interrupted_buffers=\(interruptedBuffers) " +
                    "interrupted_samples=\(interruptedSamples)"
            )
        }
    }

    private static func milliseconds(_ interval: TimeInterval?) -> Int {
        guard let interval else { return -1 }
        return max(0, Int(interval * 1_000))
    }

    func diagnosticState() -> String {
        let state = cachedOutputState
        let isBound: String
        if let selectedDevice = state.selectedDevice, let actualOutput = state.actualDevice {
            isBound = selectedDevice.id == actualOutput.id ? "true" : "false"
        } else {
            isBound = "unknown"
        }
        return "engine_running=\(state.engineRunning) player_playing=\(state.playerPlaying) " +
            "selected={\(CoreAudioDeviceCatalog.deviceDiagnostic(state.selectedDevice))} " +
            "actual_output={\(CoreAudioDeviceCatalog.deviceDiagnostic(state.actualDevice))} " +
            "bound_to_selected=\(isBound) \(state.route)"
    }

    func diagnosticSnapshot(deliveryGeneration: Int? = nil) -> VirtualAudioOutputDiagnosticSnapshot {
        let state = cachedOutputState
        let boundToSelected: Bool?
        if let selectedDevice = state.selectedDevice, let actualOutput = state.actualDevice {
            boundToSelected = selectedDevice.id == actualOutput.id
        } else {
            boundToSelected = nil
        }
        playbackLock.lock()
        let pendingBuffers: Int
        let pendingSamples: Int
        let counters: VirtualAudioPlaybackCounters
        if let deliveryGeneration {
            let pending = pendingByDeliveryGeneration[deliveryGeneration] ?? .init()
            pendingBuffers = pending.buffers
            pendingSamples = pending.samples
            counters = playbackCountersByDeliveryGeneration[deliveryGeneration] ?? .init()
            pruneDeliveryDiagnostics(keeping: deliveryGeneration)
        } else {
            pendingBuffers = pendingVoiceBufferCount
            pendingSamples = pendingVoiceSampleCount
            counters = playbackCounters
        }
        playbackLock.unlock()
        let now = uptime()
        let audibilityHealthy: Bool
        if let selected = state.selectedDevice {
            audibilityHealthy = audibilityCache.value(for: selected.id, at: now) {
                !CoreAudioDeviceCatalog.virtualAudioAudibilitySnapshot(for: selected).requiresAudibilityRepair
            }
        } else {
            audibilityHealthy = true
        }
        return VirtualAudioOutputDiagnosticSnapshot(
            selectedDeviceKind: .classify(state.selectedDevice),
            actualDeviceKind: .classify(state.actualDevice),
            engineRunning: state.engineRunning,
            playerPlaying: state.playerPlaying,
            boundToSelectedDevice: boundToSelected,
            audibilityHealthy: audibilityHealthy,
            pendingBuffers: pendingBuffers,
            pendingSamples: pendingSamples,
            counters: counters
        )
    }

    func recordPendingDeliveriesAsInterrupted() {
        for (generation, pending) in pendingByDeliveryGeneration {
            playbackCountersByDeliveryGeneration[generation, default: .init()].interruptedBuffers += pending.buffers
            playbackCountersByDeliveryGeneration[generation, default: .init()].interruptedSamples += pending.samples
        }
        pendingByDeliveryGeneration.removeAll(keepingCapacity: true)
    }

    private func pruneDeliveryDiagnostics(keeping generation: Int) {
        guard playbackCountersByDeliveryGeneration.count > 32 else { return }
        let minimumGeneration = max(0, generation - 16)
        playbackCountersByDeliveryGeneration = playbackCountersByDeliveryGeneration.filter {
            $0.key >= minimumGeneration || pendingByDeliveryGeneration[$0.key] != nil
        }
    }

    func basicDiagnosticState() -> String {
        let state = cachedOutputState
        return "engine_running=\(state.engineRunning) player_playing=\(state.playerPlaying) " +
            "selected={\(CoreAudioDeviceCatalog.deviceDiagnostic(state.selectedDevice))}"
    }
}
