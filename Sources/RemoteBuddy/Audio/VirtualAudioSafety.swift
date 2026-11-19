@preconcurrency import AVFoundation
import AudioExceptionGuard
import CoreAudio
import Foundation

enum AudioEngineSafety {
    enum Failure: Error { case objectiveCException }

    /// Swift errors and AVFoundation exceptions require separate boundaries.
    static func perform(_ operation: @escaping () throws -> Void) throws {
        var swiftError: Error?
        let succeeded = RemoteBuddyTryAudioOperation {
            do { try operation() } catch { swiftError = error }
        }
        guard succeeded else { throw Failure.objectiveCException }
        if let swiftError { throw swiftError }
    }
}

enum AudioPlayerNodeSafety {
    static func play(_ player: AVAudioPlayerNode) -> Bool {
        RemoteBuddyTryPlayAudioPlayerNode(player)
    }

    static func schedule(_ player: AVAudioPlayerNode, buffer: AVAudioPCMBuffer,
                         completion: @escaping @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void) -> Bool {
        RemoteBuddyTryAudioOperation {
            player.scheduleBuffer(buffer, at: nil, options: [],
                completionCallbackType: .dataPlayedBack, completionHandler: completion)
        }
    }

    static func reset(_ player: AVAudioPlayerNode) -> Bool {
        RemoteBuddyTryAudioOperation {
            player.stop()
            player.reset()
        }
    }
}

enum VirtualAudioDrainOutcome: String, Equatable {
    case normal
    case forced
}

/// Protects cache state without holding a lock during CoreAudio calls.
final class AudibilityCache: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var cached: (deviceID: AudioObjectID, checkTime: TimeInterval, healthy: Bool)?

    func invalidate() {
        lock.withLock {
            generation &+= 1
            cached = nil
        }
    }

    func value(for deviceID: AudioObjectID, at time: TimeInterval, query: () -> Bool) -> Bool {
        for _ in 0..<4 {
            let state = lock.withLock { () -> (Bool?, UInt64) in
                if let cached, cached.deviceID == deviceID, time - cached.checkTime < 2.0 {
                    return (cached.healthy, generation)
                }
                return (nil, generation)
            }
            if let value = state.0 { return value }
            let value = query()
            let accepted = lock.withLock { () -> Bool in
                guard generation == state.1 else { return false }
                cached = (deviceID, time, value)
                return true
            }
            if accepted { return value }
        }
        return query()
    }
}
