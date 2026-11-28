import CoreGraphics
import Foundation

struct StandaloneModifierTap {
    private var beganAt: UInt64?

    mutating func update(pressed: Bool, timestamp: UInt64) -> Bool {
        if pressed {
            if beganAt == nil { beganAt = timestamp }
            return false
        }
        defer { beganAt = nil }
        guard let beganAt, timestamp >= beganAt else { return false }
        return timestamp - beganAt <= 650_000_000
    }

    mutating func cancel() {
        beganAt = nil
    }
}

@MainActor
final class RemoteVoiceKeyboardStop {
    private var press = StandaloneModifierTap()
    private var key: VoiceKeyMode = .rightCommand
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var callbackOwner: Unmanaged<RemoteVoiceKeyboardStop>?
    private var onStop: (() -> Void)?
    private var generation: UInt64 = 0

    func start(key: VoiceKeyMode, onStop: @escaping () -> Void) {
        stop()
        self.key = key
        self.onStop = onStop
        let owner = Unmanaged.passRetained(self)
        let mask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue) |
            (CGEventMask(1) << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let listener = Unmanaged<RemoteVoiceKeyboardStop>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { listener.handle(type, event: event) }
            return Unmanaged.passUnretained(event)
        }
        for location in [CGEventTapLocation.cghidEventTap, .cgSessionEventTap] {
            guard let port = CGEvent.tapCreate(
                tap: location, place: .headInsertEventTap, options: .listenOnly,
                eventsOfInterest: mask, callback: callback, userInfo: owner.toOpaque()
            ) else { continue }
            guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
                _ = EventTapPort.release(port: port, source: nil)
                continue
            }
            tap = port
            self.source = source
            callbackOwner = owner
            EventTapPort.activate(port: port, source: source)
            AppLogger.shared.write("VOICE KEYBOARD_STOP monitoring location=\(location.rawValue)")
            return
        }
        owner.release()
        self.onStop = nil
        AppLogger.shared.write("VOICE KEYBOARD_STOP monitoring_unavailable")
    }

    func stop() {
        generation &+= 1
        press.cancel()
        onStop = nil
        let drained = EventTapPort.release(port: tap, source: source)
        tap = nil
        source = nil
        EventTapPort.finalizeOwnerRelease(callbackOwner, drained: drained) {
            AppLogger.shared.write("VOICE KEYBOARD_STOP monitor_cleanup_deferred")
        }
        callbackOwner = nil
    }

    private func handle(_ type: CGEventType, event: CGEvent) {
        let generation = self.generation
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            press.cancel()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == generation, let tap = self.tap else { return }
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }
        guard !KeyboardInjector.isSyntheticEvent(event) else { return }
        if type == .keyDown {
            press.cancel()
            return
        }
        guard type == .flagsChanged else { return }
        guard event.getIntegerValueField(.keyboardEventKeycode) == key.keyCode else {
            press.cancel()
            return
        }
        let sideSpecificFlags = key.eventFlags.rawValue & 0xFFFF
        let pressed = event.flags.rawValue & sideSpecificFlags != 0
        if press.update(pressed: pressed, timestamp: event.timestamp) {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == generation else { return }
                self.onStop?()
            }
        }
    }
}
