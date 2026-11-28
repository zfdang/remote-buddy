import Foundation
import Testing
@testable import RemoteBuddy
@Suite("Voice source exclusion") @MainActor
struct VoiceSourceExclusionTests {
    @Test func pendingReleaseBlocksAnotherVoiceStart() throws {
        let values = EphemeralUserDefaults()
        let model = BridgeAppModel(settings: AppSettings(defaults: values))
        #expect(model.canAcceptNewVoiceSession(from: .bluetooth))
        model.voiceKeyReleaseRetry = ScheduledOperation {}
        #expect(!model.canAcceptNewVoiceSession(from: .bluetooth))
        model.voiceKeyReleaseRetry = nil
        #expect(model.canAcceptNewVoiceSession(from: .bluetooth))
    }
}
