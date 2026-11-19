import CoreBluetooth
import Foundation

enum BluetoothBatteryPollingPolicy {
    static let interval: TimeInterval = 30 * 60

    static func shouldPoll(
        supportsNotifications: Bool,
        isNotifying: Bool
    ) -> Bool {
        !supportsNotifications || !isNotifying
    }
}

extension BluetoothRemoteBridge {
    /// Re-read optional battery characteristics without changing connection or audio state.
    func refreshBatteryState(reason: String) {
        guard shouldRun,
              !systemSuspension.isSuspended,
              lifecycle.isReady,
              let peripheral,
              peripheral.state == .connected
        else { return }
        requestBatteryStateRefresh(
            peripheral: peripheral,
            reason: reason,
            pollingOnly: false
        )
    }

    func updateBatteryPollingSchedule(generation: UInt64) {
        let needsPolling = batteryLevelNeedsPolling || batteryStatusNeedsPolling
        guard shouldRun, !systemSuspension.isSuspended, needsPolling else {
            stopBatteryPolling(
                reason: systemSuspension.isSuspended ? "system_suspended" : "notifications_active"
            )
            return
        }
        guard batteryRefreshWorkItem == nil else { return }
        if !batteryPollingActive {
            batteryPollingActive = true
            AppLogger.shared.write(
                "BLE BATTERY polling_started interval_ms=" +
                    "\(Int((BluetoothBatteryPollingPolicy.interval * 1_000).rounded())) " +
                    "level=\(batteryLevelNeedsPolling) power=\(batteryStatusNeedsPolling)"
            )
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.batteryRefreshWorkItem = nil
            guard self.shouldRun,
                  !self.systemSuspension.isSuspended,
                  self.currentGeneration() == generation,
                  self.lifecycle.isReady,
                  let peripheral = self.peripheral,
                  peripheral.state == .connected
            else {
                self.stopBatteryPolling(reason: "connection_inactive")
                return
            }
            self.requestBatteryStateRefresh(
                peripheral: peripheral,
                reason: "timer",
                pollingOnly: true
            )
            self.updateBatteryPollingSchedule(generation: generation)
        }
        batteryRefreshWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + BluetoothBatteryPollingPolicy.interval,
            execute: work
        )
    }

    func stopBatteryPolling(reason: String) {
        batteryRefreshWorkItem?.cancel()
        batteryRefreshWorkItem = nil
        guard batteryPollingActive else { return }
        batteryPollingActive = false
        AppLogger.shared.write("BLE BATTERY polling_stopped reason=\(reason)")
    }

    func requestBatteryStateRefresh(
        peripheral: CBPeripheral,
        reason: String,
        pollingOnly: Bool
    ) {
        var requested: [String] = []
        if let batteryCharacteristic,
           !pollingOnly || batteryLevelNeedsPolling {
            peripheral.readValue(for: batteryCharacteristic)
            requested.append("level")
        }
        if let batteryStatusCharacteristic,
           !pollingOnly || batteryStatusNeedsPolling {
            peripheral.readValue(for: batteryStatusCharacteristic)
            requested.append("power")
        }
        guard !requested.isEmpty else { return }
        AppLogger.shared.write(
            "BLE BATTERY refresh_requested reason=\(reason) " +
                "fields=\(requested.joined(separator: ","))"
        )
    }
}
