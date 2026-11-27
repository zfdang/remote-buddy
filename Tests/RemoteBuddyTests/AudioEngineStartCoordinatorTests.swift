@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import RemoteBuddy

private enum AudioEngineStartTestError: Error {
    case expectedFailure
}

private final class LockedLogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func append(_ entry: String) {
        lock.lock()
        entries.append(entry)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

private final class LockedIntBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@Suite("Audio engine start coordinator")
struct AudioEngineStartCoordinatorTests {
    @Test func coordinatorReturnsReadyWhenWorkCompletesBeforeTimeout() {
        let coordinator = AudioEngineStartCoordinator(timeout: 0.5)
        let cleanupCount = LockedIntBox()
        let outcome = coordinator.run(
            operationID: 1,
            attempt: 1,
            work: { token in
                #expect(!token.isCancelled)
                return 42
            },
            cleanup: {
                cleanupCount.increment()
            }
        )
        guard case .ready(let value) = outcome else {
            Issue.record("Expected ready outcome")
            return
        }
        #expect(value == 42)
        #expect(cleanupCount.current == 0)
    }

    @Test func coordinatorCancelsTokenRunsCleanupAndUnblocksOnTimeout() {
        let gate = DispatchSemaphore(value: 0)
        let cleanupDone = DispatchSemaphore(value: 0)
        let tokenCancelledAfterUnblock = LockedIntBox()
        defer { gate.signal() }

        let coordinator = AudioEngineStartCoordinator(timeout: 0.05)
        let outcome: AudioEngineStartOutcome<Int> = coordinator.run(
            operationID: 2,
            attempt: 1,
            work: { token in
                _ = gate.wait(timeout: .now() + 2)
                if token.isCancelled {
                    tokenCancelledAfterUnblock.increment()
                }
                return 99
            },
            cleanup: {
                cleanupDone.signal()
            }
        )

        guard case .timedOut = outcome else {
            Issue.record("Expected timedOut outcome")
            return
        }
        gate.signal()
        #expect(cleanupDone.wait(timeout: .now() + 1) == .success)
        #expect(tokenCancelledAfterUnblock.current == 1)
    }

    @Test func coordinatorRunsCleanupOnIndependentQueueEvenWhileWorkRemainsBlocked() {
        let workGate = DispatchSemaphore(value: 0)
        let workStarted = DispatchSemaphore(value: 0)
        let cleanupDone = DispatchSemaphore(value: 0)
        defer { workGate.signal() }

        let coordinator = AudioEngineStartCoordinator(timeout: 0.05)
        let outcome: AudioEngineStartOutcome<Int> = coordinator.run(
            operationID: 3,
            attempt: 1,
            work: { _ in
                workStarted.signal()
                _ = workGate.wait(timeout: .now() + 5)
                return 7
            },
            cleanup: {
                cleanupDone.signal()
            }
        )

        #expect(workStarted.wait(timeout: .now() + 1) == .success)
        guard case .timedOut = outcome else {
            Issue.record("Expected timedOut outcome")
            return
        }
        // Assert cleanup completes while work is STILL blocked on `workGate` (no signal yet).
        #expect(cleanupDone.wait(timeout: .now() + 1) == .success)
    }

    @Test func coordinatorRunsSecondCleanupAfterLateWorkBuildsGraphPostTimeout() {
        let workStarted = DispatchSemaphore(value: 0)
        let firstCleanupDone = DispatchSemaphore(value: 0)
        let allowLateBuild = DispatchSemaphore(value: 0)
        let lateCleanupDone = DispatchSemaphore(value: 0)
        defer { allowLateBuild.signal() }

        let lock = NSLock()
        nonisolated(unsafe) var hasLateGraph = false
        nonisolated(unsafe) var tornDownLateGraph = false
        nonisolated(unsafe) var cleanupCalls = 0

        let coordinator = AudioEngineStartCoordinator(timeout: 0.05)
        let outcome: AudioEngineStartOutcome<Int> = coordinator.run(
            operationID: 4,
            attempt: 1,
            work: { _ in
                workStarted.signal()
                _ = allowLateBuild.wait(timeout: .now() + 5)
                lock.lock()
                hasLateGraph = true
                lock.unlock()
                return 11
            },
            cleanup: {
                lock.lock()
                cleanupCalls += 1
                let built = hasLateGraph
                if built {
                    tornDownLateGraph = true
                }
                let callNumber = cleanupCalls
                lock.unlock()
                if callNumber == 1 {
                    firstCleanupDone.signal()
                }
                if built {
                    lateCleanupDone.signal()
                }
            }
        )

        #expect(workStarted.wait(timeout: .now() + 1) == .success)
        guard case .timedOut = outcome else {
            Issue.record("Expected timedOut outcome")
            return
        }
        #expect(firstCleanupDone.wait(timeout: .now() + 1) == .success)
        lock.lock()
        #expect(!tornDownLateGraph)
        lock.unlock()

        // Allow blocked work to finish creating the orphaned graph after timeout;
        // late-completion safety net must re-run cleanup and tear it down.
        allowLateBuild.signal()
        #expect(lateCleanupDone.wait(timeout: .now() + 1) == .success)
        lock.lock()
        #expect(tornDownLateGraph)
        #expect(cleanupCalls == 2)
        lock.unlock()
    }

    @Test func blockedAudioGraphBuildTimesOutBoundedlyAndKeepsQueueMoving() async {
        guard let device = CoreAudioDeviceCatalog.outputDevices().first else { return }
        let logs = LockedLogBox()
        let gate = DispatchSemaphore(value: 0)
        defer { for _ in 0..<4 { gate.signal() } }

        let attempts = LockedIntBox()
        let output = VirtualAudioOutput(
            logger: logs.append,
            engineStartCoordinator: AudioEngineStartCoordinator(timeout: 0.05),
            audioGraphFactory: {
                let attempt = attempts.increment()
                if attempt <= 2 {
                    _ = gate.wait(timeout: .now() + 5)
                }
                throw AudioEngineStartTestError.expectedFailure
            }
        )

        let first = AsyncStream<Bool>.makeStream()
        let startedAt = ProcessInfo.processInfo.systemUptime
        output.configureAsync(deviceUID: device.uid) { ok in
            first.continuation.yield(ok)
            first.continuation.finish()
        }
        var firstResults: [Bool] = []
        for await value in first.stream { firstResults.append(value) }
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt

        #expect(firstResults == [false])
        #expect(elapsed < 2.0)
        #expect(attempts.current == 2)
        #expect(logs.values.contains {
            $0.contains("phase=timed_out") && $0.contains("last_stage=build_graph")
        })

        let second = AsyncStream<Bool>.makeStream()
        output.configureAsync(deviceUID: device.uid) { ok in
            second.continuation.yield(ok)
            second.continuation.finish()
        }
        var secondResults: [Bool] = []
        for await value in second.stream { secondResults.append(value) }

        #expect(secondResults == [false])
        #expect(logs.values.contains { $0.contains("operation_id=2 phase=started") })
    }
}
