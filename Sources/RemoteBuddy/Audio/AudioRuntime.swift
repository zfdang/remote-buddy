import CoreAudio
import Foundation

/// Owns audio resources and asynchronous recovery lifetimes. State is main-queue
/// confined; engine work and HAL notifications keep their dedicated queues.
@MainActor
final class AudioRuntime {
    typealias AudioHardwareListenerRemover = (
        inout AudioObjectPropertyAddress, DispatchQueue, @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus
    let output: VirtualAudioOutput

    init(output: VirtualAudioOutput = VirtualAudioOutput()) {
        self.output = output
    }
    let preparationQueue = DispatchQueue(label: "RemoteBuddy.audioPreparation", qos: .userInitiated)
    var configurationGeneration: UInt64 = 0
    var activeConfigurationGeneration: UInt64?
    var activeConfigurationDeviceUID: String?
    private(set) var configurationWaiters: [UInt64: [(Bool) -> Void]] = [:]

    func beginConfiguration(
        generation: UInt64,
        deviceUID: String,
        adoptExistingWaiters: Bool = false
    ) {
        if let previousGeneration = activeConfigurationGeneration,
           previousGeneration != generation {
            if adoptExistingWaiters,
               let previousWaiters = configurationWaiters.removeValue(forKey: previousGeneration),
               !previousWaiters.isEmpty {
                configurationWaiters[generation, default: []].append(contentsOf: previousWaiters)
            } else {
                resolveConfigurationWaiters(generation: previousGeneration, configured: false)
            }
        }
        activeConfigurationGeneration = generation
        activeConfigurationDeviceUID = deviceUID
    }

    func addConfigurationWaiter(generation: UInt64, _ completion: @escaping (Bool) -> Void) {
        configurationWaiters[generation, default: []].append(completion)
    }

    func resolveConfigurationWaiters(generation: UInt64, configured: Bool) {
        if activeConfigurationGeneration == generation {
            activeConfigurationGeneration = nil
            activeConfigurationDeviceUID = nil
        }
        guard let waiters = configurationWaiters.removeValue(forKey: generation) else { return }
        for waiter in waiters {
            waiter(configured)
        }
    }

    func cancelAllConfigurationWaiters() {
        activeConfigurationGeneration = nil
        activeConfigurationDeviceUID = nil
        let pending = configurationWaiters
        configurationWaiters.removeAll()
        for generation in pending.keys.sorted() {
            for waiter in pending[generation] ?? [] {
                waiter(false)
            }
        }
    }
    var startupGeneration: UInt64 = 0
    var deviceRefreshGeneration: UInt64 = 0
    var startupPending = false
    var hardwareListenerRemover: AudioHardwareListenerRemover = { address, queue, listener in
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
    }
    var devicePropertyListenerRemover: (AudioObjectID, inout AudioObjectPropertyAddress, DispatchQueue, @escaping AudioObjectPropertyListenerBlock) -> OSStatus = { objectID, address, queue, listener in
        AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, listener)
    }
    let hardwareListenerQueue = DispatchQueue(label: "RemoteBuddy.audioHardware")
    var observedHardwareAddresses: [AudioObjectPropertyAddress] = []
    var observedDeviceProperties: [(objectID: AudioObjectID, address: AudioObjectPropertyAddress)] = []
    var recoveryWorkItem: DispatchWorkItem?
    var recoveryGeneration: UInt64 = 0
    var recoveryCoalescingState = AudioRecoveryCoalescingState()
    var virtualAudioReleaseGeneration: UInt64 = 0
    var pendingVirtualAudioRelease: (generation: UInt64, reason: String)?
    var suspensionState = SystemAudioSuspensionState()

    private(set) var registeredListener: AudioObjectPropertyListenerBlock?

    func retainHardwareListener(_ listener: @escaping AudioObjectPropertyListenerBlock) {
        registeredListener = listener
    }

    func stopObservingHardware() {
        guard let listener = registeredListener else { return }
        for var address in observedHardwareAddresses {
            _ = hardwareListenerRemover(&address, hardwareListenerQueue, listener)
        }
        observedHardwareAddresses.removeAll()
        stopObservingVirtualDevice()
        registeredListener = nil
    }

    func stopObservingVirtualDevice() {
        guard let listener = registeredListener else {
            observedDeviceProperties.removeAll()
            return
        }
        for (objectID, var address) in observedDeviceProperties {
            _ = devicePropertyListenerRemover(objectID, &address, hardwareListenerQueue, listener)
        }
        observedDeviceProperties.removeAll()
    }

    func invalidatePendingWork() {
        startupGeneration &+= 1
        deviceRefreshGeneration &+= 1
        configurationGeneration &+= 1
        cancelAllConfigurationWaiters()
        startupPending = false
        recoveryGeneration &+= 1
        recoveryWorkItem?.cancel()
        recoveryWorkItem = nil
        recoveryCoalescingState.reset()
        virtualAudioReleaseGeneration &+= 1
        pendingVirtualAudioRelease = nil
        suspensionState = SystemAudioSuspensionState()
    }

    isolated deinit {
        invalidatePendingWork()
        stopObservingHardware()
    }
}
