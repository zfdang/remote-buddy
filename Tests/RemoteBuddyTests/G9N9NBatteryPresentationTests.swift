import Testing
@testable import RemoteBuddy

@Suite("G9N9N battery display")
struct G9N9NBatteryPresentationTests {
    @Test(arguments: [0, 1, 50, 100])
    func displaysActualBatteryReadingsIncludingEmptyBattery(level: Int) {
        #expect(RemoteBatteryPresentationPolicy.shouldShowBattery(
            model: .chromecastVoiceRemote, level: level, powerState: nil))
    }
    @Test func absentBatteryReadingDoesNotShowAnInventedPercentage() {
        #expect(!RemoteBatteryPresentationPolicy.shouldShowBattery(
            model: .chromecastVoiceRemote, level: nil, powerState: nil))
    }
}
