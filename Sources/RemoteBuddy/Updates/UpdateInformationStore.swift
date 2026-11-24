import Combine
import Foundation

struct AvailableUpdateInformation: Equatable {
    let displayVersion: String
    let buildVersion: String
    let releaseNotes: [String]
}

enum UpdateInformationState: Equatable {
    case idle
    case checking
    case upToDate
    case unavailable
    case available(AvailableUpdateInformation)
}

enum UpdateVersion {
    static func normalized(_ rawValue: String) -> String? {
        let stripped = rawValue.hasPrefix("v") ? String(rawValue.dropFirst()) : rawValue
        let value = stripped.range(of: #"^\d{2}-\d{2}-\d{2}\.\d{3}$"#, options: .regularExpression) != nil
            ? stripped.replacingOccurrences(of: "-", with: ".") : stripped
        guard value.range(of: #"^\d+(?:\.\d+){1,3}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return value
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let candidate = normalized(candidate),
              let current = normalized(current)
        else { return false }
        let candidateParts = candidate.split(separator: ".").compactMap { Int($0) }
        let currentParts = current.split(separator: ".").compactMap { Int($0) }
        let count = max(candidateParts.count, currentParts.count)
        for index in 0..<count {
            let candidatePart = index < candidateParts.count ? candidateParts[index] : 0
            let currentPart = index < currentParts.count ? currentParts[index] : 0
            if candidatePart != currentPart {
                return candidatePart > currentPart
            }
        }
        return false
    }
}

enum UpdateReleaseNotes {
    static func parse(_ text: String) -> [String] {
        text.split(whereSeparator: \Character.isNewline).compactMap { line in
            var value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("- ") || value.hasPrefix("• ") {
                value.removeFirst(2)
            }
            guard !value.isEmpty, !value.hasPrefix("#") else { return nil }
            return value
        }
    }

}

@MainActor
final class UpdateInformationStore: ObservableObject {
    @Published private(set) var state: UpdateInformationState = .idle
    @Published private(set) var hasUnseenUpdate = false

    private struct PendingUpdate: Equatable {
        let displayVersion: String
        let buildVersion: String
        let fallbackNotes: [String]

        var identifier: String {
            "\(displayVersion)|\(buildVersion)"
        }
    }

    private static let lastSeenUpdateIdentifierKey =
        "updateInformation.lastSeenUpdateIdentifier"

    private let userDefaults: UserDefaults
    private var pendingUpdate: PendingUpdate?
    private var checkingDeadline: ScheduledOperation?
    private var checkingGeneration = UUID()
    private let schedule: OperationScheduler
    private let checkingTimeout: TimeInterval

    init(userDefaults: UserDefaults = .standard, checkingTimeout: TimeInterval = 30,
         schedule: @escaping OperationScheduler = ScheduledOperation.mainQueue) {
        self.userDefaults = userDefaults
        self.checkingTimeout = checkingTimeout
        self.schedule = schedule
    }

    isolated deinit { checkingDeadline?.cancel() }

    private func cancelCheckingDeadline() {
        checkingGeneration = UUID()
        checkingDeadline?.cancel()
        checkingDeadline = nil
    }

    func beginChecking(timeoutEnabled: Bool = true) {
        cancelCheckingDeadline()
        state = .checking
        guard timeoutEnabled else { return }
        let generation = checkingGeneration
        checkingDeadline = schedule(checkingTimeout) { [weak self] in
            guard let self, self.checkingGeneration == generation,
                  self.state == .checking else { return }
            self.setUnavailable()
        }
    }

    func reset() {
        cancelCheckingDeadline()
        pendingUpdate = nil
        state = .idle
        clearUnseenUpdate(reason: "update_state_reset")
    }

    func setUpToDate() {
        cancelCheckingDeadline()
        pendingUpdate = nil
        state = .upToDate
        clearUnseenUpdate(reason: "up_to_date")
    }

    func setUnavailable() {
        cancelCheckingDeadline()
        pendingUpdate = nil
        state = .unavailable
        clearUnseenUpdate(reason: "update_information_unavailable")
    }

    func setAvailable(
        displayVersion: String,
        buildVersion: String,
        fallbackDescription: String?
    ) {
        cancelCheckingDeadline()
        let pending = PendingUpdate(
            displayVersion: displayVersion,
            buildVersion: buildVersion,
            fallbackNotes: fallbackDescription.map(UpdateReleaseNotes.parse) ?? []
        )
        let candidateChanged = pendingUpdate?.identifier != pending.identifier
        pendingUpdate = pending
        state = .available(information(for: pending, notes: pending.fallbackNotes))
        if candidateChanged {
            hasUnseenUpdate = userDefaults.string(
                forKey: Self.lastSeenUpdateIdentifierKey
            ) != pending.identifier
            AppLogger.shared.write(
                "UPDATE BADGE phase=completed result=\(hasUnseenUpdate ? "shown" : "suppressed") " +
                    "reason=\(hasUnseenUpdate ? "new_update_detected" : "already_seen") " +
                    "display_version=\(AppLogger.stableToken(displayVersion)) " +
                    "build_version=\(AppLogger.stableToken(buildVersion))"
            )
        }
    }

    func markAvailableUpdateSeen() {
        guard hasUnseenUpdate, let pendingUpdate else { return }
        userDefaults.set(pendingUpdate.identifier, forKey: Self.lastSeenUpdateIdentifierKey)
        hasUnseenUpdate = false
        AppLogger.shared.write(
            "UPDATE BADGE phase=completed result=cleared reason=settings_opened " +
                "display_version=\(AppLogger.stableToken(pendingUpdate.displayVersion)) " +
                "build_version=\(AppLogger.stableToken(pendingUpdate.buildVersion))"
        )
    }

    private func information(
        for pending: PendingUpdate,
        notes: [String]
    ) -> AvailableUpdateInformation {
        AvailableUpdateInformation(
            displayVersion: pending.displayVersion,
            buildVersion: pending.buildVersion,
            releaseNotes: notes
        )
    }

    private func clearUnseenUpdate(reason: String) {
        guard hasUnseenUpdate else { return }
        hasUnseenUpdate = false
        AppLogger.shared.write(
            "UPDATE BADGE phase=completed result=cleared reason=\(reason)"
        )
    }

}
