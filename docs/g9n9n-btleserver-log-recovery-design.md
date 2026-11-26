# G9N9N 全批次蓝牙日志描述文件（`.mobileconfig`）按键恢复设计文档

## 1. 背景与问题定性

市面上的 Google Chromecast Voice Remote（**G9N9N**，VID `0x18D1` / PID `0x9450`）存在多个硬件修订与固件批次。尽管语音键（ATVV 协议，走独立 GATT 特征通道）在已知批次上均能稳定工作，但普通按键（走 HOGP / HID over GATT）在 macOS 公开 `IOHID` 层的表现存在显著分化：

| 批次标识 | 普通按键 Report 格式 | HID 描述符声明（不含 ID） | 固件实际发送（不含 ID） | macOS `BTLEServer` 行为 | 公开 `IOHID` 结果 | 无描述文件时的支持状态 |
| --- | --- | --- | --- | --- | --- | --- |
| **`0x0110` / 固件 `26.2`**（`PVT/MP`） | Report ID `1`（2 个 8-bit usage 索引） | 2 字节 | 2 字节（例如 `03 00`、`00 00`） | 校验通过并递交 | 全键按下与松开正常到达 | **完全支持（14 颗单键 + 语音）** |
| **`DIS A0` / 固件 `26.7`**（以及表现一致的 `0x0110` / `26.0` `CR PVT/MP`） | Report ID `1`（2 个 8-bit usage 索引） | 2 字节 | 单键与松开仅发 **1 字节**（`03` / `00`）；同时按两键发 **2 字节**（`03 0B`） | 1 字节短报告在长度校验失败后被丢弃；2 字节双键通过 | 仅双键组合到达 `IOHID`，单键与松开完全丢失 | **部分支持（语音 + 方向键+OK 发 Enter）** |
| **`HID 0x011B`**（社区实测批次） | Report ID `2`（16-bit 小端 consumer usage + 8-bit 按钮字段） | 3 字节 | 按下与松开仅发 **2 字节**（例如 `42 00`、`00 00`） | 所有普通按键均因长度不符被丢弃 | **连双键都收不到**，普通按键零事件 | **仅语音可用** |

### 为什么 `BTLEServer` 会丢弃这些报告？

macOS 通过系统守护进程 `bluetoothd` 与 `BTLEServer` 接收 BLE HID 的 GATT notification / indication。当 `BTLEServer` 收到输入报告后，会核对报告长度是否与设备 HID Report Map 描述符中对应 Report ID 声明的字节数一致：

- 对于 `0x011B`，Report ID 2 声明为 3 字节 payload，固件却固定只发 2 字节；
- 对于 `26.7`，Report ID 1 声明为 2 字节 payload，固件在单键按下与松开时只发 1 字节。

长度校验不通过时，`BTLEServer` 直接丢弃该报文，不会将其注入 macOS HID 事件系统，也不会触发 `IOHIDManager` / `IOHIDDevice` 的任何回调。任何仅依赖公开 `IOHID` 接口的用户态应用都无法收到这些按键。

---

## 2. 核心机制与可行性原理

### 2.1 系统统一日志中的关键线索

社区调研与真机抓包确认（参考 [brightac/remote-buddy#1](https://github.com/brightac/remote-buddy/issues/1)、[#2](https://github.com/brightac/remote-buddy/issues/2)、[#7](https://github.com/brightac/remote-buddy/issues/7)）：**`BTLEServer` 在丢弃报告之前，会向 macOS 统一日志（Unified Logging）输出两条可关联的 debug 级别信息**：

1. **`bluetoothd` 派发行**（子系统 `com.apple.bluetooth`）：记录该 GATT indication / notification 来自哪一个外设 UUID，例如：
   ```text
   Dispatching GATT indication for device "11111111-2222-3333-4444-555555555555" to session "com.apple.BTLEServer-central-634-17"
   ```
2. **`BTLEServer` 报告行**（子系统 `com.apple.bluetooth`，category `BTLEServer`）：记录 Report ID、长度与原始十六进制字节（**注意：此处为不含 Report ID 前缀的原始 GATT payload**），例如：
   ```text
   Updated input report for ID #2: {length = 2, bytes = 0x4200}
   Updated input report for ID #1: {length = 1, bytes = 0x03}
   ```

在默认隐私策略下，macOS 会把敏感字段脱敏成 `<private>`：

```text
Updated input report for ID #2: <private>
```

### 2.2 最小权限 `.mobileconfig` 描述文件

通过向 macOS 安装一个类型为 `com.apple.system.logging` 的配置描述文件（`.mobileconfig`），并**仅针对 `com.apple.bluetooth` 子系统**启用 `Enable-Private-Data` 与 `Level.Enable = Debug`：

- 不需要关闭 SIP，不需要 root 权限运行 Remote Buddy；
- **不需要开启全局 `System.Enable-Private-Data`**（不会暴露其他 App 或系统服务的日志私有数据）；
- **不开启 `Persist = Debug`**（不强迫系统将海量蓝牙 debug 日志持久化写入磁盘，仅影响实时 `log stream` 内存流）；
- 描述文件可由用户在 **系统设置 → 通用 → 设备管理** 中随时审查并一键移除。

应用内置描述文件路径为 `Resources/Profiles/RemoteBuddy-G9N9N-BluetoothLogging.mobileconfig`，核心 payload 如下：

```xml
<key>PayloadType</key>
<string>com.apple.system.logging</string>
<key>Subsystems</key>
<dict>
    <key>com.apple.bluetooth</key>
    <dict>
        <key>DEFAULT-OPTIONS</key>
        <dict>
            <key>Enable-Private-Data</key>
            <true/>
            <key>Level</key>
            <dict>
                <key>Enable</key>
                <string>Debug</string>
            </dict>
        </dict>
    </dict>
</dict>
```

### 2.3 性能与延迟特性

非 root 进程以如下参数拉起统一日志流：

```text
/usr/bin/log stream --style ndjson --level debug --predicate '...'
```

由于使用 `NSPredicate` 在内核/日志守护进程侧按进程名与前缀直接过滤，只有匹配 `BTLEServer` / `bluetoothd` 特定事件的消息才会进入管道。社区在 Apple Silicon 上的真机实测延迟为**中位数约 6.9 ms、p90 约 10.1 ms**，CPU 占用接近 0%，足以稳定区分双击（300 ms 窗口）、长按（550 ms 阈值）与连发（350 ms 起步）。

### 2.4 非 root 描述文件安装状态检测

在 macOS 上，`log config --status` 需要 root 权限，而 `/usr/bin/profiles list -output stdout-xml` **无需 root 即可读取已安装的描述文件清单**。Remote Buddy 通过以下双信号判断描述文件状态：

1. **静态清单解析**（`BluetoothLoggingProfileService`）：解析 `profiles list -output stdout-xml` 输出的 XML plist，检查是否存在 `PayloadType == "com.apple.system.logging"` 且对 `com.apple.bluetooth`（或全局 `System`）启用了 `Enable-Private-Data = true` 的条目。该检测不死绑单一 UUID，既能识别 Remote Buddy 内置描述文件，也能兼容用户自行安装的其他官方蓝牙日志描述文件。
2. **实时脱敏探测**（`BTLEServerReportLog`）：当日志流中收到 `Updated input report for ID #...: <private>` 时，标记 `btleServerLogRedactedObserved = true`，向 UI 明确反馈「系统正在丢弃报文且私有数据仍处于遮蔽状态，请确认描述文件已安装生效」。

---

## 3. 产品边界与安全原则

1. **默认关闭、显式开启（Strict Opt-In）**：
   - `AppSettings.g9n9nBluetoothLogRecoveryEnabled` 默认为 `false`。
   - 只要用户未主动打开此增强开关，Remote Buddy **绝不**启动 `/usr/bin/log stream` 子进程，零后台额外开销，也完全不读取系统蓝牙日志。
2. **保留零配置降级方案**：
   - 原有针对 `26.7 / 26.0` 的「部分支持（双键兼容）模式」完整保留。不愿安装描述文件的用户仍可零配置使用语音键 + 「方向键 + OK」发送 Enter。
3. **无静默安装、无提权、不篡改证书信任**：
   - Remote Buddy 只负责把内置 `.mobileconfig` 复制到临时路径并通过 `NSWorkspace.shared.open` 交给 macOS 系统队列，以及引导跳转「设备管理」设置页。
   - 描述文件不进行自签名信任注入；用户可在安装前审查明文 XML 内容并自主确认。
4. **严格的外设隔离与本地隐私**：
   - 仅收集当前用户在 Remote Buddy 中已配置/绑定的 Chromecast G9N9N 外设 UUID（`bluetoothIdentifier`）的报文；其他蓝牙键盘、鼠标、耳机、手机等设备的 GATT 报告一律在归属阶段丢弃，不进入处理管线、不写入日志、不持久化、不上传。
5. **外部依赖风险声明**：
   - 该机制依赖 macOS `bluetoothd` 与 `BTLEServer` 的内部日志格式。若未来 macOS 大版本修改了日志文案，日志恢复通道会静默停止转发，不会崩溃，也不会影响常规 `IOHID` 设备与 ATVV 语音功能。

---

## 4. 总体架构与数据流

```text
[用户主动开启开关] + [在系统设置安装 .mobileconfig]
                    │
                    ▼
    BluetoothLoggingProfileService
    (非 root 解析 profiles list XML + 打开描述文件/设备管理页)
                    │
                    ▼
    BridgeAppModel (持有唯一共享 BTLEServerReportLogSource 实例)
      ├─ OSAllocatedUnfairLock<Set<UUID>> 保存目标 G9N9N bluetoothIdentifier
      ├─ 仅当 started && g9n9nBluetoothLogRecoveryEnabled && 权限就绪
      │  && 非休眠 && 存在 G9N9N 设备或处于 G9N9N 向导时运行
      ├─ /usr/bin/log stream --style ndjson --level debug
      │     ├─ <private> 脱敏行 ──▶ 更新 btleServerLogRedactedObserved 提示安装
      │     └─ Attributor 归属成功 ─▶ AttributedReport(peripheral, reportID, data)
      └─ 按 peripheral UUID → profileID → hidFingerprint 精确路由
                    │
                    ▼
    HIDRemoteMonitor (对应已绑定 monitor 或 discoveryHIDMonitor)
      ├─ origin = .btleServerLog (vs .iohid)
      ├─ G9N9NProtocol.usages(..., payloadOnly: origin == .btleServerLog)
      │     ├─ Report ID 1 (1B/2B payload): 覆盖 26.2、26.7、26.0
      │     └─ Report ID 2 (2B consumer usage): 覆盖 0x011B
      ├─ 跨来源归一化去重 (150ms 窗口内比较 reportID + 解码后的 usages 集合)
      └─ 按 usage 跟踪 btleLogActiveUsages → 禁用原生直通 + 跳过事件抑制
```

### 为什么由 `BridgeAppModel` 持有唯一共享日志源？

在现有架构中，`BridgeAppModel.HIDMapping.swift` 会为每个已绑定遥控器创建一个 `HIDRemoteMonitor`，外加一个 `discoveryHIDMonitor`。如果把 `log stream` 放在单个 `HIDRemoteMonitor` 内部：
- 仅连接 1 只 G9N9N 就会同时拉起 **2 个** `/usr/bin/log stream` 子进程；
- 在多只 G9N9N 遥控器并存时无法根据 `peripheral UUID` 精准分流。

因此由 `BridgeAppModel` 集中维护唯一共享的 `BTLEServerReportLogSource`，再根据 `AttributedReport.peripheral` 反查 `RemoteDeviceProfile.bluetoothIdentifier` 与 `hidFingerprint`，精准投递到对应 `HIDRemoteMonitor`（未完成指纹绑定的设备则投递到 `discoveryHIDMonitor`）。

---

## 5. 关键技术细节与边界加固

相比社区 PR #4/#5 的初步实现，本设计针对全批次兼容与工程健壮性做了以下 6 项关键加固：

### 5.1 全批次 Report 解码与 Power 键防误判

`G9N9NProtocol.usages(reportID:data:descriptor:payloadOnly:)` 新增 `payloadOnly: Bool = false` 参数：

- **当 `origin == .iohid`**（`payloadOnly == false`）：完整保留现有 IOHID 解析与 `[1, 0]` 短松开补齐逻辑（确保 IOHID 回调下的 `01 00` 不会误触发 `0x01` 电源键）。
- **当 `origin == .btleServerLog`**（`payloadOnly == true`）：`BTLEServer` 日志中的字节**永远是不含 Report ID 的原始 GATT payload**：
  - **Report ID 1（`usesIndexedConsumerLayout(descriptor) == true`）**：同时接受 **1 字节**和 **2 字节** payload（每个字节索引均在 `0...17` 范围内）：
    - `[0x00]` 或 `[0x00, 0x00]` → `[]`（全松开）；
    - `[0x01]` 或 `[0x01, 0x00]` → `[.power]`（电源键不会与 `[1, 0]` 混淆）；
    - `[0x03]` → `[.up]`（完整覆盖 `26.7` / `26.0` 单键短包）；
    - `[0x03, 0x0B]` → `[.up, .back]`（完整覆盖双键组合）。
  - **Report ID 2（`0x011B`）**：跳过首字节 `2` 剥离分支，直接按 16-bit 小端 consumer usage 解析，确保 14 颗按键与 `[0x00, 0x00]` 松开无歧义。

### 5.2 外设归属与无 dispatch 松开恢复状态机

`BTLEServerReportLog.Attributor` 维护两个状态：
- `lastIndication: (peripheral: UUID, timestamp: TimeInterval)?`
- `heldByPeripheral: [UUID: (reportID: UInt32, maxLength: Int)]` 与 `lastHeldPeripheral: UUID?`

匹配规则：
1. **标准有归属窗口匹配**：收到 `bluetoothd` 的 `Dispatching GATT (indication|notification) for device "<UUID>" to session "...BTLEServer..."` 后，在 `[-5 ms, +200 ms]` 窗口内匹配紧随其后的 `BTLEServer` report 行（实测最大延迟约 46 ms，留足余量）。若该 UUID 不在目标 G9N9N 集合中（例如蓝牙键盘/鼠标），直接丢弃且**不清空其他遥控器的持键状态**。
2. **无独立 dispatch 的松开恢复**（解决社区 Issue #7 实测发现的松开无 dispatch 行问题，同时兼容 `26.7` 双键长度变化）：
   - 当一条 report 未命中有效窗口内的目标 indication，但其 payload **全部为 `0x00`** 时：
   - 检查最近持键的目标外设 `candidate` 是否有 `held = heldByPeripheral[candidate]`，满足 `held.reportID == report.reportID` 且 **`(1...held.maxLength).contains(report.data.count)`**；
   - 放宽长度匹配为 `1...held.maxLength` 的原因：`26.7` 批次同时按两键发出 **2 字节**（`03 0B`），而全松开时固件只发出 **1 字节**（`00`）。放宽后可确保双键按下后的 1 字节松开不卡键。

### 5.3 跨来源归一化去重

对于完全支持批次（`0x0110 / 26.2`）或 `26.7` 双键组合，同一按键会同时到达 `IOHID` 和 `BTLEServer` 日志两路：
- `IOHID` 上报的字节带 Report ID 前缀（如 `01 03 00`，3 字节）；
- `btle_log` 上报的字节不带 Report ID 前缀（如 `03 00`，2 字节）。

若像社区初步方案那样直接拿原始字节拼去重键，Report ID 1 上会因为 `3 字节 != 2 字节` 导致去重失效，产生连击或干扰手势识别。本方案改为在 `parseReport` 解码之后，以 **`(reportID, decodedUsages: Set<UInt16>)`** 作为归一化键在 **150 ms** 窗口内跨 `.iohid` 与 `.btleServerLog` 去重，先到先处理、后到丢弃。

### 5.4 原生直通禁用与事件抑制隔离

- **问题**：默认情况下，`HIDRemoteMonitor.shouldUseNativePassthrough` 对「左键 → `arrowLeft`」「右键 → `arrowRight`」在未独占设备（unseized）时走 macOS 原生直通，且对其他按键调用 `eventSuppressor.arm` 拦截系统 180 ms 内生成的原生按键事件。然而来自 `btle_log` 的报告已经被 `BTLEServer` 丢弃，macOS 根本不会产生原生事件。
- **方案**：
  - 使用 `currentReportOrigin: HIDReportOrigin`（带 `defer` 栈式恢复）并在 `btleLogActiveUsages: Set<UInt16>` 中按 usage 记录当前按下是否来自 `btle_log`；
  - `shouldUseNativePassthrough` 对 `.btleServerLog` 显式返回 `false`，由 Remote Buddy 主动注入左右方向键；
  - 统一封装 `armNativeSuppression(button:edge:fromBTLEServerLog:)` 替换所有 `eventSuppressor.arm` 调用点——无论在按下、松开、双键兼容路径还是 `missing_release` / `hard_ceiling` 超时恢复路径，只要来源于 `btle_log` 一律跳过拦截，避免误吞用户同时敲击真实键盘的按键。

### 5.5 线程安全与 Swift 6 `StrictConcurrency`

- `BTLEServerReportLogSource` 使用 `OSAllocatedUnfairLock<Set<UUID>>` 持有当前需要监听的外设 UUID 集合，`BridgeAppModel` 在主线程状态变化时调用 `updatePeripherals(_:)` 更新，子线程解析时无锁等待主线程（彻底消除社区方案在后台队列 `DispatchQueue.main.sync` 导致的停止/重启死锁风险）。
- 同样使用 `OSAllocatedUnfairLock` 保护非线程安全的 `DateFormatter` 时间戳解析器。
- 进程异常退出采用退避重连（`1s, 2s, ..., 上限 30s`），并在成功解析交付首条报告后归零计数；在系统休眠（`suspendHIDMonitoring`）和权限撤销时同步停止进程，唤醒后再重建。

### 5.6 首次向导、设置页与模式平滑升级

- **首次/添加设备向导（`OnboardingView`）**：
  - 保持现有「先测单按 OK，无反应可尝试上+OK 并勾选部分支持模式」的零配置主流程；
  - 在 Chromecast 兼容提示卡片内提供可展开/可选的「全键兼容增强（蓝牙日志描述文件）」开关（默认关闭）；
  - 用户主动开启后，显示描述文件安装状态、一键打开 `.mobileconfig`、跳转系统设置「设备管理」、重新检测按钮，并在检测到 `<private>` 时给出醒目提示；
  - 安装并生效后，直接按一下 OK 键即可通过 `btle_log` 通道进入**完全支持模式**，完成后续 3 键验证与全 14 键映射。
- **设置页（连接页 & 映射页）**：
  - 在 G9N9N 设备硬件卡片中增加「全键兼容增强（蓝牙日志描述文件）」开关、状态标识、安装/卸载说明；
  - 对之前已进入「部分支持模式」的用户，只要在设置页开启开关并安装描述文件，当首次从 `btle_log` 收到单键按下报告时，自动将其 profile 从 `.twoKeyCompatibility` 平滑升级回 `.full` 并刷新按键状态，无需移除重配。
- **诊断摘要**：
  - 在首用诊断文本中记录 `g9n9n_btle_log_recovery_enabled`、`bluetooth_logging_profile` 与 `btle_log_redacted_observed` 三个布尔/枚举字段，绝不记录任何外设 UUID 或报文内容。

---

## 6. 测试与真机验收规划

### 6.1 自动化单元测试

1. **`BTLEServerReportLogTests`**：
   - Report ID 2（`0x011B`）14 键 + `0000` 解码；
   - Report ID 1（`26.7`）1 字节单键（含 `0x01` Power、`0x03` Up、`0x07` OK）、2 字节双键（`03 0B`）、1 字节 `0x00` 松开；
   - `indication` 与 `notification` 两种 `bluetoothd` 派发日志格式；
   - 2 字节双键按下后无 dispatch 的 1 字节 `0x00` 松开归属；
   - `<private>` 脱敏报告检测、缩略长包过滤、多 G9N9N 隔离、蓝牙键盘干扰隔离；
   - `BluetoothLoggingProfileService` XML 解析与内置 `.mobileconfig` 资源校验。
2. **`G9N9NProtocolTests` / `HoldRepeatConfigurationTests` / `G9N9NCompatibilityModeTests`**：
   - `payloadOnly: true` 与 `iohid` 短松开（`[1, 0]`）边界隔离；
   - `IOHID (01 03 00)` 与 `btle_log (03 00)` 跨来源去重；
   - `btle_log` 左右方向键主动注入而非原生直通；
   - `btle_log` 按下/松开/超时恢复不误触发 `eventSuppressor`；
   - 开关默认 `false`、持久化以及开启后由 `.twoKeyCompatibility` 平滑升级为 `.full`。

### 6.2 真机验收清单

1. **未开启开关（默认状态）**：确认 `ps aux | grep "/usr/bin/log"` 无任何额外 `log stream` 进程。
2. **`0x011B` 样机**：开启开关（未装描述文件）触发 `<private>` 提示 → 安装 `.mobileconfig` → 完成全键向导 → 验证全部 14 颗键（含左右键光标移动、单击/双击/长按/连发）与语音键。
3. **`26.7` / `26.0` 样机**：验证单键 1 字节恢复、电源键 `0x01` 不误判、双键按下后 1 字节 `0x00` 松开不卡键，以及已配对部分支持模式升级回完全支持模式。
4. **`0x0110 / 26.2` 样机**：开启开关并安装描述文件后，验证 `IOHID` 与 `btle_log` 去重准确，不触发连击。
5. **移除描述文件 / 关闭开关**：在系统设置移除描述文件后，确认系统恢复 `<private>` 遮蔽且 App 不崩溃、关闭开关后立即终止 `log stream` 进程。
