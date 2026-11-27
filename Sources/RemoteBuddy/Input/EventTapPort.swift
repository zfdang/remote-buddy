import CoreGraphics
import Foundation
import os

/// Bounds repeated WindowServer disable/re-enable cycles on each tap.
final class EventTapRecovery: @unchecked Sendable {
    private struct RetryState {
        var attempts = 0
        var lastAttempt: TimeInterval?
    }

    private let state = OSAllocatedUnfairLock(initialState: RetryState())
    private let now: () -> TimeInterval
    private let dispatch: (TimeInterval, @escaping @Sendable () -> Void) -> Void

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         dispatch: @escaping (TimeInterval, @escaping @Sendable () -> Void) -> Void = { delay, action in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
         }) {
        self.now = now
        self.dispatch = dispatch
    }

    func recover(type: CGEventType, isCurrent: @escaping () -> Bool,
                 permissionsGranted: @escaping () -> Bool,
                 enable: @escaping () -> Bool, stop: @escaping () -> Void) {
        let time = now()
        let (delay, exhausted) = state.withLock { state -> (TimeInterval, Bool) in
            if let lastAttempt = state.lastAttempt, time - lastAttempt > 30 {
                state.attempts = 0
            }
            state.lastAttempt = time
            state.attempts += 1
            let delay = min(8, 0.5 * pow(2, Double(state.attempts - 1)))
            return (delay, state.attempts > 5)
        }
        nonisolated(unsafe) let isCurrent = isCurrent
        nonisolated(unsafe) let permissionsGranted = permissionsGranted
        nonisolated(unsafe) let enable = enable
        nonisolated(unsafe) let stop = stop
        EventTapPort.deferRecovery(type: type,
            dispatch: { self.dispatch(delay, $0) }, isCurrent: { isCurrent() },
            permissionsGranted: { !exhausted && permissionsGranted() }, enable: {
                guard !enable() else { return }
                // A failed enable need not produce another WindowServer callback.
                // Keep the same port/generation guard and bounded retry budget.
                self.recover(type: type, isCurrent: isCurrent,
                    permissionsGranted: permissionsGranted, enable: enable, stop: stop)
            }, stop: { stop() })
    }
}

/// event tap 端口的接入与释放。
///
/// 释放必须包含 `CFMachPortInvalidate`：只调用 `CGEvent.tapEnable(enable: false)` 并摘除
/// RunLoop source 不会把端口从 WindowServer 的 tap 列表中注销，端口会一直残留到进程
/// 退出。遥控器每次重连都会重建 HID 监听，因此残留量随重连次数单调累积，最终使每个
/// 输入事件都要流经上千个已禁用 tap，表现为全系统界面卡顿。
///
/// 两处 tap 创建点（`KeyboardEventSuppressor` 与 `ShortcutCaptureMonitor`）共用本类型，
/// 避免同一释放逻辑被分别实现后再次分叉。
enum EventTapPort {
    /// Return from the WindowServer callback before checking TCC or recovering a tap.
    /// A queued recovery must not revive a port stopped or replaced in the meantime.
    static func deferRecovery(
        type: CGEventType,
        dispatch: (@escaping @Sendable () -> Void) -> Void,
        isCurrent: @escaping @Sendable () -> Bool,
        permissionsGranted: @escaping @Sendable () -> Bool,
        enable: @escaping @Sendable () -> Void,
        stop: @escaping @Sendable () -> Void
    ) {
        dispatch {
            guard isCurrent() else { return }
            guard type == .tapDisabledByTimeout || type == .tapDisabledByUserInput,
                  permissionsGranted() else {
                stop()
                return
            }
            enable()
        }
    }

    /// 把已创建的 tap 端口接入主 RunLoop 并启用。
    static func activate(port: CFMachPort, source: CFRunLoopSource) {
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    /// 释放 tap 端口：先禁用再摘除 RunLoop source，最后 invalidate。
    ///
    /// `port` 为 nil 时只摘除 source；`source` 为 nil 时只处理端口，用于 tap 创建
    /// 中途失败、端口已登记但尚未接入 RunLoop 的情形。
    /// - Returns: `true` 表示端口已安全排空（RunLoop 移除确认或无需等待）；
    ///   `false` 表示 RunLoop 线程在超时预算内未响应，调用方必须保留 `userInfo`
    ///   回调上下文对象，避免仍在执行的回调访问已释放对象（UAF）。
    @discardableResult
    static func release(port: CFMachPort?, source: CFRunLoopSource?) -> Bool {
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
        }
        guard let source else {
            if let port {
                CFMachPortInvalidate(port)
            }
            return true
        }

        let mainRunLoop = CFRunLoopGetMain()
        if Thread.isMainThread {
            CFRunLoopRemoveSource(mainRunLoop, source, .commonModes)
            if let port {
                CFMachPortInvalidate(port)
            }
            return true
        }

        let semaphore = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(mainRunLoop, CFRunLoopMode.commonModes.rawValue) {
            CFRunLoopRemoveSource(mainRunLoop, source, .commonModes)
            if let port {
                CFMachPortInvalidate(port)
            }
            semaphore.signal()
        }
        CFRunLoopWakeUp(mainRunLoop)

        if semaphore.wait(timeout: .now() + .milliseconds(500)) == .success {
            return true
        }

        // Fallback: invalidate even when the RunLoop did not respond in time so
        // disabled taps cannot accumulate in WindowServer. Return false so the
        // caller keeps the retained callback owner alive instead of causing UAF.
        AppLogger.shared.write(
            "EVENT TAP phase=timed_out action=release result=fallback reason=run_loop_timeout"
        )
        if let port {
            CFMachPortInvalidate(port)
        }
        return false
    }

    /// 仅在端口已确认排空后释放回调持有的强引用；排空超时时有意保留对象避免 UAF。
    static func finalizeOwnerRelease<Owner: AnyObject>(
        _ owner: Unmanaged<Owner>?,
        drained: Bool,
        onRetainedFallback: () -> Void
    ) {
        guard let owner else { return }
        if drained {
            owner.release()
        } else {
            onRetainedFallback()
        }
    }
}
