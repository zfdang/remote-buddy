import ApplicationServices
import CoreGraphics
import Foundation
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

    @Test func hudWatchdogKeepsSessionAliveOnFrontmostChangeAndSkipsEscapeAfterTwoAbsentTicks() {
        let clock = ControlledTestScheduler()
        var events: [(CGKeyCode, Bool, CGEventFlags)] = []
        var logs: [String] = []
        var frontmost = "com.example.editor"
        var hudVisible: Bool? = true

        let coordinator = HIDAppSwitcherCoordinator(
            session: KeyboardInjector.AppSwitcherSession(
                hardwareFlags: { [] },
                keyStatePoster: { code, down, flags, _ in
                    events.append((code, down, flags))
                    return true
                },
                scheduleRelease: clock.voiceSchedule
            ),
            scheduler: clock,
            frontmostBundleIdentifier: { frontmost },
            switcherHUDVisible: { hudVisible },
            diagnosticLogger: { logs.append($0) }
        )
        let owner = UUID()
        let poll = HIDRemoteTiming.appSwitcherFrontmostPollMilliseconds

        #expect(coordinator.trigger(for: .home, trigger: .singleClick, owner: owner))
        events.removeAll()

        // Changing frontmost app while the HUD remains visible must NOT dismiss the switcher.
        frontmost = "com.apple.Safari"
        clock.advance(to: poll * 3)
        #expect(coordinator.isActive)
        #expect(events.isEmpty)

        // Unreadable AX state (nil) must not advance the dismissal counter.
        hudVisible = nil
        clock.advance(to: poll * 6)
        #expect(coordinator.isActive)
        #expect(events.isEmpty)

        // A single absent tick is tolerated and resets as soon as the HUD reads visible again.
        hudVisible = false
        clock.advance(to: poll * 7)
        #expect(coordinator.isActive)
        hudVisible = true
        clock.advance(to: poll * 8)
        #expect(coordinator.isActive)

        // Two consecutive absent ticks end the session without sending Escape (53).
        hudVisible = false
        clock.advance(to: poll * 9)
        #expect(coordinator.isActive)
        clock.advance(to: poll * 10)
        #expect(!coordinator.isActive)
        #expect(events.count == 1)
        #expect(events[0].0 == KeyboardInjector.leftCommandKeyCode)
        #expect(events[0].1 == false)
        #expect(logs.contains { $0.contains("ended reason=hud_dismissed confirmed=false") })

        // Explicit Back button dismissal still sends Escape (53) before releasing Command.
        events.removeAll()
        hudVisible = true
        #expect(coordinator.trigger(for: .home, trigger: .singleClick, owner: owner))
        events.removeAll()
        #expect(coordinator.handleControlPress(.back, owner: owner))
        #expect(!coordinator.isActive)
        #expect(events.map(\.0) == [53, 53, KeyboardInjector.leftCommandKeyCode])
        #expect(!events[2].1)

        // Direct session cancel(dismissSwitcher: false) releases Command without posting Escape.
        let directSession = KeyboardInjector.AppSwitcherSession(
            hardwareFlags: { [] },
            keyStatePoster: { code, down, flags, _ in
                events.append((code, down, flags))
                return true
            }
        )
        #expect(directSession.trigger())
        events.removeAll()
        #expect(directSession.cancel(dismissSwitcher: false))
        #expect(!directSession.isActive)
        #expect(events.count == 1)
        #expect(events[0].0 == KeyboardInjector.leftCommandKeyCode)
        #expect(!events[0].1)
    }

    @Test func confirmRetriesFailedCommandAndOptionReleasesAndFlushPreservesFailedOwnership() {
        struct PostedEdge: Equatable {
            let code: CGKeyCode
            let down: Bool
        }

        // 1. Command release fails on first attempt, retries after 50ms, then Option releases 100ms later.
        do {
            let clock = ControlledTestScheduler()
            var failNextCommandUp = true
            var posted: [(CGKeyCode, Bool, CGEventFlags)] = []
            let session = KeyboardInjector.AppSwitcherSession(
                hardwareFlags: { [] },
                keyStatePoster: { code, down, flags, _ in
                    if code == KeyboardInjector.leftCommandKeyCode && !down && failNextCommandUp {
                        failNextCommandUp = false
                        return false
                    }
                    posted.append((code, down, flags))
                    return true
                },
                scheduleRelease: clock.voiceSchedule
            )
            #expect(session.trigger())
            posted.removeAll()
            #expect(session.confirm())
            #expect(posted.map(\.0) == [KeyboardInjector.AppSwitcherSession.leftOptionKeyCode])

            // At 60ms, Command up fails; Option must remain held until Command retry succeeds.
            clock.advance(to: 60)
            #expect(posted.count == 1)

            // Retry fires after +50ms (110ms total): Command up succeeds.
            clock.advance(to: 110)
            #expect(posted.map(\.0) == [
                KeyboardInjector.AppSwitcherSession.leftOptionKeyCode,
                KeyboardInjector.leftCommandKeyCode,
            ])
            #expect(!posted[1].1)

            // Option releases +100ms later (210ms total).
            clock.advance(to: 210)
            #expect(posted.map(\.0) == [
                KeyboardInjector.AppSwitcherSession.leftOptionKeyCode,
                KeyboardInjector.leftCommandKeyCode,
                KeyboardInjector.AppSwitcherSession.leftOptionKeyCode,
            ])
            #expect(!posted[2].1)
        }

        // 2. Option release fails on first attempt and succeeds on bounded retry.
        do {
            let clock = ControlledTestScheduler()
            var failNextOptionUp = true
            var posted: [PostedEdge] = []
            let session = KeyboardInjector.AppSwitcherSession(
                hardwareFlags: { [] },
                keyStatePoster: { code, down, _, _ in
                    if code == KeyboardInjector.AppSwitcherSession.leftOptionKeyCode && !down && failNextOptionUp {
                        failNextOptionUp = false
                        return false
                    }
                    posted.append(PostedEdge(code: code, down: down))
                    return true
                },
                scheduleRelease: clock.voiceSchedule
            )
            #expect(session.trigger())
            posted.removeAll()
            #expect(session.confirm())
            clock.advance(to: 160)
            #expect(posted == [
                PostedEdge(code: KeyboardInjector.AppSwitcherSession.leftOptionKeyCode, down: true),
                PostedEdge(code: KeyboardInjector.leftCommandKeyCode, down: false),
            ])

            clock.advance(to: 210)
            #expect(posted == [
                PostedEdge(code: KeyboardInjector.AppSwitcherSession.leftOptionKeyCode, down: true),
                PostedEdge(code: KeyboardInjector.leftCommandKeyCode, down: false),
                PostedEdge(code: KeyboardInjector.AppSwitcherSession.leftOptionKeyCode, down: false),
            ])
        }

        // 3. Early flush (retrigger before deferred release completes) preserves stuck modifiers and retries.
        do {
            let clock = ControlledTestScheduler()
            var failNextOptionUp = true
            var posted: [PostedEdge] = []
            let session = KeyboardInjector.AppSwitcherSession(
                hardwareFlags: { [] },
                keyStatePoster: { code, down, _, _ in
                    if code == KeyboardInjector.AppSwitcherSession.leftOptionKeyCode && !down && failNextOptionUp {
                        failNextOptionUp = false
                        return false
                    }
                    posted.append(PostedEdge(code: code, down: down))
                    return true
                },
                scheduleRelease: clock.voiceSchedule
            )
            #expect(session.trigger())
            #expect(session.confirm())
            posted.removeAll()

            // Retrigger immediately before Option release runs; Option up fails, so trigger refuses
            // to start a polluted session and schedules a retry instead of forgetting Option.
            #expect(!session.trigger())
            #expect(posted == [PostedEdge(code: KeyboardInjector.leftCommandKeyCode, down: false)])

            clock.advance(to: 50)
            #expect(posted == [
                PostedEdge(code: KeyboardInjector.leftCommandKeyCode, down: false),
                PostedEdge(code: KeyboardInjector.AppSwitcherSession.leftOptionKeyCode, down: false),
            ])
            #expect(session.trigger())
        }
    }

    @Test func coordinatorCancelAllImmediatelyAfterConfirmReleasesCommandAndOptionOnce() {
        let clock = ControlledTestScheduler()
        let owner = UUID()
        var posted: [(code: CGKeyCode, down: Bool)] = []
        let session = KeyboardInjector.AppSwitcherSession(
            hardwareFlags: { [] },
            keyStatePoster: { code, down, _, _ in
                posted.append((code: code, down: down))
                return true
            },
            scheduleRelease: clock.voiceSchedule
        )
        let coordinator = HIDAppSwitcherCoordinator(
            session: session,
            scheduler: clock,
            frontmostBundleIdentifier: { "com.apple.Safari" },
            switcherHUDVisible: { true },
            diagnosticLogger: { _ in }
        )

        #expect(coordinator.trigger(for: .menu, trigger: .singleClick, owner: owner))
        #expect(coordinator.handleControlPress(.ok, owner: owner))
        #expect(!coordinator.isActive)
        #expect(session.hasPendingModifierRelease)
        posted.removeAll()

        // Quit right after confirm before the 60ms release timer fires.
        coordinator.cancelAll()
        #expect(!session.hasPendingModifierRelease)
        #expect(posted.filter { $0.code == KeyboardInjector.leftCommandKeyCode && !$0.down }.count == 1)
        #expect(posted.filter { $0.code == KeyboardInjector.AppSwitcherSession.leftOptionKeyCode && !$0.down }.count == 1)
        #expect(!posted.contains { $0.code == 53 })

        clock.advance(to: 500)
        #expect(posted.filter { $0.code == KeyboardInjector.leftCommandKeyCode && !$0.down }.count == 1)
        #expect(posted.filter { $0.code == KeyboardInjector.AppSwitcherSession.leftOptionKeyCode && !$0.down }.count == 1)
    }

    @Test func coordinatorCancelAllWhileOnlyOptionPendingReleasesRemainingOptionOnce() {
        let clock = ControlledTestScheduler()
        let owner = UUID()
        var posted: [(code: CGKeyCode, down: Bool)] = []
        let session = KeyboardInjector.AppSwitcherSession(
            hardwareFlags: { [] },
            keyStatePoster: { code, down, _, _ in
                posted.append((code: code, down: down))
                return true
            },
            scheduleRelease: clock.voiceSchedule
        )
        let coordinator = HIDAppSwitcherCoordinator(
            session: session,
            scheduler: clock,
            frontmostBundleIdentifier: { "com.apple.Safari" },
            switcherHUDVisible: { true },
            diagnosticLogger: { _ in }
        )

        #expect(coordinator.trigger(for: .menu, trigger: .singleClick, owner: owner))
        #expect(coordinator.handleControlPress(.ok, owner: owner))
        posted.removeAll()

        // Advance 60ms so Command releases cleanly, leaving only Option pending.
        clock.advance(to: 60)
        #expect(posted.filter { $0.code == KeyboardInjector.leftCommandKeyCode && !$0.down }.count == 1)
        #expect(posted.filter { $0.code == KeyboardInjector.AppSwitcherSession.leftOptionKeyCode && !$0.down }.isEmpty)
        #expect(session.hasPendingModifierRelease)

        // Quit before Option's 100ms release timer completes.
        coordinator.cancelAll()
        #expect(!session.hasPendingModifierRelease)
        #expect(posted.filter { $0.code == KeyboardInjector.leftCommandKeyCode && !$0.down }.count == 1)
        #expect(posted.filter { $0.code == KeyboardInjector.AppSwitcherSession.leftOptionKeyCode && !$0.down }.count == 1)
        #expect(!posted.contains { $0.code == 53 })

        clock.advance(to: 500)
        #expect(posted.filter { $0.code == KeyboardInjector.leftCommandKeyCode && !$0.down }.count == 1)
        #expect(posted.filter { $0.code == KeyboardInjector.AppSwitcherSession.leftOptionKeyCode && !$0.down }.count == 1)
    }

    @Test func dockSubroleTimeoutsKeepAppSwitcherActiveUntilVisibleAndAbsentPollsDismiss() {
        let clock = ControlledTestScheduler()
        let owner = UUID()
        var posted: [(code: CGKeyCode, down: Bool)] = []
        let session = KeyboardInjector.AppSwitcherSession(
            hardwareFlags: { [] },
            keyStatePoster: { code, down, _, _ in
                posted.append((code: code, down: down))
                return true
            },
            scheduleRelease: clock.voiceSchedule
        )

        var pollIndex = 0
        let scriptedResponses: [[(error: AXError, value: String?)]] = [
            [(error: .attributeUnsupported, value: nil), (error: .cannotComplete, value: nil)],
            [(error: .cannotComplete, value: nil)],
            [(error: .cannotComplete, value: nil)],
            [(error: .attributeUnsupported, value: nil), (error: .success, value: "AXProcessSwitcherList")],
            [(error: .attributeUnsupported, value: nil), (error: .noValue, value: nil)],
            [(error: .noValue, value: nil)],
        ]

        let coordinator = HIDAppSwitcherCoordinator(
            session: session,
            scheduler: clock,
            frontmostBundleIdentifier: { "com.apple.Safari" },
            switcherHUDVisible: {
                let index = min(pollIndex, scriptedResponses.count - 1)
                pollIndex += 1
                let children = scriptedResponses[index]
                return KeyboardInjector.evaluateAppSwitcherHUDVisibility(children: children) { $0 }
            },
            diagnosticLogger: { _ in }
        )

        #expect(coordinator.trigger(for: .menu, trigger: .singleClick, owner: owner))

        // Polls 1-3 experience transient `.cannotComplete` subrole timeouts: switcher stays active.
        let pollInterval = HIDRemoteTiming.appSwitcherFrontmostPollMilliseconds
        clock.advance(to: pollInterval * 3)
        #expect(coordinator.isActive)

        // Poll 4 recovers HUD visibility (`AXProcessSwitcherList`); navigation still works.
        clock.advance(to: pollInterval * 4)
        #expect(coordinator.isActive)
        #expect(coordinator.handleControlPress(.right, owner: owner))

        // Polls 5-6 return definitive absence (`.attributeUnsupported` / `.noValue`) twice -> dismiss without Escape.
        clock.advance(to: pollInterval * 6)
        #expect(!coordinator.isActive)
        #expect(!posted.contains { $0.code == 53 })
        #expect(posted.contains { $0.code == KeyboardInjector.leftCommandKeyCode && !$0.down })
    }
}
