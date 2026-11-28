import AppKit
import AVFoundation
import CoreAudio
import Foundation

@MainActor
final class KeyboardMicrophoneRuntime {
    let client = VoiceInputAudioClient()
    var session = KeyboardMicrophoneSession()
    var timer: Timer?
    var delivery: KeyboardMicrophoneDelivery?
    var capture: KeyboardMicrophoneCapture?
    var startedAt: TimeInterval = 0
    var canRestartInput = false
    var sendingStopKey = false

    isolated deinit {
        timer?.invalidate()
        delivery?.cancel()
    }
}

extension BridgeAppModel {
    private static let keyboardMicrophoneClientBundleID = "com.bytedance.inputmethod.doubaoime"

    var configuredKeyboardMicrophoneKey: VoiceKeyMode? {
        guard #available(macOS 15.0, *), settings.onboardingVoiceTool == .doubao,
              !settings.keyboardMicrophoneUID.isEmpty else { return nil }
        return settings.keyboardMicrophoneToggleKey
    }

    func refreshKeyboardMicrophoneDevices() {
        audio.preparationQueue.async { [weak self] in
            let devices = CoreAudioDeviceCatalog.inputDevices().filter {
                VirtualAudioDeviceDiagnosticKind.classify($0) == .other
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.started else { return }
                self.keyboardMicrophoneDevices = devices
                if self.keyboardMicrophone.delivery != nil,
                   !devices.contains(where: { $0.uid == self.settings.keyboardMicrophoneUID }) {
                    self.suppressKeyboardMicrophoneCapture(reason: "device_removed")
                }
                self.refreshKeyboardMicrophoneStatus()
            }
        }
    }

    func requestKeyboardMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.refreshKeyboardMicrophoneStatus() }
        }
    }

    func synchronizeKeyboardMicrophone() {
        stopKeyboardMicrophone(reason: "configuration_changed")
        refreshKeyboardMicrophoneStatus()
        guard started, !audio.suspensionState.isSuspended,
              configuredKeyboardMicrophoneKey != nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkKeyboardMicrophoneClient() }
        }
        keyboardMicrophone.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private var remoteOwnsMicrophone: Bool {
        longRecordingRequested || g9n9nSmartToggle.isActive || voiceSession.isActive ||
            voiceSession.pendingStart.identifier != nil || voiceSession.pendingKeyRelease != nil ||
            pendingVoiceKeyActivationOwner == .bluetooth || hasPendingBluetoothVoiceWork
    }

    private func checkKeyboardMicrophoneClient() {
        guard !isTerminating, !audio.suspensionState.isSuspended,
              configuredKeyboardMicrophoneKey != nil else { return }
        guard let device = BuddyMicrophoneDevicePolicy.device(in: audioDevices) else {
            if keyboardMicrophone.delivery != nil {
                suppressKeyboardMicrophoneCapture(reason: "output_removed")
            }
            return
        }
        let reading = keyboardMicrophone.client.isReading(
            deviceID: device.id, bundleIdentifier: Self.keyboardMicrophoneClientBundleID
        )
        let remoteActive = remoteOwnsMicrophone
        switch keyboardMicrophone.session.update(readerActive: reading, remoteActive: remoteActive) {
        case .none:
            break
        case .start:
            startKeyboardMicrophoneCapture()
        case .stop:
            stopKeyboardMicrophoneCapture(reason: remoteActive ? "remote_session" : "reader_stopped")
        }
        if keyboardMicrophone.delivery != nil,
           ProcessInfo.processInfo.systemUptime - keyboardMicrophone.startedAt >= settings.voiceAutoStopDuration.timeInterval {
            suppressKeyboardMicrophoneCapture(reason: "time_limit")
        }
    }

    private func startKeyboardMicrophoneCapture() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              let source = keyboardMicrophoneDevices.first(where: { $0.uid == settings.keyboardMicrophoneUID })
        else {
            refreshKeyboardMicrophoneStatus()
            return
        }

        let delivery = KeyboardMicrophoneDelivery(output: audio.output)
        keyboardMicrophone.delivery = delivery
        keyboardMicrophone.startedAt = ProcessInfo.processInfo.systemUptime
        keyboardMicrophone.canRestartInput = true
        cancelVirtualAudioReleaseIfPending(trigger: "keyboard_microphone")
        ensureVirtualAudioOutputReady(reason: "keyboard_microphone") { [weak self] ready in
            guard let self, self.keyboardMicrophone.delivery === delivery else { return }
            guard ready, !self.remoteOwnsMicrophone else {
                self.suppressKeyboardMicrophoneCapture(reason: "output_unavailable")
                return
            }
            self.openKeyboardMicrophone(source, delivery: delivery)
        }
    }

    private func openKeyboardMicrophone(_ device: AudioDeviceInfo, delivery: KeyboardMicrophoneDelivery) {
        let preparationQueue = audio.preparationQueue
        preparationQueue.async { [weak self] in
            guard delivery.isActive else { return }
            let capture = try? KeyboardMicrophoneCapture(
                device: device, delivery: delivery, preparationQueue: preparationQueue
            ) { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.keyboardMicrophone.delivery === delivery else { return }
                    self.restartKeyboardMicrophoneAfterInputChange(device)
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.keyboardMicrophone.delivery === delivery else {
                    if let capture {
                        preparationQueue.async { capture.stop() }
                    }
                    return
                }
                guard let capture else {
                    self.suppressKeyboardMicrophoneCapture(reason: "input_unavailable")
                    self.keyboardMicrophoneStatus = LocalizedMessage("keyboard_microphone.input_unavailable")
                    return
                }
                self.keyboardMicrophone.capture = capture
                self.refreshKeyboardMicrophoneStatus()
                AppLogger.shared.write("KEYBOARD MIC started")
            }
        }
    }

    private func restartKeyboardMicrophoneAfterInputChange(_ device: AudioDeviceInfo) {
        guard keyboardMicrophone.canRestartInput, !remoteOwnsMicrophone,
              let destination = BuddyMicrophoneDevicePolicy.device(in: audioDevices),
              keyboardMicrophone.client.isReading(
                  deviceID: destination.id, bundleIdentifier: Self.keyboardMicrophoneClientBundleID
              ),
              let currentDevice = CoreAudioDeviceCatalog.deviceInfo(for: device.id),
              currentDevice.uid == device.uid
        else {
            suppressKeyboardMicrophoneCapture(reason: "input_configuration_changed")
            return
        }
        keyboardMicrophone.canRestartInput = false
        if let capture = keyboardMicrophone.capture {
            keyboardMicrophone.capture = nil
            audio.preparationQueue.async { capture.stop() }
        }
        let delivery = KeyboardMicrophoneDelivery(output: audio.output)
        keyboardMicrophone.delivery = delivery
        openKeyboardMicrophone(currentDevice, delivery: delivery)
        AppLogger.shared.write("KEYBOARD MIC restarting reason=input_configuration_changed")
    }

    func stopKeyboardMicrophone(reason: String) {
        keyboardMicrophone.timer?.invalidate()
        keyboardMicrophone.timer = nil
        suppressKeyboardMicrophoneCapture(reason: reason)
    }

    func suppressKeyboardMicrophoneCapture(reason: String) {
        keyboardMicrophone.session.suppress()
        stopKeyboardMicrophoneCapture(reason: reason)
    }

    private func stopKeyboardMicrophoneCapture(reason: String) {
        guard let delivery = keyboardMicrophone.delivery else { return }
        delivery.cancel()
        keyboardMicrophone.delivery = nil
        if let capture = keyboardMicrophone.capture {
            keyboardMicrophone.capture = nil
            audio.preparationQueue.async { capture.stop() }
        }
        audio.output.endSession()
        releaseVirtualAudioOutputIfUnused(reason: "keyboard_microphone_stopped")
        refreshKeyboardMicrophoneStatus()
        AppLogger.shared.write("KEYBOARD MIC stopped reason=\(reason)")
    }

    func refreshKeyboardMicrophoneStatus() {
        let key: String
        if configuredKeyboardMicrophoneKey == nil {
            key = "disabled"
        } else if keyboardMicrophone.capture != nil {
            key = "active"
        } else if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            key = "needs_permission"
        } else if !keyboardMicrophoneDevices.contains(where: { $0.uid == settings.keyboardMicrophoneUID }) {
            key = "input_unavailable"
        } else {
            key = "ready"
        }
        let status = LocalizedMessage("keyboard_microphone." + key)
        if keyboardMicrophoneStatus != status { keyboardMicrophoneStatus = status }
    }

    /// A remote trigger closes an existing keyboard session with that tool's
    /// hands-free toggle. Stop the physical input before posting the key.
    func stopKeyboardMicrophoneFromRemote(closeRemote: () -> Bool = { true }) -> Bool {
        guard let mode = configuredKeyboardMicrophoneKey,
              keyboardMicrophone.session.ownsAudio || keyboardMicrophone.sendingStopKey
        else { return false }
        if keyboardMicrophone.sendingStopKey {
            _ = closeRemote()
            return true
        }
        guard let device = BuddyMicrophoneDevicePolicy.device(in: audioDevices),
              keyboardMicrophone.client.isReading(
                deviceID: device.id, bundleIdentifier: Self.keyboardMicrophoneClientBundleID
              )
        else {
            suppressKeyboardMicrophoneCapture(reason: "reader_stopped")
            return false
        }
        let closed = closeRemote()
        suppressKeyboardMicrophoneCapture(reason: "remote_stop_key")
        guard KeyboardInjector.setVoiceKeyPressed(mode, isPressed: true) else {
            AppLogger.shared.write("KEYBOARD MIC remote_stop close=\(closed) result=press_failed")
            return true
        }
        keyboardMicrophone.sendingStopKey = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(105)) { [weak self] in
            let released = KeyboardInjector.setVoiceKeyPressed(mode, isPressed: false)
            self?.keyboardMicrophone.sendingStopKey = false
            if released { KeyboardInjector.startPostVoicePhantomModifierSweep() }
            AppLogger.shared.write("KEYBOARD MIC remote_stop close=\(closed) released=\(released)")
        }
        return true
    }
}
