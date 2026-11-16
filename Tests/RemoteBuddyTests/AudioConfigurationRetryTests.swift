import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Integrated microphone readiness")
@MainActor
struct AudioConfigurationRetryTests {
    private func withModel(_ body: (BridgeAppModel) async throws -> Void) async throws {
        let suite = UUID().uuidString
        let values = try #require(UserDefaults(suiteName: suite))
        defer { values.removePersistentDomain(forName: suite) }
        let model = BridgeAppModel(settings: AppSettings(defaults: values))
        try await body(model)
    }

    private func mainQueueTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test(arguments: [false, true], ["startup", "test_tone", "long_recording"])
    func transientFailureRetriesOnceAndReportsFinalOutcome(recovered: Bool, demand: String) async throws {
        try await withModel { model in
            model.started = true
            switch demand {
            case "test_tone": model.audio.testToneStartupPending = true
            case "long_recording": model.longRecordingRequested = true
            default: model.audio.startupPending = true
            }
            defer { model.started = false }
            var attempts = 0
            var pending: [() -> Void] = []
            var answers: [Bool] = []
            model.configureAudioOutputWithRetry(deviceUID: model.settings.selectedAudioDeviceUID,
                generation: 0, configure: { _, done in
                    attempts += 1
                    done(attempts == 2 && recovered)
                }, scheduleRetry: { delay, action in
                    #expect(delay == 0.25)
                    pending.append(action)
                }, completion: { answers.append($0) })
            await mainQueueTurn()
            #expect(answers.isEmpty)
            #expect(pending.count == 1)
            pending.removeFirst()()
            await mainQueueTurn()
            #expect(attempts == 2)
            #expect(answers == [recovered])
            #expect(pending.isEmpty)
        }
    }

    @Test(arguments: ["new_configuration", "stop", "sleep", "idle", "quit"])
    func supersededRetryCannotReopenAudio(reason: String) async throws {
        try await withModel { model in
            model.started = true
            model.voiceSession.isActive = true
            defer { model.started = false }
            var pending: [() -> Void] = []
            var attempts = 0
            var answers: [Bool] = []
            model.configureAudioOutputWithRetry(deviceUID: model.settings.selectedAudioDeviceUID,
                generation: 0, configure: { _, done in attempts += 1; done(false) },
                scheduleRetry: { _, action in pending.append(action) },
                completion: { answers.append($0) })
            await mainQueueTurn()
            switch reason {
            case "new_configuration": model.audio.configurationGeneration += 1
            case "stop": model.started = false
            case "sleep": _ = model.audio.suspensionState.apply(.systemWillSleep)
            case "idle": model.voiceSession.isActive = false
            default: model.prepareForTermination()
            }
            try #require(pending.count == 1)
            pending.removeFirst()()
            #expect(attempts == 1)
            #expect(answers == [false])
        }
    }

    @Test func recoveryWaitsForInFlightConfigurationInsteadOfPreemptingVoiceStart() async throws {
        try await withModel { model in
            model.started = true
            model.voiceSession.isActive = true
            defer {
                model.audio.invalidatePendingWork()
                model.voiceSession.isActive = false
                model.started = false
            }

            var configureCalls = 0
            var pendingConfigureDone: ((Bool) -> Void)?
            var voiceResults: [Bool] = []
            model.configureVirtualAudioOutput(
                reason: "bluetooth_voice_start",
                configureOutput: { _, done in
                    configureCalls += 1
                    pendingConfigureDone = done
                },
                completion: { voiceResults.append($0) }
            )
            let inFlightGeneration = model.audio.configurationGeneration
            #expect(configureCalls == 1)

            var recoveryCalls = 0
            let healthySnapshot = VirtualAudioOutputDiagnosticSnapshot(
                engineRunning: true,
                playerPlaying: true,
                boundToSelectedDevice: true,
                audibilityHealthy: true,
                pendingBuffers: 0,
                pendingSamples: 0
            )
            let selectedDevice = AudioDeviceInfo(
                id: 101,
                uid: model.settings.selectedAudioDeviceUID,
                name: "Test Mic"
            )
            model.completeAudioRecoveryDeviceRefresh(
                generation: 0,
                reason: "engine_configuration_change",
                details: "",
                devices: [selectedDevice],
                outputSnapshot: healthySnapshot,
                configureOutput: { done in
                    recoveryCalls += 1
                    done(true)
                }
            )
            #expect(model.audio.configurationGeneration == inFlightGeneration)
            #expect(recoveryCalls == 0)
            #expect(voiceResults.isEmpty)

            pendingConfigureDone?(true)
            await mainQueueTurn()
            await mainQueueTurn()
            #expect(voiceResults == [true])
            #expect(recoveryCalls == 0)
            #expect(model.audio.activeConfigurationGeneration == nil)
        }
    }

    @Test func concurrentEnsureReadyJoinsInFlightConfigurationForSameDevice() async throws {
        try await withModel { model in
            model.started = true
            model.voiceSession.isActive = true
            defer {
                model.audio.invalidatePendingWork()
                model.voiceSession.isActive = false
                model.started = false
            }

            var configureCalls = 0
            var pendingConfigureDone: ((Bool) -> Void)?
            var firstResults: [Bool] = []
            var secondResults: [Bool] = []
            model.configureVirtualAudioOutput(
                reason: "bluetooth_voice_start",
                configureOutput: { _, done in
                    configureCalls += 1
                    pendingConfigureDone = done
                },
                completion: { firstResults.append($0) }
            )
            model.ensureVirtualAudioOutputReady(reason: "bluetooth_ready") {
                secondResults.append($0)
            }
            #expect(configureCalls == 1)

            pendingConfigureDone?(true)
            await mainQueueTurn()
            await mainQueueTurn()
            #expect(firstResults == [true])
            #expect(secondResults == [true])
            #expect(configureCalls == 1)
        }
    }

    @Test func supersededConfigurationForwardsResultWhileSleepCancelsWaiters() async throws {
        try await withModel { model in
            model.started = true
            model.voiceSession.isActive = true
            defer {
                model.audio.invalidatePendingWork()
                model.voiceSession.isActive = false
                model.started = false
            }

            var firstDone: ((Bool) -> Void)?
            var secondDone: ((Bool) -> Void)?
            var firstResults: [Bool] = []
            var secondResults: [Bool] = []
            model.configureVirtualAudioOutput(
                reason: "bluetooth_voice_start",
                configureOutput: { _, done in firstDone = done },
                completion: { firstResults.append($0) }
            )
            model.configureVirtualAudioOutput(
                reason: "settings_change",
                configureOutput: { _, done in secondDone = done },
                completion: { secondResults.append($0) }
            )

            firstDone?(false)
            await mainQueueTurn()
            #expect(firstResults.isEmpty)
            #expect(secondResults.isEmpty)

            secondDone?(true)
            await mainQueueTurn()
            #expect(firstResults == [true])
            #expect(secondResults == [true])

            var sleepResults: [Bool] = []
            model.configureVirtualAudioOutput(
                reason: "bluetooth_voice_start",
                configureOutput: { _, _ in },
                completion: { sleepResults.append($0) }
            )
            model.handleSystemAudioLifecycle(.systemWillSleep)
            #expect(sleepResults == [false])
        }
    }
}
