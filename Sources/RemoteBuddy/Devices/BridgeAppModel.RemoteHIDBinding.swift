import Foundation

extension BridgeAppModel {
    func observeRemoteHIDIdentity(_ bridge: BluetoothRemoteBridge) {
        bridge.onDeviceInformationUpdate = { [weak self, weak bridge] in
            guard let self, let bridge, let identifier = bridge.deviceIdentifier else { return }
            self.remoteDeviceInformation[identifier] = bridge.deviceInformation
        }
        bridge.onHIDIdentityUpdate = { [weak self, weak bridge] in
            guard let self, let bridge else { return }
            self.learnSelectedRemoteHIDIdentity(bridge)
        }
    }

    func learnSelectedRemoteHIDIdentity(_ bridge: BluetoothRemoteBridge) {
        // BLE readiness includes the adapter's model and capability validation.
        guard case .ready = bridge.state,
              let profileID = remoteProfileID(for: bridge),
              let profile = settings.remoteDeviceProfiles.first(where: { $0.id == profileID }),
              [RemoteModel.rc001, .rc003, .chromecastVoiceRemote, .t1Remote].contains(profile.model)
        else { return }
        let fallbackIdentity: RemoteHIDIdentity = profile.model.isChromecastRemote
            ? .chromecast
            : (profile.model.isT1Remote ? .t1Remote : .xiaomi)
        let identity = bridge.reportedHIDIdentity ?? fallbackIdentity
        if !identity.isStandard {
            guard !settings.isOnboardingComplete, settings.selectedRemoteProfileID == profileID,
                  settings.onboardingStep == .remote || settings.onboardingStep == .controls,
                  Self.canLearnHIDIdentity(model: profile.model, source: settings.onboardingControlSource)
            else { return }
        }
        let unboundCandidates = availableCandidatesExcludingOtherProfiles(for: profileID)
        guard let candidate = Self.resolveHIDCandidate(
            forModel: profile.model,
            identity: identity,
            expectedName: bridge.currentSystemDeviceName(),
            availableCandidates: unboundCandidates,
            boundFingerprints: []
        ) else { return }
        if bridge.deviceInformation.hidVersion == nil,
           let hidVersion = RemoteHIDIdentity.readVersionNumber(forFingerprint: candidate.binding.fingerprint) {
            bridge.deviceInformation.hidVersion = hidVersion
            AppLogger.shared.write(
                "REMOTE HID version_observed hid_version=\(String(format: "0x%04X", hidVersion)) source=iohid"
            )
        }
        bindCompatibleRemote(candidate, profileID: profileID, select: false)
    }

    private func availableCandidatesExcludingOtherProfiles(for profileID: UUID) -> [RemoteHIDCandidate] {
        let otherBoundFingerprints = Set(
            settings.remoteDeviceProfiles
                .filter { $0.id != profileID }
                .compactMap(\.hidFingerprint)
        )
        return RemoteHIDCandidate.available().filter { !otherBoundFingerprints.contains($0.id) }
    }

    static func resolveHIDCandidate(
        forModel model: RemoteModel,
        identity: RemoteHIDIdentity,
        expectedName: String?,
        availableCandidates: [RemoteHIDCandidate],
        boundFingerprints: Set<String>
    ) -> RemoteHIDCandidate? {
        let unboundCandidates = availableCandidates.filter { !boundFingerprints.contains($0.id) }
        if let matched = RemoteHIDCandidate.identified(
            identity: identity,
            expectedName: expectedName,
            among: unboundCandidates
        ) {
            return matched
        }
        // When a Chromecast remote's macOS Bluetooth name differs from its HID name
        // (or has not resolved yet), fall back to a unique unbound standard 18D1:9450 candidate.
        guard model.isChromecastRemote, identity == .chromecast else {
            return nil
        }
        let chromecastMatches = RemoteHIDCandidate.unambiguous(unboundCandidates).filter {
            $0.binding.identity == .chromecast
        }
        return chromecastMatches.count == 1 ? chromecastMatches.first : nil
    }

    static func canLearnHIDIdentity(model: RemoteModel, source: OnboardingControlSource) -> Bool {
        switch source {
        case .chromecastRemote: return model.isChromecastRemote
        case .t1Remote: return model.isT1Remote
        case .xiaomiRemote: return model == .rc001 || model == .rc003
        default: return false
        }
    }

    static func showsManualCompatibleHIDPicker(model: RemoteModel, source: OnboardingControlSource) -> Bool {
        !model.isChromecastRemote && canLearnHIDIdentity(model: model, source: source)
    }

    @discardableResult
    func bindCompatibleRemote(_ candidate: RemoteHIDCandidate, profileID: UUID, select: Bool = true) -> Bool {
        guard let profile = settings.remoteDeviceProfiles.first(where: { $0.id == profileID }),
              settings.allowsSetupCandidate(hidFingerprint: candidate.id, model: profile.model),
              let identifier = profile.bluetoothIdentifier,
              let bridge = connections.bridges[identifier], case .ready = bridge.state,
              !profile.model.isChromecastRemote || bridge.identifiedModel == .chromecastVoiceRemote,
              !profile.model.isT1Remote || bridge.identifiedModel == .t1Remote,
              candidate.binding.identity != .xiaomi || !profile.model.isATVVRemote,
              candidate.binding.identity != .chromecast || profile.model.isChromecastRemote,
              candidate.binding.identity != .t1Remote || profile.model.isT1Remote,
              RemoteHIDCandidate.available().contains(candidate),
              !isStreaming, !voiceKeyLatch.isHeld,
              !voiceFnTapSession.requiresCleanupBeforeMapping else { return false }
        guard settings.bindCompatibleHID(candidate.binding, to: profileID) else {
            return settings.remoteDeviceProfiles.contains {
                $0.id == profileID && $0.hidFingerprint == candidate.id &&
                    ($0.compatibleHIDBinding == candidate.binding || candidate.binding.identity.isStandard)
            }
        }
        if select { selectRemoteProfile(profileID) }
        if started { applyHIDSettings() }
        AppLogger.shared.write(
            "REMOTE HID binding_saved custom_identity=\(!candidate.binding.identity.isStandard) " +
                String(format: "vid=%04X pid=%04X", candidate.binding.identity.vendorID, candidate.binding.identity.productID)
        )
        return true
    }
}
