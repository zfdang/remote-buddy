import Testing
@testable import RemoteBuddy

@Suite("Remote voice keyboard stop")
struct RemoteVoiceKeyboardStopTests {
    @Test func acceptsShortTapsAndRejectsChordsAndLongHolds() {
        var tap = StandaloneModifierTap()
        let down = tap.update(pressed: true, timestamp: 1_000_000_000)
        let up = tap.update(pressed: false, timestamp: 1_120_000_000)
        let duplicate = tap.update(pressed: false, timestamp: 1_150_000_000)
        #expect(!down)
        #expect(up)
        #expect(!duplicate)

        _ = tap.update(pressed: true, timestamp: 2_000_000_000)
        tap.cancel()
        let cancelled = tap.update(pressed: false, timestamp: 2_120_000_000)
        #expect(!cancelled)

        _ = tap.update(pressed: true, timestamp: 3_000_000_000)
        let held = tap.update(pressed: false, timestamp: 3_800_000_000)
        #expect(!held)
    }
}
