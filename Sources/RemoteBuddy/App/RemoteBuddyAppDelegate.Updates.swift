import AppKit
import Combine
import Foundation
import Sparkle

extension RemoteBuddyAppDelegate {
    enum UpdateCheckPurpose {
        case information
        case userInitiated

        var usesInformationTimeout: Bool {
            if case .information = self { return true }
            return false
        }
    }

    func observeUpdatePreferences() {
        model.settings.$checksForPreReleaseUpdates
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] isEnabled in
                guard let self else { return }
                updateCheckTask?.cancel()
                resolvedUpdateFeedURLString = nil
                updateInformation.reset()
                let policy = UpdateCheckPolicy(checksForPreReleaseUpdates: isEnabled)
                if updaterStarted {
                    updater.automaticallyChecksForUpdates =
                        policy.allowsBackgroundUpdatePrompts
                }
                if policy.startsUpdaterAutomatically {
                    startUpdaterIfNeeded()
                    updater.resetUpdateCycleAfterShortDelay()
                    refreshUpdateInformation()
                }
            }
            .store(in: &subscriptions)
    }

    func configureUpdater() {
        let checksForPreReleaseUpdates = model.settings.checksForPreReleaseUpdates
        guard checksForPreReleaseUpdates else {
            startUpdaterIfNeeded()
            return
        }
    }

    @discardableResult
    func startUpdaterIfNeeded() -> Bool {
        if updaterStarted { return true }
        guard updateFeedSelection.validatedStableFeedURL != nil else {
            updateInformation.setUnavailable()
            return false
        }
        updater.automaticallyChecksForUpdates =
            UpdateCheckPolicy(
                checksForPreReleaseUpdates: model.settings.checksForPreReleaseUpdates
            ).allowsBackgroundUpdatePrompts
        do { try updater.start() }
        catch {
            updateInformation.setUnavailable()
            AppLogger.shared.write("UPDATE START failed " + AppLogger.errorFields(error))
            return false
        }
        updaterStarted = true
        return true
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        let includePreRelease = model.settings.checksForPreReleaseUpdates
        #if DEBUG
        if let testFeed = UpdateFeedResolver.testInjectedFeed(
            environment: ProcessInfo.processInfo.environment,
            assetName: updateFeedSelection.appcastAssetName,
            includePreRelease: includePreRelease
        ) {
            return testFeed.url.absoluteString
        }
        #endif
        if includePreRelease, let resolvedUpdateFeedURLString {
            return resolvedUpdateFeedURLString
        }
        return updateFeedSelection.feedURLString(
            checksForPreReleaseUpdates: includePreRelease
        )
    }

    @objc func checkForUpdates() {
        packageFallbackCoordinator.resetForManualCheck()
        performUpdateCheck(.userInitiated)
    }

    func refreshUpdateInformation() {
        performUpdateCheck(.information)
    }

    func performUpdateCheck(_ purpose: UpdateCheckPurpose) {
        updateCheckTask?.cancel()
        updateCheckTask = Task { [weak self] in
            guard let self else { return }
            updateInformation.beginChecking(timeoutEnabled: purpose.usesInformationTimeout)
            let includePreRelease = model.settings.checksForPreReleaseUpdates
            #if DEBUG
            let testFeed = UpdateFeedResolver.testInjectedFeed(
                environment: ProcessInfo.processInfo.environment,
                assetName: updateFeedSelection.appcastAssetName,
                includePreRelease: includePreRelease
            )
            let source = testFeed == nil ? "cloudflare_channel" : "ui_test"
            #else
            let source = "cloudflare_channel"
            #endif
            resolvedUpdateFeedURLString = nil
            if includePreRelease {
                var resolution = UpdateFeedResolver.FeedResolution(stable: nil, preview: nil)
                #if DEBUG
                if let testFeed {
                    resolution = UpdateFeedResolver.FeedResolution(stable: nil, preview: testFeed)
                }
                #endif
                if resolution.selected == nil,
                   let stableURL = updateFeedSelection.validatedStableFeedURL,
                   let previewURL = updateFeedSelection.validatedPreReleaseFeedURL {
                    resolution = await UpdateFeedResolver.resolvePreviewFeed(
                        stableURL: stableURL,
                        previewURL: previewURL
                    )
                }
                guard !Task.isCancelled else { return }
                guard let selectedFeed = resolution.selected else {
                    updateInformation.setUnavailable()
                    AppLogger.shared.write(
                        "UPDATE CHECK prerelease_enabled=true resolved=false " +
                            "stable_version=unknown preview_version=unknown " +
                            "selected_channel=unknown source=cloudflare_channel user_alert=false"
                    )
                    return
                }
                resolvedUpdateFeedURLString = selectedFeed.url.absoluteString
                AppLogger.shared.write(
                    "UPDATE CHECK prerelease_enabled=true resolved=true " +
                        "stable_version=\(resolution.stable?.version ?? "unknown") " +
                        "preview_version=\(resolution.preview?.version ?? "unknown") " +
                        "selected_channel=\(selectedFeed.isPreRelease ? "preview" : "stable") " +
                        "source=\(source)"
                )
            } else {
                guard updateFeedSelection.feedURLString(checksForPreReleaseUpdates: false) != nil else {
                    updateInformation.setUnavailable()
                    AppLogger.shared.write(
                        "UPDATE CHECK prerelease_enabled=false resolved=false " +
                            "source=cloudflare_channel user_alert=false"
                    )
                    return
                }
                AppLogger.shared.write(
                    "UPDATE CHECK prerelease_enabled=false resolved=true " +
                        "selected_channel=stable source=cloudflare_channel"
                )
            }
            guard startUpdaterIfNeeded() else { return }
            if updater.sessionInProgress {
                if case .userInitiated = purpose { updateUserDriver.showUpdateInFocus() }
                return
            }
            switch purpose {
            case .information:
                updater.checkForUpdateInformation()
            case .userInitiated:
                updater.checkForUpdates()
            }
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        updateInformation.setAvailable(
            displayVersion: item.displayVersionString,
            buildVersion: item.versionString,
            fallbackDescription: item.itemDescription
        )
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        updateInformation.setUpToDate()
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        updateInformation.setUpToDate()
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        if let fallbackURL = packageFallbackCoordinator.downloadURLOverride(
            forVersion: item.versionString,
            fileURL: item.fileURL
        ) {
            request.url = fallbackURL
        }
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        packageFallbackCoordinator.recordDownloadSucceeded(forVersion: item.versionString)
        updateUserDriver.clearFallbackState()
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        if case .retryWithFallback = packageFallbackCoordinator.recordDownloadFailure(
            forVersion: item.versionString,
            fileURL: item.fileURL,
            error: error
        ) {
            updateUserDriver.prepareForFallbackDownload(autoConfirmVersion: item.versionString)
        } else {
            updateUserDriver.clearFallbackState()
        }
    }

    func userDidCancelDownload(_ updater: SPUUpdater) {
        packageFallbackCoordinator.cancelFallback()
        updateUserDriver.clearFallbackState()
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        if error != nil, packageFallbackCoordinator.consumePendingRetry() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if updateCheck == .updatesInBackground {
                    self.updater.checkForUpdatesInBackground()
                } else {
                    self.performUpdateCheck(.userInitiated)
                }
            }
            return
        }
        if error != nil {
            updateUserDriver.clearFallbackState()
        }
        if error != nil, updateInformation.state == .checking {
            updateInformation.setUnavailable()
        }
    }
}
