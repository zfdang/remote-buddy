# 首次设置

从本项目 GitHub Releases 下载适合 Mac 架构的 PKG，一次安装 App 与虚拟麦克风驱动；打开 `/Applications/Remote Buddy.app`。

首次向导依次检查权限与麦克风、选择遥控器型号、连接遥控器、按键测试、语音热键、输入工具、语音测试和完成。按需授予蓝牙、输入监控和辅助功能权限。小米 RC001／RC003、T1 飞鼠键盘语音遥控器与 G9N9N 有连接适配；GY3LE 和 Siri Remote 尚未完成适配。

**G9N9N：**已验证版本支持语音与普通按键自定义，向导单按 OK 后再依次测试三个不同按键。兼容款存在不同硬件版本，功能支持可能不同，购买时请注意挑选硬件版本，详见[设备指南](https://remote.zfdang.com/device.html)。

App 自动输出到 **Remote Buddy Mic**，无需选择回环设备。在目标输入工具中选择同名麦克风，配置并测试语音快捷键。App 负责音频路由及按键动作；识别由输入工具完成，不采集使用统计、不保存录音或文本历史、不上传日志。

安装驱动需要管理员授权，会短暂重启音频。当前 PKG 未签名、未公证；App 与驱动使用固定自签名身份。Windows 尚未实现。更多说明：https://github.com/zfdang/remote-buddy/blob/main/docs/interface.md
