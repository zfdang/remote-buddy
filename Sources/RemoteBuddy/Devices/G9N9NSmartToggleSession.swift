import Foundation

/// State machine for Chromecast G9N9N physical voice button smart-toggle mode:
/// - Short press & release (`< holdThreshold`) keeps the voice session alive and triggers
///   an ATVV `MIC_OPEN` (`0x0C`) reopen so the user can speak hands-free until the next press.
/// - Long press (`>= holdThreshold`) behaves as standard hold-to-talk and stops on release.
struct G9N9NSmartToggleState: Equatable {
    static let holdThreshold: TimeInterval = 0.7
    static let reopenTimeout: TimeInterval = 5
    static let maximumHandsFreeDuration: TimeInterval = 300

    enum Phase: Equatable {
        case idle
        case physicalPressed(bridgeID: UUID, startedAt: TimeInterval, physicalReleasedAt: TimeInterval?)
        case awaitingReopen(bridgeID: UUID)
        case handsFreeActive(bridgeID: UUID)
        case closing(bridgeID: UUID)
    }

    private(set) var phase: Phase = .idle
    private(set) var generation: UInt64 = 0

    var ownerBridgeID: UUID? {
        switch phase {
        case .idle:
            return nil
        case let .physicalPressed(id, _, _),
             let .awaitingReopen(id),
             let .handsFreeActive(id),
             let .closing(id):
            return id
        }
    }

    var isActive: Bool {
        phase != .idle
    }

    var isAwaitingReopen: Bool {
        if case .awaitingReopen = phase { return true }
        return false
    }

    var isAwaitingReopenWithPendingPreparationRelease: Bool {
        if case let .physicalPressed(_, _, releasedAt) = phase {
            return releasedAt != nil
        }
        return false
    }

    mutating func beginPhysicalPress(bridgeID: UUID, at uptime: TimeInterval) {
        generation &+= 1
        phase = .physicalPressed(bridgeID: bridgeID, startedAt: uptime, physicalReleasedAt: nil)
    }

    mutating func recordShortReleaseDuringPreparation(
        bridgeID: UUID,
        stopReason: BluetoothVoiceStopReason?,
        localCloseRequested: Bool,
        at uptime: TimeInterval
    ) -> Bool {
        guard case let .physicalPressed(ownerID, startedAt, existingRelease) = phase,
              ownerID == bridgeID,
              stopReason == .remoteNotification,
              !localCloseRequested
        else { return false }
        let releaseTime = existingRelease ?? uptime
        guard releaseTime - startedAt < Self.holdThreshold else { return false }
        phase = .physicalPressed(bridgeID: ownerID, startedAt: startedAt, physicalReleasedAt: releaseTime)
        return true
    }

    func shouldReopenOnPhysicalStop(
        bridgeID: UUID,
        stopReason: BluetoothVoiceStopReason?,
        localCloseRequested: Bool,
        at uptime: TimeInterval
    ) -> Bool {
        guard case let .physicalPressed(ownerID, startedAt, physicalReleasedAt) = phase,
              ownerID == bridgeID,
              stopReason == .remoteNotification,
              !localCloseRequested
        else { return false }
        let releaseTime = physicalReleasedAt ?? uptime
        return releaseTime - startedAt < Self.holdThreshold
    }

    @discardableResult
    mutating func enterAwaitingReopen(bridgeID: UUID) -> UInt64 {
        generation &+= 1
        phase = .awaitingReopen(bridgeID: bridgeID)
        return generation
    }

    mutating func enterHandsFreeActive(bridgeID: UUID) -> UInt64? {
        guard case .awaitingReopen(bridgeID) = phase else { return nil }
        generation &+= 1
        phase = .handsFreeActive(bridgeID: bridgeID)
        return generation
    }

    func shouldStopOnRemoteOpenRequest(bridgeID: UUID) -> Bool {
        switch phase {
        case let .physicalPressed(id, _, releasedAt):
            return id == bridgeID && releasedAt != nil
        case let .awaitingReopen(id), let .handsFreeActive(id), let .closing(id):
            return id == bridgeID
        case .idle:
            return false
        }
    }

    func shouldStopOnRemoteAudioStart(
        bridgeID: UUID,
        interaction: UInt8?,
        activeSessionID: UInt8?,
        incomingSessionID: UInt8?
    ) -> Bool {
        switch phase {
        case let .closing(id):
            return id == bridgeID
        case let .handsFreeActive(id):
            guard id == bridgeID else { return false }
            if interaction == 0x03 { return true }
            if let incomingSessionID, incomingSessionID != activeSessionID { return true }
            return false
        case let .awaitingReopen(id):
            guard id == bridgeID else { return false }
            return interaction == 0x03
        case let .physicalPressed(id, _, releasedAt):
            return id == bridgeID && releasedAt != nil && interaction == 0x03
        case .idle:
            return false
        }
    }

    @discardableResult
    mutating func enterClosing(bridgeID: UUID) -> UInt64? {
        switch phase {
        case let .physicalPressed(id, _, releasedAt) where releasedAt != nil:
            guard id == bridgeID else { return nil }
            generation &+= 1
            phase = .closing(bridgeID: bridgeID)
            return generation
        case let .awaitingReopen(id), let .handsFreeActive(id):
            guard id == bridgeID else { return nil }
            generation &+= 1
            phase = .closing(bridgeID: bridgeID)
            return generation
        case let .closing(id):
            return id == bridgeID ? generation : nil
        case .idle, .physicalPressed:
            return nil
        }
    }

    mutating func reset() {
        generation &+= 1
        phase = .idle
    }
}
