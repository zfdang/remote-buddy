# G9N9N 全批次蓝牙日志描述文件（`.mobileconfig`）按键恢复设计文档

## 1. 背景与问题定性

市面上的 Google Chromecast Voice Remote（**G9N9N**，VID `0x18D1` / PID `0x9450`）存在多个硬件修订与固件批次。尽管语音键（ATVV 协议，走独立 GATT 特征通道）在已知批次上均能稳定工作，但普通按键（走 HOGP / HID over GATT）在 macOS 公开 `IOHID` 层的表现存在显著分化：

| 批次标识 | 普通按键 Report 格式 | HID 描述符声明（不含 ID） | 固件实际发送（不含 ID） | macOS `BTLEServer` 行为 | 公开 `IOHID` 结果 | Remote Buddy 接入方式 |
| --- | --- | --- | --- | --- | --- | --- |
| **`0x0110` / 固件 `26.2`**（`PVT/MP`） | Report ID `1`（2 个 8-bit usage 索引） | 2 字节 | 2 字节（例如 `03 00`、`00 00`） | 校验通过并递交 | 全键按下与松开正常到达 | **已验证 · 原生完全支持（`Standard System HID`）**：语音 + 14 颗普通按键 |
| **`DIS A0` / 固件 `26.7`**（已抓包） | Report ID `1`（2 个 8-bit usage 索引） | 2 字节 | 单键与松开仅发 **1 字节**（`03` / `00`）；同时按两键发 **2 字节**（`03 0B`） | 1 字节短报告在长度校验失败后被丢弃 | 单键与松开无法正常到达公开 `IOHID` | **待真机验收 · 蓝牙日志描述文件恢复（`.mobileconfig`）** |
| **`0x0110` / 固件 `26.0`**（`CR PVT/MP`） | 声明 Report ID `1` 尺寸，**原始 BLE 报文待抓包确认** | 2 字节 | **待抓包确认** | 公开 `IOHID` 单键无响应 | 单键与松开无法正常到达公开 `IOHID` | **待抓包与真机验收**（解析兼容性需抓包后再确认） |
| **`HID 0x011B`**（社区实测批次） | Report ID `2`（16-bit 小端 consumer usage + 8-bit 按钮字段） | 3 字节 | 按下与松开仅发 **2 字节**（例如 `42 00`、`00 00`） | 所有普通按键均因长度不符被丢弃 | 普通按键零事件 | **待真机验收 · 蓝牙日志描述文件恢复（`.mobileconfig`）** |

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
/usr/bin/log stream --style ndjson --level debug --predicate 'subsystem == "com.apple.bluetooth" AND (...)'
```

入口谓词与 NDJSON 解析器（`BTLEServerReportLog.parse(ndjsonLine:)`）均明确限制仅接收 `subsystem == "com.apple.bluetooth"` 的 `bluetoothd` / `BTLEServer` 事件。社区在 Apple Silicon 上的真机实测延迟为**中位数约 6.9 ms、p90 约 10.1 ms**，CPU 占用接近 0%，足以稳定区分双击（300 ms 窗口）、长按（550 ms 阈值）与连发（350 ms 起步）。

### 2.4 非 root 描述文件安装状态检测

在 macOS 上，`log config --status` 与 `profiles list` 读取系统级作用域需要 root 权限，而 `/usr/sbin/system_profiler SPConfigurationProfileDataType -xml` **无需 root 即可读取设备级与用户级配置描述文件**（解析失败时再以 `/usr/bin/profiles list -output stdout-xml` 兜底）。Remote Buddy 通过以下双信号判断描述文件状态：

1. **静态清单解析**（`BluetoothLoggingProfileService`）：优先解析 `system_profiler SPConfigurationProfileDataType -xml`（支持 OpenStep ASCII plist 中的 `1`/`true` 布尔表达），再必要时回退解析 `profiles list -output stdout-xml`，检查是否存在 `com.apple.system.logging` 且对 `Subsystems["com.apple.bluetooth"]`（`DEFAULT-OPTIONS` 或 `BTLEServer`）同时启用了 `Enable-Private-Data = true` 与 `Level.Enable == "Debug"`（大小写不敏感）的条目。**仅当明确确认 `.installed` 时才允许启动 `/usr/bin/log stream`**；无论是 `.notInstalled` 还是受限于查询环境返回的 `.unknown`，日志读取器均保持未启动。
2. **实时脱敏探测与独立暂停状态**（`BTLEServerReportLog` + `BridgeAppModel`）：当日志流中收到直接归属到目标外设（`peripheral != nil`）的 `<private>` 脱敏报文时，标记 `btleServerLogRedactedObserved = true` 并**立即停止 `/usr/bin/log stream`**；即使随后静态查询仍返回 `.installed`，也不会自动清除运行时暂停标记或重启日志流，必须等待用户处理后显式点击「重新检测」再次确认 `.installed` 才会恢复。对于无直接外设归属的 `<private>`（`peripheral == nil`，常见于其他蓝牙 HID 设备），在当前状态仍为 `.installed` 时按节流间隔异步刷新静态状态而不误停；若后台刷新确认描述文件已被移除（`.notInstalled`），则立即停止日志读取。

---

## 3. 产品边界与安全原则

1. **默认关闭、显式开启与无效即停（Strict Opt-In & Fail-Closed Lifecycle）**：
   - `AppSettings.g9n9nBluetoothLogRecoveryEnabled` 默认为 `false`。
   - 仅当开关开启、权限与设备就绪、存在已完成 `hidFingerprint` 绑定的非原生 G9N9N 目标、静态确认 `.installed` 且未处于 `<private>` 运行时暂停时，才允许启动 `/usr/bin/log stream`；停用时不仅递增代数（`btleServerReportLogGeneration`）并设置 `isActive` 丢弃排队回调，还会同步清理绑定监听器中由 `btle_log` 触发的持键状态、连发定时器与延迟单双击/长按计时器。
2. **统一二元模式模型与退役影响**：
   - G9N9N 仅保留两种支持模式：**原生完全支持（`.full`）** 与 **蓝牙日志描述文件支持（`.bluetoothLogRecovery`）**。
   - 若设备普通按键可通过公开 `IOHID` 完整识别，则始终走原生通道（并禁止 `btle_log` 对其重复触发）；原 `26.7 / 26.0` 「部分支持（方向键 + OK 发 Enter）」已退役——未安装 `.mobileconfig` 时非原生批次仅保留 ATVV 语音且无法通过单键向导验证；老配置中的 `"two_key_compatibility"` 在解码时单字段安全降回默认 `.full`，绝不导致整组 `remoteDeviceProfiles` 解码失败。
3. **无静默安装、无提权、不篡改证书信任**：
   - Remote Buddy 只负责把内置 `.mobileconfig` 复制到临时路径并通过 `NSWorkspace.shared.open` 交给 macOS 系统队列，以及引导跳转「设备管理」设置页。
   - 描述文件不进行自签名信任注入；用户可在安装前审查明文 XML 内容并自主确认。
4. **严格的外设隔离、物理绑定校验与无原始字节诊断日志**：
   - 仅将日志源订阅及路由限定在已完成 `bluetoothIdentifier + hidFingerprint` 绑定的 `.bluetoothLogRecovery` 设备（或配对向导中已完成 HID 绑定的当前选中 G9N9N）；**绝不**将日志报文路由到未绑定的 `discoveryHIDMonitor`，已确认为原生 `.full` 的设备也绝不会走日志恢复分支；
   - `Attributor` 将窗口收紧至 `100 ms` 并校验 G9N9N 合法短报文形状（ID 1 的 1–2B、ID 2 的 2B）；多外设交错活动、超 10 秒过期/已移除设备的遗留持键、`hidFingerprint` 或对应 `hidMonitors[fingerprint]` 缺失均直接清理并丢弃事件；
   - `btle_log` 路径在任何诊断日志中均不输出原始 payload 十六进制字节，也不持久化、不上传。
5. **外部依赖风险声明**：
   - 该机制依赖 macOS `bluetoothd` 与 `BTLEServer` 的内部日志格式，以及 `bluetoothd` 派发与 `BTLEServer` 报告在 100 ms 窗口内的成对日志顺序。若未来 macOS 大版本修改日志文案或其它 BLE 外设彻底缺失派发行，日志恢复可能漏报或无法确认归属（遵循 fail-closed 原则丢弃），但不会崩溃，也不会影响常规 `IOHID` 设备与 ATVV 语音功能。

---

## 4. 总体架构与数据流

```text
[用户主动开启开关] + [在系统设置安装 .mobileconfig]
                    │
                    ▼
    BluetoothLoggingProfileService
    (非 root 优先解析 system_profiler SPConfigurationProfileDataType -xml；未确认 .installed 一律不启动)
                    │
                    ▼
    BridgeAppModel (持有唯一共享 BTLEServerReportLogSource + generation 校验)
      ├─ OSAllocatedUnfairLock<Set<UUID>> 仅保存已绑定 hidFingerprint 的非原生 G9N9N
      ├─ 仅当 started && g9n9nBluetoothLogRecoveryEnabled && 权限就绪 && 非休眠
      │  && profile == .installed && !redactedObserved && !targets.isEmpty 时运行
      ├─ /usr/bin/log stream --style ndjson --level debug --predicate 'subsystem == "com.apple.bluetooth" AND ...'
      │     ├─ 已归属 <private> ──▶ 标记 redacted 并立即暂停 log stream（静态 .installed 不自动清零）
      │     └─ Attributor 归属成功 ─▶ AttributedReport(peripheral, reportID, data)
      └─ 校验 generation 与开关有效 → bluetoothIdentifier + hidFingerprint → 对应已绑定 HIDRemoteMonitor
                    │
                    ▼
    HIDRemoteMonitor (仅限 targetFingerprint / deviceFingerprint 已确认的监控器)
      ├─ origin = .btleServerLog (vs .iohid)
      ├─ G9N9NProtocol.usages(..., payloadOnly: origin == .btleServerLog)
      │     ├─ Report ID 1 (1B/2B payload): 覆盖 26.2、26.7（26.0 待抓包核实）
      │     └─ Report ID 2 (2B consumer usage): 覆盖 0x011B（待真机逐键验收）
      ├─ 跨来源归一化去重 (150ms 窗口内比较 reportID + 解码后的 usages 集合)
      └─ 按 usage 跟踪 btleLogActiveUsages → 禁用原生直通 + 跳过事件抑制
```

### 为什么由 `BridgeAppModel` 持有唯一共享日志源？

在现有架构中，`BridgeAppModel.HIDMapping.swift` 会为每个已绑定遥控器创建一个 `HIDRemoteMonitor`，外加一个 `discoveryHIDMonitor`。如果把 `log stream` 放在单个 `HIDRemoteMonitor` 内部：
- 仅连接 1 只 G9N9N 就会同时拉起 **2 个** `/usr/bin/log stream` 子进程；
- 在多只 G9N9N 遥控器并存时无法根据 `peripheral UUID` 精准分流。

因此由 `BridgeAppModel` 集中维护唯一共享的 `BTLEServerReportLogSource`，且仅在设备通过 `learnSelectedRemoteHIDIdentity` 等流程完成 `bluetoothIdentifier` 与 `hidFingerprint` 绑定后，才将其纳入日志监听并将 `AttributedReport` 精确投递至对应的已绑定 `HIDRemoteMonitor`；未完成物理绑定的设备与缺失绑定监听器的事件一律丢弃。

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

### 5.2 外设归属、设备绑定与原生通道隔离

`BTLEServerReportLog.Attributor` 维护 `pendingIndications`、`heldByPeripheral`（含 `pressedAt` 与污染标记）与 `lastActivityByPeripheral`：

1. **可验证归属窗口匹配**：收到 `bluetoothd` 的 `Dispatching GATT (indication|notification) for device "<UUID>" to session "...BTLEServer..."` 后，先校验报告符合 G9N9N 合法短报文格式与已知键码（Report ID 1 的 1–2B 合法索引或全零，或 Report ID 2 的 2B 已知 `consumerButtons` usage 或全零），再在 `[-5 ms, +100 ms]` 窗口内匹配紧随其后的 `BTLEServer` report 行。若同一窗口内出现来自不同外设的交错派发活动，或遇到缺少 dispatch 行的非目标/未知报文，则污染当前持键及最近 `100 ms` 窗口并直接丢弃（平台边界注记：若另一台与 G9N9N 拥有相同合法短报文长度及键码的蓝牙设备恰好也缺失 `bluetoothd` 派发行且落入同一 `100 ms` 窗口，统一日志层面无法独立提供设备 UUID）。
2. **无独立 dispatch 的松开恢复**：当全 `0x00` 松开报文缺少 dispatch 行时，先清理已超过 `10s` 上限或已不在目标列表中的过期按住记录，再仅当同时满足「当前仅唯一一台目标 G9N9N 处于按住状态」「自其按下以来未收到任何其他外设的派发指示或未归属报文（未受污染）」「report ID 与 `1...held.maxLength` 长度一致且在 10 秒按住窗口内」时才允许归属，否则安全丢弃（交给 `missing_release` 超时机制收口）。
3. **精确设备绑定派发与原生 `.full` 设备隔离**：`BridgeAppModel` 与 `HIDRemoteMonitor` 仅接收已完成 `bluetoothIdentifier + hidFingerprint` 绑定且对应 `hidMonitors[fingerprint]` 已就绪的设备；在有 HID 报告描述符时还强校验 Report ID 与描述符布局一致；未完成 HID 绑定的发现阶段或缺失绑定监听器一律丢弃，且两层均拦截已确认为原生 `.full` 的设备，即使日志副本先于 `IOHID` 到达也绝不重复按键。

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

### 5.6 首次向导与设置页接入标识

- **首次/添加设备向导（`OnboardingView`）**：
  - 主流程明确区分两种接入方式：单按 OK 正常进入即自动判定为**原生完全支持（`.full`）**；若单按无响应，向导卡片直接引导用户主动开启「蓝牙日志全键兼容（`.mobileconfig`）」，显示安装/权限作用域提示、一键打开 `.mobileconfig`、跳转系统设置「设备管理」、重新检测按钮与 `<private>` 实时警告；
  - 安装生效后单按 OK 即可通过 `btle_log` 通道进入，完成后续 3 键验证与全 14 键映射。
- **设置页（连接页 & 映射页）**：
  - `G9N9NInputMode` 仅包含 `.full` 与 `.bluetoothLogRecovery` 两个枚举值并按设备独立持久化；
  - 在 **设置 → 遥控器连接（设备详情页）** 的硬件信息网格展示「按键接入方式」（标明 `蓝牙日志描述文件 (.mobileconfig)`），配合说明文本与切换开关呈现；若开关被关闭、描述文件未确认安装（包括 `.unknown` 或 `.notInstalled`）或检测到 `<private>`，详情页会同步显示失效提醒；
  - 在 **按键映射页** 与 **向导完成页** 展示对应的接入来源文字说明（设备卡片不再单独追加「蓝牙日志兼容」徽章，仅原生完全支持保留「完全支持硬件版本」徽章）。
- **诊断摘要**：
  - 在首用诊断文本中记录 `g9n9n_btle_log_recovery_enabled`、`bluetooth_logging_profile` 与 `btle_log_redacted_observed` 三个状态字段，绝不记录任何外设 UUID 或报文内容。

---

## 6. 测试与真机验收规划

### 6.1 自动化单元测试

1. **`BTLEServerReportLogTests`**：
   - Report ID 2（`0x011B`）14 键 + `0000` 解码；
   - Report ID 1（`26.7`）1 字节单键（含 `0x01` Power、`0x03` Up、`0x07` OK）、2 字节双键（`03 0B`）、1 字节 `0x00` 松开；
   - `indication` 与 `notification` 两种 `bluetoothd` 派发日志格式；
   - 多外设交错指示丢弃、多遥控器持键与受污染无 dispatch 松开拒绝；
   - `<private>` 脱敏报告检测、缩略长包过滤；
   - `BluetoothLoggingProfileService` XML 解析（含系统级缺失 `.notInstalled` 与无 `_computerlevel` 返回 `.unknown`）与内置 `.mobileconfig` 资源校验。
2. **`G9N9NProtocolTests` / `HoldRepeatConfigurationTests` / `G9N9NCompatibilityModeTests`**：
   - `payloadOnly: true` 与 `iohid` 短松开（`[1, 0]`）边界隔离；
   - `IOHID (01 03 00)` 与 `btle_log (03 00)` 跨来源去重与双向到达顺序；
   - 原生 `.full` 设备对日志恢复的隔离（两种到达顺序均不重复触发）；
   - 多 G9N9N 设备缺失绑定时不误派发给首个 HID 候选；
   - `btle_log` 路径零原始字节日志输出；
   - 开关默认 `false`、关闭开关/移除描述文件/重启后的状态保留与恢复行为。

### 6.2 真机验收清单

1. **未开启开关（默认状态）**：确认 `ps aux | grep "/usr/bin/log"` 无任何额外 `log stream` 进程。
2. **`0x011B` 样机**：开启开关（未装描述文件）触发 `<private>` 提示 → 安装 `.mobileconfig` → 完成全键向导 → 验证全部 14 颗键（含左右键光标移动、单击/双击/长按/连发）与语音键。
3. **`26.7` / `26.0` 样机**：验证单键 1 字节恢复、电源键 `0x01` 不误判、双键按下后 1 字节 `0x00` 松开不卡键，以及已配对部分支持模式升级回完全支持模式。
4. **`0x0110 / 26.2` 样机**：开启开关并安装描述文件后，验证 `IOHID` 与 `btle_log` 去重准确，不触发连击。
5. **移除描述文件 / 关闭开关**：在系统设置移除描述文件后，确认系统恢复 `<private>` 遮蔽且 App 不崩溃、关闭开关后立即终止 `log stream` 进程。
