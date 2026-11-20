import Foundation

/// Describes the observed transport event, not whether the user physically released Voice.
enum BluetoothVoiceStopReason: String {
    case remoteNotification = "remote_notification"
    case remoteMicrophoneRefused = "remote_microphone_refused"
    case localStop = "local_stop"
    case bridgeStopped = "bridge_stopped"
    case peripheralReset = "peripheral_reset"
    case disconnected
    case systemSuspended = "system_suspended"
    case bluetoothPoweredOff = "bluetooth_powered_off"
    case bluetoothResetting = "bluetooth_resetting"
    case centralReleased = "central_released"
    case writeResponseFailure = "write_response_failure"
    case flowControlTimeout = "flow_control_timeout"
    case closeUnacknowledged = "close_unacknowledged"
    case closeRetryExhausted = "close_retry_exhausted"
    case unsupportedCodec = "unsupported_codec"
    case sessionReplaced = "session_replaced"
    case decodeBacklog = "decode_backlog"
    case unsupportedAudio = "unsupported_audio"
    case initializationFailed = "initialization_failed"
}
