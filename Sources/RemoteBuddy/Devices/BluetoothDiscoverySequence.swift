/// Uses the same ordered discovery paths for new and registered remotes.
/// A failed or paused cached connection must still fall through to system-connected and scanning paths.
enum BluetoothDiscoverySequence {
    enum Source: String {
        case cachedTarget = "target_identifier"
        case systemConnected = "connected_peripheral"
    }

    static func run<Candidate>(
        cachedTarget: () -> Candidate?,
        connectedCandidates: () -> [Candidate],
        adopt: (Candidate, Source) -> Bool,
        scan: () -> Void
    ) {
        if let target = cachedTarget(), adopt(target, .cachedTarget) { return }
        for candidate in connectedCandidates() {
            if adopt(candidate, .systemConnected) { return }
        }
        scan()
    }
}
