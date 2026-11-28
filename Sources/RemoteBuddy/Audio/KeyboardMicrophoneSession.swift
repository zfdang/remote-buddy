import Foundation

/// One reader activation belongs to one source. The recognizer may continue reading
/// briefly after the remote releases its trigger, so wait for it to go idle.
struct KeyboardMicrophoneSession {
    enum Transition: Equatable {
        case none
        case start
        case stop
    }

    private enum Phase {
        case waitingForIdle
        case idle
        case keyboard
    }

    private var phase: Phase = .waitingForIdle

    var ownsAudio: Bool { phase == .keyboard }

    mutating func update(readerActive: Bool, remoteActive: Bool) -> Transition {
        if !readerActive {
            let wasRecording = ownsAudio
            phase = .idle
            return wasRecording ? .stop : .none
        }
        if remoteActive { return suppress() }
        guard phase == .idle else { return .none }
        phase = .keyboard
        return .start
    }

    @discardableResult
    mutating func suppress() -> Transition {
        let wasRecording = ownsAudio
        phase = .waitingForIdle
        return wasRecording ? .stop : .none
    }
}
