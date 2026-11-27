import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Audio recovery review regressions")
@MainActor
struct AudioRecoveryReviewTests {
    @Test func automaticRecoveryDoesNotStopContinuousRecordingBeforeRebinding() throws {
        let defaults = EphemeralUserDefaults()
        let model = BridgeAppModel(settings: AppSettings(defaults: defaults), initialAudioDevices: [])
        model.started = true
        defer {
            model.started = false
            model.finishLongRecording(reason: "test_cleanup")
        }
        model.longRecordingRequested = true
        let recordingGeneration = model.longRecordingGeneration
        let stopped = VirtualAudioOutputDiagnosticSnapshot(engineRunning: false,
            playerPlaying: false, boundToSelectedDevice: nil, pendingBuffers: 0, pendingSamples: 0)
        model.completeAudioRecoveryDeviceRefresh(generation: 0, reason: "engine_configuration_change",
            details: "", devices: [], outputSnapshot: stopped, diagnosticLog: { _ in })
        #expect(model.audio.activeConfigurationGeneration != nil)
        #expect(model.longRecordingRequested)
        #expect(model.longRecordingGeneration == recordingGeneration)
    }

    @Test(arguments: [true, false])
    func continuousRecordingStopsOnlyOnFailedRebindWhenOutputIsNotReady(configured: Bool) throws {
        let defaults = EphemeralUserDefaults()
        let model = BridgeAppModel(settings: AppSettings(defaults: defaults), initialAudioDevices: [])
        model.started = true
        defer {
            model.started = false
            model.finishLongRecording(reason: "test_cleanup")
        }
        model.longRecordingRequested = true
        model.isAudioOutputReady = true
        let recordingGeneration = model.longRecordingGeneration
        model.completeAudioRecoveryDeviceRefresh(generation: 0, reason: "engine_configuration_change",
            details: "", devices: [], configureOutput: { complete in complete(configured) },
            diagnosticLog: { _ in })
        #expect(!model.isAudioOutputReady)
        #expect(model.longRecordingRequested == configured)
        #expect((model.longRecordingGeneration == recordingGeneration) == configured)
    }

    @Test func lateEngineNotificationAfterReleaseDoesNotReconfigureOrReportDegraded() throws {
        let values = EphemeralUserDefaults()
        let model = BridgeAppModel(settings: AppSettings(defaults: values))
        model.started = true
        defer { model.started = false }
        var calls = 0
        var logs: [String] = []
        let stopped = VirtualAudioOutputDiagnosticSnapshot(engineRunning: false,
            playerPlaying: false, boundToSelectedDevice: nil, pendingBuffers: 0, pendingSamples: 0)
        model.completeAudioRecoveryDeviceRefresh(generation: 0, reason: "engine_configuration_change",
            details: "", devices: [], outputSnapshot: stopped,
            configureOutput: { _ in calls += 1 }, diagnosticLog: { logs.append($0) })
        #expect(calls == 0)
        #expect(logs.contains { $0.contains("result=ignored") && $0.contains("decision=virtual_audio_inactive") })
        #expect(!logs.contains { $0.contains("result=degraded") })
    }

    @Test(arguments: [false, true])
    func voiceEndingDuringRecoveryIsIgnoredButActiveFailureIsReported(hasTail: Bool) throws {
        let values = EphemeralUserDefaults()
        let model = BridgeAppModel(settings: AppSettings(defaults: values))
        model.started = true
        model.voiceSession.isActive = true
        defer {
            model.started = false
            model.cancelVirtualAudioReleaseIfPending(trigger: "test_cleanup")
        }
        var logs: [String] = []
        model.completeAudioRecoveryDeviceRefresh(generation: 0, reason: "engine_configuration_change",
            details: "", devices: [], configureOutput: { done in
                model.voiceSession.isActive = false
                if hasTail { model.audio.output.registerPendingVoiceBuffer() }
                done(false)
            }, diagnosticLog: { logs.append($0) })
        let expectedDecision = hasTail ? "virtual_audio_draining" : "virtual_audio_inactive"
        #expect(logs.contains { $0.contains("decision=\(expectedDecision)") })
        #expect(!logs.contains { $0.contains("result=degraded") })

        logs.removeAll()
        model.voiceSession.isActive = true
        model.completeAudioRecoveryDeviceRefresh(generation: 0, reason: "engine_configuration_change",
            details: "", devices: [], configureOutput: { $0(false) },
            diagnosticLog: { logs.append($0) })
        #expect(logs.contains { $0.contains("result=degraded") })
        #expect(!logs.contains { $0.contains("decision=virtual_audio_inactive") })
    }

    @Test(arguments: [false, true])
    func idleQueuedAudioUsesRealApplySettingsDrainWithoutDegradedRecovery(releaseFirst: Bool) async throws {
        let values = EphemeralUserDefaults()
        let clock = ControlledTestScheduler()
        let output = VirtualAudioOutput(logger: { _ in },
            uptime: { Double(clock.now) / 1_000 }, scheduleDrainDeadline: clock.voiceSchedule)
        let model = BridgeAppModel(settings: AppSettings(defaults: values), initialAudioDevices: [],
            audioRuntime: AudioRuntime(output: output))
        model.started = true
        defer {
            model.started = false
            model.cancelVirtualAudioReleaseIfPending(trigger: "test_cleanup")
        }
        output.registerPendingVoiceBuffer()
        #expect(!model.shouldKeepVirtualAudioActive)
        let generation = model.audio.configurationGeneration
        var logs: [String] = []
        var applied: [Bool] = []
        if releaseFirst { model.applyAudioSettings { applied.append($0) } }
        model.completeAudioRecoveryDeviceRefresh(generation: 0, reason: "engine_configuration_change",
            details: "", devices: [], diagnosticLog: { logs.append($0) })
        let release = try #require(model.audio.pendingVirtualAudioRelease)
        if !releaseFirst { model.applyAudioSettings { applied.append($0) } }
        #expect(applied == [false])
        #expect(model.audio.configurationGeneration == generation)
        #expect(model.audio.pendingVirtualAudioRelease?.generation == release.generation)
        #expect(output.pendingVoiceBufferCountForDiagnostics == 1)
        #expect(logs.contains { $0.contains("result=ignored") && $0.contains("decision=virtual_audio_draining") })
        #expect(!logs.contains { $0.contains("result=degraded") })
        // A repeated notification must not reset the drain's deadline.
        model.completeAudioRecoveryDeviceRefresh(generation: 0, reason: "engine_configuration_change",
            details: "", devices: [], diagnosticLog: { logs.append($0) })
        #expect(model.audio.pendingVirtualAudioRelease?.generation == release.generation)
        clock.advance(to: 749)
        #expect(output.pendingVoiceBufferCountForDiagnostics == 1)
        clock.advance(to: 750)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(output.pendingVoiceBufferCountForDiagnostics == 0)
        #expect(model.audio.pendingVirtualAudioRelease == nil)
        #expect(!logs.contains { $0.contains("result=degraded") })
    }

    @Test func stoppedActiveOutputRequestsRecoveryWithoutTheDebounceGap() async throws {
        let values = EphemeralUserDefaults()
        let model = BridgeAppModel(settings: AppSettings(defaults: values))
        model.started = true
        model.voiceSession.isActive = true
        defer { model.started = false }
        var delays: [TimeInterval] = []
        model.scheduleAudioRecovery(reason: "engine_configuration_change", schedule: { delay, _ in delays.append(delay) })
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(delays == [0])
    }

    @Test(arguments: ["hardware_change", "engine_configuration_change"])
    func healthySelectedOutputKeepsActiveAndQueuedSpeech(reason: String) throws {
        let values = EphemeralUserDefaults()
        let model = BridgeAppModel(settings: AppSettings(defaults: values))
        model.started = true
        defer { model.started = false }
        model.voiceSession.isActive = true
        model.audio.output.registerPendingVoiceBuffer()
        let device = AudioDeviceInfo(id: 101, uid: model.settings.selectedAudioDeviceUID, name: "Test Mic")
        let healthy = VirtualAudioOutputDiagnosticSnapshot(engineRunning: true,
            playerPlaying: true, boundToSelectedDevice: true, pendingBuffers: 1, pendingSamples: 32_000)
        var reconfigurations = 0
        model.completeAudioRecoveryDeviceRefresh(generation: 0, reason: reason, details: "properties=devices",
            devices: [device], outputSnapshot: healthy, configureOutput: { _ in reconfigurations += 1 })
        #expect(reconfigurations == 0)
        #expect(model.audio.output.pendingVoiceBufferCountForDiagnostics == 1)
        #expect(model.voiceSession.isActive)
        // Cached health is not sufficient after the selected device disappears.
        model.completeAudioRecoveryDeviceRefresh(generation: 0, reason: reason, details: "properties=devices",
            devices: [], outputSnapshot: healthy, configureOutput: { _ in reconfigurations += 1 })
        #expect(reconfigurations == 1)
        model.completeAudioRecoveryDeviceRefresh(generation: 99, reason: reason, details: "",
            devices: [], configureOutput: { _ in reconfigurations += 1 })
        #expect(reconfigurations == 1)
    }

    @Test func unhealthyActiveEngineStillRecoversAndBoundIdleEngineDoesNotLoop() {
        #expect(AudioEngineConfigurationChangePolicy.needsRecovery(boundToSelectedDevice: true,
            configurationHealthy: false, hasActiveAudioSource: true, pendingVoiceBufferCount: 1))
        #expect(!AudioEngineConfigurationChangePolicy.needsRecovery(boundToSelectedDevice: true,
            configurationHealthy: false, hasActiveAudioSource: false, pendingVoiceBufferCount: 0))
        #expect(AudioEngineConfigurationChangePolicy.needsRecovery(boundToSelectedDevice: false,
            configurationHealthy: false, hasActiveAudioSource: false, pendingVoiceBufferCount: 0))
    }

    @Test func inaudibleVirtualDeviceTriggersRecoveryEvenWhenEngineAndPlayerAreRunning() throws {
        let values = EphemeralUserDefaults()
        let model = BridgeAppModel(settings: AppSettings(defaults: values))
        model.started = true
        model.voiceSession.isActive = true
        defer { model.started = false }
        let device = AudioDeviceInfo(id: 101, uid: model.settings.selectedAudioDeviceUID, name: "Remote Buddy Mic")
        let inaudible = VirtualAudioOutputDiagnosticSnapshot(
            engineRunning: true,
            playerPlaying: true,
            boundToSelectedDevice: true,
            audibilityHealthy: false,
            pendingBuffers: 0,
            pendingSamples: 0
        )
        var reconfigurations = 0
        model.completeAudioRecoveryDeviceRefresh(
            generation: 0,
            reason: "hardware_change",
            details: "properties=device_mute",
            devices: [device],
            outputSnapshot: inaudible,
            configureOutput: { _ in reconfigurations += 1 }
        )
        #expect(reconfigurations == 1)
    }

    @Test func normalVolumeAdjustmentKeepsAudioOutputReadyAndDoesNotTriggerReconfiguration() throws {
        let values = EphemeralUserDefaults()
        let model = BridgeAppModel(settings: AppSettings(defaults: values))
        model.started = true
        model.voiceSession.isActive = true
        defer { model.started = false }
        model.isAudioOutputReady = true
        let device = AudioDeviceInfo(id: 101, uid: model.settings.selectedAudioDeviceUID, name: "Test Mic")
        let healthy = VirtualAudioOutputDiagnosticSnapshot(
            engineRunning: true,
            playerPlaying: true,
            boundToSelectedDevice: true,
            audibilityHealthy: true,
            pendingBuffers: 0,
            pendingSamples: 0
        )
        var reconfigurations = 0
        model.completeAudioRecoveryDeviceRefresh(
            generation: 0,
            reason: "hardware_change",
            details: "properties=device_volume",
            devices: [device],
            outputSnapshot: healthy,
            configureOutput: { _ in reconfigurations += 1 }
        )
        #expect(reconfigurations == 0)
        #expect(model.isAudioOutputReady)
    }

    @Test func healthyVolumeAfterPriorUnreadyRestoresAudioOutputReady() throws {
        let values = EphemeralUserDefaults()
        let model = BridgeAppModel(settings: AppSettings(defaults: values))
        model.started = true
        model.voiceSession.isActive = true
        defer { model.started = false }
        model.isAudioOutputReady = false
        let device = AudioDeviceInfo(id: 101, uid: model.settings.selectedAudioDeviceUID, name: "Test Mic")
        let healthy = VirtualAudioOutputDiagnosticSnapshot(
            engineRunning: true,
            playerPlaying: true,
            boundToSelectedDevice: true,
            audibilityHealthy: true,
            pendingBuffers: 0,
            pendingSamples: 0
        )
        var reconfigurations = 0
        model.completeAudioRecoveryDeviceRefresh(
            generation: 0,
            reason: "hardware_change",
            details: "properties=device_volume",
            devices: [device],
            outputSnapshot: healthy,
            configureOutput: { _ in reconfigurations += 1 }
        )
        #expect(reconfigurations == 0)
        #expect(model.isAudioOutputReady)
    }

    @Test func invalidationDuringQueryCannotRestoreStaleAudibility() async {
        let cache = AudibilityCache()
        let queryStarted = DispatchSemaphore(value: 0)
        let resumeQuery = DispatchSemaphore(value: 0)
        let firstResult = Task.detached {
            var calls = 0
            return cache.value(for: 101, at: 10) {
                calls += 1
                if calls == 1 {
                    queryStarted.signal()
                    resumeQuery.wait()
                    return false
                }
                return true
            }
        }
        #expect(queryStarted.wait(timeout: .now() + 5) == .success)
        cache.invalidate()
        let current = cache.value(for: 101, at: 10) { true }
        resumeQuery.signal()
        #expect(await firstResult.value)
        #expect(current)
        #expect(cache.value(for: 101, at: 10) { false })
    }

    @Test func audibilityCachePartitionsDevicesAndExpires() {
        let cache = AudibilityCache()
        #expect(cache.value(for: 101, at: 10) { true })
        #expect(cache.value(for: 101, at: 11) { false })
        #expect(!cache.value(for: 102, at: 11) { false })
        #expect(cache.value(for: 102, at: 13) { true })
    }
}
