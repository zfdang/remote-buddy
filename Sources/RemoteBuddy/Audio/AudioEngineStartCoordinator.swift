import Foundation

/// Result of building, preparing, and starting an audio engine inside a bounded worker.
enum AudioEngineStartOutcome<Value> {
    case ready(Value)
    case failed(Error)
    case timedOut
}

/// Cancellation token shared with a worker that may be blocked in Core Audio HAL calls.
final class AudioEngineStartToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Runs Core Audio graph construction and startup off the serial audio output queue
/// under a bounded wall-clock wait so a wedged HAL call cannot stall future requests.
struct AudioEngineStartCoordinator {
    typealias QueueFactory = (_ operationID: UInt64, _ attempt: Int) -> DispatchQueue
    typealias Work<Value> = (AudioEngineStartToken) throws -> Value

    static let defaultTimeout: TimeInterval = 2

    private let timeout: TimeInterval
    private let queueFactory: QueueFactory
    private let cleanupQueue: DispatchQueue

    init(
        timeout: TimeInterval = Self.defaultTimeout,
        queueFactory: @escaping QueueFactory = Self.makeQueue,
        cleanupQueue: DispatchQueue = DispatchQueue.global(qos: .userInitiated)
    ) {
        self.timeout = timeout
        self.queueFactory = queueFactory
        self.cleanupQueue = cleanupQueue
    }

    func run<Value>(
        operationID: UInt64,
        attempt: Int,
        work: @escaping Work<Value>,
        cleanup: @escaping @Sendable () -> Void
    ) -> AudioEngineStartOutcome<Value> {
        let token = AudioEngineStartToken()
        let queue = queueFactory(operationID, attempt)
        let semaphore = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        nonisolated(unsafe) var outcome: AudioEngineStartOutcome<Value> = .failed(
            AudioEngineStartError.cancelled
        )

        nonisolated(unsafe) let work = work
        queue.async {
            let result: AudioEngineStartOutcome<Value>
            do {
                let value = try work(token)
                result = token.isCancelled ? .timedOut : .ready(value)
            } catch {
                result = token.isCancelled ? .timedOut : .failed(error)
            }
            if token.isCancelled {
                // Run cleanup once more after late work finishes in case the graph was
                // constructed after the immediate off-queue timeout cleanup ran.
                cleanup()
            }
            resultLock.lock()
            outcome = result
            resultLock.unlock()
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            token.cancel()
            cleanupQueue.async(execute: cleanup)
            return .timedOut
        }

        resultLock.lock()
        defer { resultLock.unlock() }
        return outcome
    }

    func start(
        operationID: UInt64,
        attempt: Int,
        start: @escaping Work<Void>,
        cleanup: @escaping @Sendable () -> Void
    ) -> AudioEngineStartOutcome<Void> {
        run(operationID: operationID, attempt: attempt, work: start, cleanup: cleanup)
    }

    private static func makeQueue(operationID: UInt64, attempt: Int) -> DispatchQueue {
        DispatchQueue(
            label: "RemoteBuddy.audioOutput.prepare.\(operationID).\(attempt)",
            qos: .userInitiated
        )
    }
}

enum AudioEngineStartError: Error {
    case cancelled
}
