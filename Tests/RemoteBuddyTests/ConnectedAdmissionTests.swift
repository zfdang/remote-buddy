import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Connected product admission")
struct ConnectedAdmissionTests {
    @Test(arguments: ["Chromecast", "Chromecast Remote", "chromecast_remote", "chromecast 遥控器", "G9N9N"])
    func googleCandidatePassesBothStages(name: String) {
        let identifier = UUID()
        #expect(VoiceRemoteAdmission.decide(identifier: identifier, targetIdentifier: identifier,
            advertisesVoiceService: true, name: name, advertisedName: nil, allowsG9N9N: true).isAdopted)
        #expect(!VoiceRemoteAdmission.rejectsConnectedProduct(name: name, allowsG9N9N: true))
        #expect(!VoiceRemoteAdmission.decide(identifier: identifier, targetIdentifier: UUID(),
            advertisesVoiceService: true, name: name, advertisedName: nil, allowsG9N9N: true).isAdopted)
    }

    @Test(arguments: ["Remote G10", "g10", "remoteg10"])
    func unsupportedProductsRemainRejected(name: String) {
        #expect(VoiceRemoteAdmission.rejectsConnectedProduct(name: name, allowsG9N9N: true))
    }

    @Test func xiaomiOnlyModeStillRejectsChromecast() {
        #expect(VoiceRemoteAdmission.rejectsConnectedProduct(name: "Chromecast", allowsG9N9N: false))
    }

    @Test func resolvedNameFallsBackFromBlankAdvertisedNameToPeripheralName() {
        #expect(VoiceRemoteAdmission.resolvedName(advertisedName: "  Chromecast  ", peripheralName: "MI RC") == "Chromecast")
        #expect(VoiceRemoteAdmission.resolvedName(advertisedName: nil, peripheralName: "  T1-Remote ") == "T1-Remote")
        #expect(VoiceRemoteAdmission.resolvedName(advertisedName: "", peripheralName: "Chromecast") == "Chromecast")
        #expect(VoiceRemoteAdmission.resolvedName(advertisedName: " \n\t ", peripheralName: "MI RC") == "MI RC")
        #expect(VoiceRemoteAdmission.resolvedName(advertisedName: "  ", peripheralName: nil) == nil)
    }
}
