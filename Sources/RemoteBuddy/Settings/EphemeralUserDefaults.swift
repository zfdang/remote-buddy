import Foundation

/// In-memory `UserDefaults` subclass for tests and preview harnesses.
/// Overrides standard read/write, registration, and persistent-domain APIs so calls
/// stay in memory instead of mutating `UserDefaults.standard` or creating suite plists.
final class EphemeralUserDefaults: UserDefaults {
    private let lock = NSLock()
    private var storage: [String: Any] = [:]
    private var registered: [String: Any] = [:]

    convenience init() {
        self.init(suiteName: nil)!
    }

    override init?(suiteName suitename: String?) {
        super.init(suiteName: nil)
    }

    override func object(forKey defaultName: String) -> Any? {
        lock.withLock {
            storage[defaultName] ?? registered[defaultName]
        }
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        lock.withLock {
            guard let value else {
                storage[defaultName] = nil
                return
            }
            if let boolValue = value as? Bool, CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() {
                storage[defaultName] = NSNumber(value: boolValue)
            } else if let number = value as? NSNumber {
                storage[defaultName] = number
            } else {
                storage[defaultName] = value
            }
        }
    }

    override func set(_ value: Int, forKey defaultName: String) {
        lock.withLock { storage[defaultName] = NSNumber(value: value) }
    }

    override func set(_ value: Float, forKey defaultName: String) {
        lock.withLock { storage[defaultName] = NSNumber(value: value) }
    }

    override func set(_ value: Double, forKey defaultName: String) {
        lock.withLock { storage[defaultName] = NSNumber(value: value) }
    }

    override func set(_ value: Bool, forKey defaultName: String) {
        lock.withLock { storage[defaultName] = NSNumber(value: value) }
    }

    override func set(_ url: URL?, forKey defaultName: String) {
        lock.withLock {
            if let url {
                storage[defaultName] = url
            } else {
                storage[defaultName] = nil
            }
        }
    }

    override func removeObject(forKey defaultName: String) {
        lock.withLock {
            storage[defaultName] = nil
        }
    }

    override func string(forKey defaultName: String) -> String? {
        switch object(forKey: defaultName) {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    override func array(forKey defaultName: String) -> [Any]? {
        object(forKey: defaultName) as? [Any]
    }

    override func dictionary(forKey defaultName: String) -> [String: Any]? {
        object(forKey: defaultName) as? [String: Any]
    }

    override func data(forKey defaultName: String) -> Data? {
        object(forKey: defaultName) as? Data
    }

    override func stringArray(forKey defaultName: String) -> [String]? {
        object(forKey: defaultName) as? [String]
    }

    override func integer(forKey defaultName: String) -> Int {
        switch object(forKey: defaultName) {
        case let number as NSNumber:
            return number.intValue
        case let intValue as Int:
            return intValue
        case let string as String:
            return (string as NSString).integerValue
        default:
            return 0
        }
    }

    override func float(forKey defaultName: String) -> Float {
        switch object(forKey: defaultName) {
        case let number as NSNumber:
            return number.floatValue
        case let floatValue as Float:
            return floatValue
        case let string as String:
            return (string as NSString).floatValue
        default:
            return 0
        }
    }

    override func double(forKey defaultName: String) -> Double {
        switch object(forKey: defaultName) {
        case let number as NSNumber:
            return number.doubleValue
        case let doubleValue as Double:
            return doubleValue
        case let string as String:
            return (string as NSString).doubleValue
        default:
            return 0
        }
    }

    override func bool(forKey defaultName: String) -> Bool {
        switch object(forKey: defaultName) {
        case let boolValue as Bool:
            return boolValue
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            return (string as NSString).boolValue
        default:
            return false
        }
    }

    override func url(forKey defaultName: String) -> URL? {
        switch object(forKey: defaultName) {
        case let url as URL:
            return url
        case let string as String:
            return URL(fileURLWithPath: (string as NSString).expandingTildeInPath)
        case let data as Data:
            return (try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSURL.self, from: data)) as URL?
        default:
            return nil
        }
    }

    override func register(defaults registrationDictionary: [String: Any]) {
        lock.withLock {
            for (key, value) in registrationDictionary {
                registered[key] = value
            }
        }
    }

    override func persistentDomain(forName domainName: String) -> [String: Any]? {
        lock.withLock {
            storage.isEmpty ? nil : storage
        }
    }

    override func setPersistentDomain(_ domain: [String: Any], forName domainName: String) {
        lock.withLock {
            storage = domain
        }
    }

    override func removePersistentDomain(forName domainName: String) {
        lock.withLock {
            storage.removeAll()
        }
    }

    override func dictionaryRepresentation() -> [String: Any] {
        lock.withLock {
            registered.merging(storage) { _, new in new }
        }
    }

    override func synchronize() -> Bool {
        true
    }
}
