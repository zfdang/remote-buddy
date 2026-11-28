@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import os

/// Invalidates delivery before an asynchronous engine shutdown or source handoff.
final class KeyboardMicrophoneDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private let output: VirtualAudioOutput
    private var active = true
    private var verified = false
    private var loggedFirstBatch = false

    init(output: VirtualAudioOutput) {
        self.output = output
    }

    var isActive: Bool { lock.withLock { active } }

    func verifyDevice() {
        lock.withLock { verified = true }
    }

    func cancel() {
        lock.withLock { active = false }
    }

    func send(_ samples: [Int16]) {
        lock.withLock {
            guard active, verified, output.enqueue(samples: samples) else { return }
            if !loggedFirstBatch {
                loggedFirstBatch = true
                AppLogger.shared.write("KEYBOARD MIC audio_ready samples=\(samples.count)")
            }
        }
    }
}

/// Binds to the selected Core Audio device without changing the system input.
final class KeyboardMicrophoneCapture: @unchecked Sendable {
    enum Failure: Error {
        case cancelled
        case inputUnavailable
        case unsupportedFormat
    }

    private let engine = AVAudioEngine()
    private var tapNode: AVAudioInputNode?
    private var configurationObserver: NSObjectProtocol?

    init(
        device: AudioDeviceInfo,
        delivery: KeyboardMicrophoneDelivery,
        onConfigurationChange: @escaping @Sendable () -> Void
    ) throws {
        do {
            try AudioEngineSafety.perform {
                try self.start(device: device, delivery: delivery)
            }
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { _ in onConfigurationChange() }
        } catch {
            stop()
            throw error
        }
    }

    private func start(device: AudioDeviceInfo, delivery: KeyboardMicrophoneDelivery) throws {
        guard delivery.isActive else { throw Failure.cancelled }
        let input = engine.inputNode
        guard let unit = input.audioUnit else { throw Failure.inputUnavailable }
        var deviceID = device.id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                  kAudioUnitScope_Global, 0, &deviceID, size) == noErr,
              Self.isBound(unit, deviceID: device.id) else { throw Failure.inputUnavailable }
        let source = input.outputFormat(forBus: 0)
        guard source.sampleRate > 0, source.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: target)
        else { throw Failure.unsupportedFormat }
        converter.downmix = true
        converter.primeMethod = .none
        input.installTap(onBus: 0, bufferSize: 512, format: source) { buffer, _ in
            guard delivery.isActive else { return }
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * target.sampleRate / source.sampleRate)) + 32
            guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            let inputSupplied = OSAllocatedUnfairLock(initialState: false)
            let result = converter.convert(to: converted, error: nil) { _, status in
                let shouldSupply = inputSupplied.withLock { supplied in
                    defer { supplied = true }
                    return !supplied
                }
                status.pointee = shouldSupply ? .haveData : .noDataNow
                return shouldSupply ? buffer : nil
            }
            guard result != .error, converted.frameLength > 0,
                  let samples = converted.int16ChannelData?[0] else { return }
            delivery.send(Array(UnsafeBufferPointer(start: samples, count: Int(converted.frameLength))))
        }
        tapNode = input
        guard delivery.isActive else { throw Failure.cancelled }
        engine.prepare()
        try engine.start()
        guard Self.isBound(unit, deviceID: device.id) else { throw Failure.inputUnavailable }
        delivery.verifyDevice()
    }

    private static func isBound(_ unit: AudioUnit, deviceID: AudioDeviceID) -> Bool {
        var currentID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                    kAudioUnitScope_Global, 0, &currentID, &size) == noErr &&
            currentID == deviceID
    }

    // Start and stop run on the audio preparation queue.
    func stop() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        _ = try? AudioEngineSafety.perform {
            self.engine.stop()
            self.tapNode?.removeTap(onBus: 0)
            self.tapNode = nil
        }
    }
}
