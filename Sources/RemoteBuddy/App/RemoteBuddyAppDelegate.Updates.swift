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
        model.settings.$receiveUpdateNotifications
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] isEnabled in
                guard let self else { return }
                updateCheckTask?.cancel()
                updateInformation.reset()
                let policy = UpdateCheckPolicy(receiveUpdateNotifications: isEnabled)
                if updaterStarted {
                    updater.automaticallyChecksForUpdates =
                        policy.enablesSparkleAutomaticChecks
                }
                if policy.checksForUpdateInformationOnAboutAppear {
                    refreshUpdateInformation()
                }
            }
            .store(in: &subscriptions)
    }

    func configureUpdater() {
        startUpdaterIfNeeded()
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
                receiveUpdateNotifications: model.settings.receiveUpdateNotifications
            ).enablesSparkleAutomaticChecks
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
        updateFeedSelection.feedURLString
    }

    @objc func checkForUpdates() {
        packageFallbackCoordinator.resetForManualCheck()
        if !updater.sessionInProgress {
            updateUserDriver.clearFallbackState()
        }
        performUpdateCheck(.userInitiated)
    }

    func installAvailableUpdate(_ update: AvailableUpdateInformation) {
        packageFallbackCoordinator.resetForManualCheck()
        if !updater.sessionInProgress {
            updateUserDriver.prepareForConfirmedInstall(update)
        }
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
            guard updateFeedSelection.feedURLString != nil else {
                updateInformation.setUnavailable()
                AppLogger.shared.write(
                    "UPDATE CHECK resolved=false source=cloudflare_channel user_alert=false"
                )
                return
            }
            AppLogger.shared.write(
                "UPDATE CHECK resolved=true selected_channel=stable source=cloudflare_channel"
            )
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
                self?.performUpdateCheck(.userInitiated)
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
