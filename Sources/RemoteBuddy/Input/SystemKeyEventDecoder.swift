import AppKit
import CoreGraphics

/// Decodes `.systemDefined` CGEvents via a neutralized `.applicationDefined` copy so
/// AppKit's Caps Lock input-source handling never runs synchronously on event-tap callbacks.
enum SystemKeyEventDecoder {
    static func data1(
        from event: CGEvent,
        convert: (CGEvent) -> NSEvent? = NSEvent.init(cgEvent:)
    ) -> Int? {
        guard event.type.rawValue == NSEvent.EventType.systemDefined.rawValue,
              let snapshot = event.copy()
        else { return nil }

        guard let applicationDefined = CGEventType(
            rawValue: UInt32(NSEvent.EventType.applicationDefined.rawValue)
        ) else { return nil }
        snapshot.type = applicationDefined
        guard let decoded = convert(snapshot), decoded.subtype.rawValue == 8 else {
            return nil
        }
        return decoded.data1
    }
}
