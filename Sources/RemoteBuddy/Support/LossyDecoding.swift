import Foundation

/// Collects the coding paths of entries a lossy decode skipped, so a partial load can be
/// reported instead of silently shrinking the data.
final class LossyDecodingLog: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [[String]] = []

    var droppedPaths: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }

    func record(_ codingPath: [any CodingKey]) {
        let path = codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }
        lock.lock()
        paths.append(path)
        lock.unlock()
    }
}

extension CodingUserInfoKey {
    static let lossyDecodingLog = CodingUserInfoKey(rawValue: "lossyDecodingLog")!
}

extension Decoder {
    var lossyDecodingLog: LossyDecodingLog? {
        userInfo[.lossyDecodingLog] as? LossyDecodingLog
    }
}

extension JSONDecoder {
    static func lossy(log: LossyDecodingLog) -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.userInfo[.lossyDecodingLog] = log
        return decoder
    }
}

struct LossyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

/// Consumes one array element without reading it, so decoding can move past a bad entry.
private struct SkippedElement: Decodable {
    init(from decoder: Decoder) {}
}

/// Decodes each element on its own; an element that cannot be read is dropped and logged.
struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            let path = container.codingPath + [LossyCodingKey(intValue: container.currentIndex)]
            do {
                elements.append(try container.decode(Element.self))
            } catch {
                if try !container.decodeNil() { _ = try container.decode(SkippedElement.self) }
                decoder.lossyDecodingLog?.record(path)
            }
        }
        self.elements = elements
    }
}

/// Decodes each value of a string-keyed object on its own; unreadable values are dropped and logged.
struct LossyDictionary<Value: Decodable>: Decodable {
    var entries: [String: Value]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: LossyCodingKey.self)
        var entries: [String: Value] = [:]
        for key in container.allKeys {
            do {
                entries[key.stringValue] = try container.decode(Value.self, forKey: key)
            } catch {
                decoder.lossyDecodingLog?.record(container.codingPath + [key])
            }
        }
        self.entries = entries
    }
}

/// A single value that decodes to nil, and is logged, when it cannot be read.
private struct LossyValue<Value: Decodable>: Decodable {
    var value: Value?

    init(from decoder: Decoder) {
        do {
            value = try decoder.singleValueContainer().decode(Value.self)
        } catch {
            value = nil
            decoder.lossyDecodingLog?.record(decoder.codingPath)
        }
    }
}

extension KeyedDecodingContainer {
    /// A missing or null key reads as empty; a value that is not an object is logged and reads as empty.
    func decodeLossyDictionary<Value: Decodable>(_ type: Value.Type, forKey key: Key) -> [String: Value] {
        decodeLossyIfPresent(LossyDictionary<Value>.self, forKey: key)?.entries ?? [:]
    }

    func decodeLossyIfPresent<Value: Decodable>(_ type: Value.Type, forKey key: Key) -> Value? {
        (try? decodeIfPresent(LossyValue<Value>.self, forKey: key))?.value
    }
}
