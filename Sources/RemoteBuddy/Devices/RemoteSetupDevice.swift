/// Product scope, separate from the catalog admitting validated hardware connections.
/// Adapter readiness is separate from allowing a device to be selected for setup.
enum RemoteSetupDevice: String, CaseIterable, Identifiable {
    case chromecastG9N9N
    case t1Remote
    case xiaomi
    case googleStreamerGY3LE
    case siriRemote

    var id: String { rawValue }
    var titleKey: String { "remote.catalog.\(rawValue).title" }

    /// Only devices with an available adapter can enter connection setup.
    var onboardingSource: OnboardingControlSource? {
        switch self {
        case .xiaomi: return .xiaomiRemote
        case .t1Remote: return .t1Remote
        case .chromecastG9N9N: return .chromecastRemote
        case .googleStreamerGY3LE, .siriRemote: return nil
        }
    }

    var canStartSetup: Bool { onboardingSource != nil }

    static func device(for source: OnboardingControlSource) -> Self? {
        allCases.first { $0.onboardingSource == source }
    }

    /// Bundled device artwork: G9N9N uses the supplied real photograph.
    var illustrationResource: String {
        switch self {
        case .xiaomi: return "BuddyRemoteIllustration"
        case .t1Remote: return "T1RemoteSetupIllustration"
        case .chromecastG9N9N: return "ChromecastG9N9NPhoto"
        case .googleStreamerGY3LE: return "GoogleStreamerGY3LEIllustration"
        case .siriRemote: return "SiriRemoteA2854Illustration"
        }
    }

    var icon: String {
        self == .siriRemote ? "appletvremote.gen4.fill" : "antenna.radiowaves.left.and.right"
    }

    /// Google manufacturer model numbers, not player models or seller compatibility labels.
    var googleHardwareModelNumber: String? {
        switch self {
        case .chromecastG9N9N: return "G9N9N"
        case .googleStreamerGY3LE: return "GY3LE"
        case .xiaomi, .t1Remote, .siriRemote: return nil
        }
    }
}
