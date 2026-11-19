import Foundation
import Sparkle

/// Derives verified GitHub Release fallback URLs for packages primarily hosted on remote.zfdang.com.
enum UpdatePackageURLResolver {
    private static let primaryHost = "remote.zfdang.com"
    private static let primaryPathPrefix = "/downloads/"
    private static let githubDownloadPrefix = "https://github.com/zfdang/remote-buddy/releases/download"
    private static let packageNamePattern = try! NSRegularExpression(
        pattern: #"^Remote_Buddy_(v\d{2}-\d{2}-\d{2}\.\d{3})_macOS_(arm64|intel)\.pkg$"#
    )

    static func isPrimaryPackageURL(_ url: URL?) -> Bool {
        parsedPrimaryPackage(from: url) != nil
    }

    static func githubReleaseFallbackURL(for primaryURL: URL?) -> URL? {
        guard let parsed = parsedPrimaryPackage(from: primaryURL) else { return nil }
        return URL(string: "\(githubDownloadPrefix)/\(parsed.tag)/\(parsed.filename)")
    }

    private static func parsedPrimaryPackage(from url: URL?) -> (tag: String, filename: String)? {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https",
              components.host == primaryHost,
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.hasPrefix(primaryPathPrefix) else {
            return nil
        }

        let filename = String(components.path.dropFirst(primaryPathPrefix.count))
        guard !filename.isEmpty, !filename.contains("/") else { return nil }
        let nsFilename = filename as NSString
        let range = NSRange(location: 0, length: nsFilename.length)
        guard let match = packageNamePattern.firstMatch(in: filename, range: range),
              match.numberOfRanges == 3 else {
            return nil
        }

        let tag = nsFilename.substring(with: match.range(at: 1))
        return (tag: tag, filename: filename)
    }
}

/// Coordinates a single automatic fallback to GitHub Releases when a Pages package download fails.
struct UpdatePackageDownloadCoordinator {
    enum FailureAction: Equatable {
        case retryWithFallback(URL)
        case noFallback
    }

    private(set) var activeFallbackVersion: String?
    private(set) var activeFallbackURL: URL?
    private var pendingRetryVersion: String?
    private var attemptedFallbackVersions = Set<String>()

    var hasPendingFallback: Bool {
        pendingRetryVersion != nil
    }

    mutating func resetForManualCheck() {
        activeFallbackVersion = nil
        activeFallbackURL = nil
        pendingRetryVersion = nil
        attemptedFallbackVersions.removeAll()
    }

    mutating func cancelFallback() {
        activeFallbackVersion = nil
        activeFallbackURL = nil
        pendingRetryVersion = nil
    }

    func downloadURLOverride(forVersion version: String, fileURL: URL?) -> URL? {
        guard version == activeFallbackVersion,
              let fallbackURL = activeFallbackURL ?? UpdatePackageURLResolver.githubReleaseFallbackURL(for: fileURL) else {
            return nil
        }
        return fallbackURL
    }

    mutating func recordDownloadFailure(
        forVersion version: String,
        fileURL: URL?,
        error: Error
    ) -> FailureAction {
        switch Self.classifyDownloadError(error) {
        case .cancelled:
            cancelFallback()
            return .noFallback
        case .nonRetryable:
            activeFallbackVersion = nil
            activeFallbackURL = nil
            pendingRetryVersion = nil
            return .noFallback
        case .retryableNetworkOrHTTP:
            break
        }

        guard !attemptedFallbackVersions.contains(version),
              let fallbackURL = UpdatePackageURLResolver.githubReleaseFallbackURL(for: fileURL) else {
            activeFallbackVersion = nil
            activeFallbackURL = nil
            pendingRetryVersion = nil
            return .noFallback
        }

        attemptedFallbackVersions.insert(version)
        activeFallbackVersion = version
        activeFallbackURL = fallbackURL
        pendingRetryVersion = version
        return .retryWithFallback(fallbackURL)
    }

    private enum ErrorDisposition {
        case cancelled
        case nonRetryable
        case retryableNetworkOrHTTP
    }

    private static func classifyDownloadError(_ error: Error) -> ErrorDisposition {
        let downloadErrorCode = Int(SUError.downloadError.rawValue)
        var queue: [NSError] = [error as NSError]
        var seen = Set<ObjectIdentifier>()
        var hasNetworkOrSparkleDownloadError = false

        while !queue.isEmpty {
            let current = queue.removeFirst()
            let identifier = ObjectIdentifier(current)
            guard seen.insert(identifier).inserted else { continue }

            if (current.domain == NSURLErrorDomain && current.code == NSURLErrorCancelled)
                || (current.domain == NSCocoaErrorDomain && current.code == NSUserCancelledError) {
                return .cancelled
            }
            if current.domain == SUSparkleErrorDomain && current.code != downloadErrorCode {
                return .nonRetryable
            }
            if current.domain == NSCocoaErrorDomain
                || current.domain == NSPOSIXErrorDomain
                || current.domain == NSMachErrorDomain {
                return .nonRetryable
            }
            if current.domain == NSURLErrorDomain
                || (current.domain == SUSparkleErrorDomain && current.code == downloadErrorCode) {
                hasNetworkOrSparkleDownloadError = true
            }

            if let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError {
                queue.append(underlying)
            }
            if let multiple = current.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] {
                queue.append(contentsOf: multiple)
            }
        }

        return hasNetworkOrSparkleDownloadError ? .retryableNetworkOrHTTP : .nonRetryable
    }

    mutating func recordDownloadSucceeded(forVersion version: String) {
        if activeFallbackVersion == version {
            activeFallbackVersion = nil
            activeFallbackURL = nil
        }
        pendingRetryVersion = nil
    }

    mutating func consumePendingRetry() -> Bool {
        guard pendingRetryVersion != nil else { return false }
        pendingRetryVersion = nil
        return true
    }
}
