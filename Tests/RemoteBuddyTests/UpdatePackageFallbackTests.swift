import Foundation
import Sparkle
import Testing
@testable import RemoteBuddy

@Suite("Update package mirror fallback")
struct UpdatePackageFallbackTests {
    @Test func derivesGitHubFallbackOnlyForValidatedPagesPackageURLs() {
        let primaryArm = URL(string: "https://remote.zfdang.com/downloads/Remote_Buddy_v26-11-15.867_macOS_arm64.pkg")!
        let primaryIntel = URL(string: "https://remote.zfdang.com/downloads/Remote_Buddy_v26-11-15.867_macOS_intel.pkg")!

        #expect(UpdatePackageURLResolver.isPrimaryPackageURL(primaryArm))
        #expect(
            UpdatePackageURLResolver.githubReleaseFallbackURL(for: primaryArm)
                == URL(string: "https://github.com/zfdang/remote-buddy/releases/download/v26-11-15.867/Remote_Buddy_v26-11-15.867_macOS_arm64.pkg")!
        )
        #expect(
            UpdatePackageURLResolver.githubReleaseFallbackURL(for: primaryIntel)
                == URL(string: "https://github.com/zfdang/remote-buddy/releases/download/v26-11-15.867/Remote_Buddy_v26-11-15.867_macOS_intel.pkg")!
        )

        for invalid in [
            "http://remote.zfdang.com/downloads/Remote_Buddy_v26-11-15.867_macOS_arm64.pkg",
            "https://evil.example/downloads/Remote_Buddy_v26-11-15.867_macOS_arm64.pkg",
            "https://remote.zfdang.com/other/Remote_Buddy_v26-11-15.867_macOS_arm64.pkg",
            "https://remote.zfdang.com/downloads/Remote_Buddy_v26-11-15.867_macOS_universal.pkg",
            "https://remote.zfdang.com/downloads/Remote_Buddy_v26-11-15.867_macOS_arm64.pkg?redirect=evil",
            "https://github.com/zfdang/remote-buddy/releases/download/v26-11-15.867/Remote_Buddy_v26-11-15.867_macOS_arm64.pkg",
        ] {
            let url = URL(string: invalid)!
            #expect(!UpdatePackageURLResolver.isPrimaryPackageURL(url))
            #expect(UpdatePackageURLResolver.githubReleaseFallbackURL(for: url) == nil)
        }
    }

    @Test func defaultsToPagesURLThenFallsBackOnceToGitHubOnFailure() {
        var coordinator = UpdatePackageDownloadCoordinator()
        let primary = URL(string: "https://remote.zfdang.com/downloads/Remote_Buddy_v26-11-15.867_macOS_arm64.pkg")!
        let fallback = URL(string: "https://github.com/zfdang/remote-buddy/releases/download/v26-11-15.867/Remote_Buddy_v26-11-15.867_macOS_arm64.pkg")!

        // Default attempt keeps primary URL from enclosure.
        #expect(coordinator.downloadURLOverride(forVersion: "867", fileURL: primary) == nil)
        let initialRetry = coordinator.consumePendingRetry()
        #expect(!initialRetry)

        // First download failure from remote.zfdang.com schedules GitHub fallback.
        let networkError = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let firstAction = coordinator.recordDownloadFailure(forVersion: "867", fileURL: primary, error: networkError)
        #expect(firstAction == .retryWithFallback(fallback))
        #expect(coordinator.hasPendingFallback)
        let firstRetry = coordinator.consumePendingRetry()
        #expect(firstRetry)
        let duplicateRetry = coordinator.consumePendingRetry()
        #expect(!duplicateRetry)

        // Retry uses GitHub Releases override.
        #expect(coordinator.downloadURLOverride(forVersion: "867", fileURL: primary) == fallback)
        #expect(coordinator.downloadURLOverride(forVersion: "868", fileURL: primary) == nil)

        // If GitHub fallback also fails, no second infinite retry is scheduled.
        let secondAction = coordinator.recordDownloadFailure(forVersion: "867", fileURL: primary, error: networkError)
        #expect(secondAction == .noFallback)
        #expect(!coordinator.hasPendingFallback)
        #expect(coordinator.downloadURLOverride(forVersion: "867", fileURL: primary) == nil)

        // Manual check resets fallback attempts so remote.zfdang.com is tried first again.
        coordinator.resetForManualCheck()
        let thirdAction = coordinator.recordDownloadFailure(forVersion: "867", fileURL: primary, error: networkError)
        #expect(thirdAction == .retryWithFallback(fallback))
    }

    @Test func cancellationDoesNotTriggerFallbackRetry() {
        var coordinator = UpdatePackageDownloadCoordinator()
        let primary = URL(string: "https://remote.zfdang.com/downloads/Remote_Buddy_v26-11-15.867_macOS_arm64.pkg")!
        let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)

        let action = coordinator.recordDownloadFailure(forVersion: "867", fileURL: primary, error: cancelled)
        #expect(action == .noFallback)
        #expect(!coordinator.hasPendingFallback)
        let retried = coordinator.consumePendingRetry()
        #expect(!retried)
    }

    @Test func retriesSparkleWrappedNetworkAndHttpErrorsButNotDiskOrSignatureErrors() {
        let primary = URL(string: "https://remote.zfdang.com/downloads/Remote_Buddy_v26-11-15.867_macOS_arm64.pkg")!
        let fallback = URL(string: "https://github.com/zfdang/remote-buddy/releases/download/v26-11-15.867/Remote_Buddy_v26-11-15.867_macOS_arm64.pkg")!

        // Sparkle wraps NSURLErrorDomain failures and HTTP >= 400 download status errors as SUDownloadError.
        var wrappedCoordinator = UpdatePackageDownloadCoordinator()
        let wrappedTimeout = NSError(
            domain: SUSparkleErrorDomain,
            code: Int(SUError.downloadError.rawValue),
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)]
        )
        #expect(
            wrappedCoordinator.recordDownloadFailure(forVersion: "867", fileURL: primary, error: wrappedTimeout)
                == .retryWithFallback(fallback)
        )

        var httpCoordinator = UpdatePackageDownloadCoordinator()
        let httpError = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.downloadError.rawValue))
        #expect(
            httpCoordinator.recordDownloadFailure(forVersion: "867", fileURL: primary, error: httpError)
                == .retryWithFallback(fallback)
        )

        // Signature failures, temp directory errors, and local disk-full errors must not retry.
        for nonRetryable in [
            NSError(domain: SUSparkleErrorDomain, code: Int(SUError.signatureError.rawValue)),
            NSError(domain: SUSparkleErrorDomain, code: Int(SUError.temporaryDirectoryError.rawValue)),
            NSError(
                domain: SUSparkleErrorDomain,
                code: Int(SUError.downloadError.rawValue),
                userInfo: [NSUnderlyingErrorKey: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)]
            ),
            NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)),
        ] {
            var coordinator = UpdatePackageDownloadCoordinator()
            #expect(
                coordinator.recordDownloadFailure(forVersion: "867", fileURL: primary, error: nonRetryable)
                    == .noFallback
            )
            #expect(!coordinator.hasPendingFallback)
            let retried = coordinator.consumePendingRetry()
            #expect(!retried)
        }
    }
}
