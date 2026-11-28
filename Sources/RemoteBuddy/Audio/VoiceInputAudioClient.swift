import CoreAudio
import Foundation

/// Observes only the configured voice tool's public Core Audio process state.
@MainActor
final class VoiceInputAudioClient {
    private var processes: [AudioObjectID] = []
    private var lastRefresh = -Double.infinity

    func isReading(deviceID: AudioDeviceID, bundleIdentifier: String) -> Bool {
        guard #available(macOS 15.0, *) else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastRefresh >= 0.5 {
            lastRefresh = now
            processes = ((try? AudioHardwareSystem.shared.processes) ?? [])
                .filter { (try? $0.bundleID) == bundleIdentifier }
                .map(\.id)
        }
        return processes.contains { Self.isReading(deviceID: deviceID, processID: $0) }
    }

    static private func isReading(deviceID: AudioDeviceID, processID: AudioObjectID) -> Bool {
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var runningSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(processID, &runningAddress, 0, nil, &runningSize, &running) == noErr,
              running != 0 else { return false }

        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyDevices,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(processID, &deviceAddress, 0, nil, &bytes) == noErr,
              bytes >= MemoryLayout<AudioDeviceID>.stride else { return false }
        var devices = [AudioDeviceID](repeating: 0, count: Int(bytes) / MemoryLayout<AudioDeviceID>.stride)
        let status = devices.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(processID, &deviceAddress, 0, nil, &bytes, $0.baseAddress!)
        }
        return status == noErr && devices.prefix(Int(bytes) / MemoryLayout<AudioDeviceID>.stride).contains(deviceID)
    }
}
