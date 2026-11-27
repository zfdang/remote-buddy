import CoreGraphics
import Testing
@testable import RemoteBuddy

@Suite("App switcher cancellation")
struct AppSwitcherCancellationTests {
    @Test(arguments: [false, true])
    func cancelSendsEscapeBeforeReleasingCommandWhileConfirmOnlyReleases(cancel: Bool) {
        var events: [(CGKeyCode, Bool, CGEventFlags, CGEventFlags)] = []
        let session = KeyboardInjector.AppSwitcherSession(
            hardwareFlags: { [] },
            keyStatePoster: { code, down, flags, excludingOwned in
                events.append((code, down, flags, excludingOwned)); return true
            }
        )
        #expect(session.trigger())
        events.removeAll()
        #expect(cancel ? session.cancel() : session.confirm(restoreMinimizedWindows: false))
        #expect(events.map { $0.0 } == (cancel ? [53, 53, 55] : [55]))
        #expect(events.map { $0.1 } == (cancel ? [true, false, false] : [false]))
        if cancel { #expect(events[0].2 == .maskCommand && events[1].2 == .maskCommand) }
        #expect(events.last?.2 == [])
        #expect(events.last?.3 == ShortcutEventSequence.modifierFlags(for: 55))
        #expect(!session.isActive)
        let count = events.count
        #expect(session.cancel())
        #expect(events.count == count)
    }

    @Test func confirmHoldsOptionBeforeReleasingCommandAndFallsBackWhenOptionDownFails() {
        let clock = ControlledTestScheduler()
        var events: [(CGKeyCode, Bool, CGEventFlags, CGEventFlags)] = []
        let session = KeyboardInjector.AppSwitcherSession(
            hardwareFlags: { [] },
            keyStatePoster: { code, down, flags, excludingOwned in
                events.append((code, down, flags, excludingOwned))
                return true
            },
            scheduleRelease: clock.voiceSchedule
        )
        #expect(session.trigger())
        events.removeAll()

        #expect(session.confirm())
        #expect(!session.isActive)
        #expect(events.count == 1)
        #expect(events[0].0 == KeyboardInjector.AppSwitcherSession.leftOptionKeyCode)
        #expect(events[0].1 == true)
        #expect(events[0].2 == [.maskCommand, .maskAlternate])

        clock.advance(to: 60)
        #expect(events.count == 2)
        #expect(events[1].0 == KeyboardInjector.leftCommandKeyCode)
        #expect(events[1].1 == false)
        #expect(events[1].2 == [.maskAlternate])
        #expect(events[1].3 == ShortcutEventSequence.modifierFlags(for: KeyboardInjector.leftCommandKeyCode))

        clock.advance(to: 160)
        #expect(events.count == 3)
        #expect(events[2].0 == KeyboardInjector.AppSwitcherSession.leftOptionKeyCode)
        #expect(events[2].1 == false)
        #expect(events[2].2 == [])
        #expect(events[2].3 == ShortcutEventSequence.modifierFlags(for: KeyboardInjector.AppSwitcherSession.leftOptionKeyCode))

        // If Option press cannot be posted, confirm falls back to releasing Command immediately.
        var fallbackEvents: [(CGKeyCode, Bool, CGEventFlags)] = []
        let fallbackSession = KeyboardInjector.AppSwitcherSession(
            hardwareFlags: { [] },
            keyStatePoster: { code, down, flags, _ in
                if code == KeyboardInjector.AppSwitcherSession.leftOptionKeyCode && down { return false }
                fallbackEvents.append((code, down, flags))
                return true
            },
            scheduleRelease: clock.voiceSchedule
        )
        #expect(fallbackSession.trigger())
        fallbackEvents.removeAll()
        #expect(fallbackSession.confirm())
        #expect(!fallbackSession.isActive)
        #expect(fallbackEvents.count == 1)
        #expect(fallbackEvents[0].0 == KeyboardInjector.leftCommandKeyCode)
        #expect(fallbackEvents[0].1 == false)

        // Retriggering before the 160ms Option release fires flushes Command+Option release first.
        events.removeAll()
        #expect(session.trigger())
        events.removeAll()
        #expect(session.confirm())
        #expect(events.map(\.0) == [KeyboardInjector.AppSwitcherSession.leftOptionKeyCode])
        events.removeAll()
        #expect(session.trigger())
        #expect(events.map(\.0) == [
            KeyboardInjector.leftCommandKeyCode,
            KeyboardInjector.AppSwitcherSession.leftOptionKeyCode,
            KeyboardInjector.leftCommandKeyCode,
            48,
            48,
        ])
        #expect(!events[0].1)
        #expect(!events[1].1)
    }
}
