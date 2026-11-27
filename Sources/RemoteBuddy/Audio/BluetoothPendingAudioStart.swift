import Foundation

/// Owns an audio-configuration pre-roll for one device. Rejecting a different
/// device must not discard the original device's pending start.
final class BluetoothPendingAudioStart {
    /// Covers two bounded 2s engine start attempts plus graph/dispatch headroom at 16 kHz.
    static let startupBufferSampleCount = VoicePlaybackQueueCapacity.maximumPreRollSamples

    private(set) var identifier: UUID?
    private(set) var operationID: UUID?
    var audio = CommandVoiceActivationAudioBuffer(maximumSampleCount: startupBufferSampleCount)

    /// Appends samples while awaiting audio configuration without silently trimming leading frames.
    /// Returns the number of overflowing samples when capacity is exceeded so the caller can
    /// terminate cleanly instead of clipping the user's opening words.
    func appendPreservingOrder(_ newSamples: [Int16]) -> (accepted: Bool, overflowSamples: Int) {
        guard audio.isWaiting else { return (false, 0) }
        let overflow = max(0, audio.bufferedSampleCount + newSamples.count - Self.startupBufferSampleCount)
        if overflow > 0 {
            return (true, overflow)
        }
        _ = audio.appendIfWaiting(newSamples)
        return (true, 0)
    }

    @discardableResult
    func begin(for identifier: UUID) -> UUID {
        cancel()
        let operationID = UUID()
        self.identifier = identifier
        self.operationID = operationID
        audio.begin()
        return operationID
    }

    func matches(identifier: UUID, operationID: UUID) -> Bool {
        self.identifier == identifier && self.operationID == operationID
    }

    func drain() -> [Int16] {
        let samples = audio.drain()
        identifier = nil
        operationID = nil
        return samples
    }

    @discardableResult
    func cancel(ifOwnedBy identifier: UUID) -> Bool {
        guard self.identifier == identifier else { return false }
        cancel()
        return true
    }
    func cancel() {
        identifier = nil
        operationID = nil
        audio.cancel()
    }

}
