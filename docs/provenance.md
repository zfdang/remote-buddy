# 移植来源和许可

迁入日期：2026年10月11日。

上游： https://github.com/HD838A/remote-mic-app

本地迁入基线：`cae2a23804506538c31003d14ec3239379da66c1`。本次读取其已提交的 Sources 和 Resources；未复制 `.git`、未提交的 `.omc`、私有包、发布凭据或原产品受限图标及遥控器照片。

代码保留原作者及第三方版权。本次修改包括独立产品命名与 Bundle ID、移除原品牌资产、切断统计与回眸执行路径、停用日志上传和上游服务接入、简化公开构建、独立驱动身份与原创图标。原始声明保存在 upstream-copyright.md 和 upstream-logo-license.md；其中原仓库相对链接仅作为历史来源记录，不是本仓库的链接。

源码按 GPL-3.0-only 发布。第三方清单保留原始来源信息，应结合实际发行内容阅读。未构建的 Apple 扩展与私有适配器不代表本产品已经支持相关设备。

每个发行版必须同时提供对应 App 源码、构建和安装脚本，以及实际分发驱动的 BlackHole v0.7.2 源码、device-usb.patch 和必要许可文本，不能只发布此仓库的链接而遗漏驱动源码。Sparkle 采用 MIT；其打包组件还包括单独许可，需随完整框架保留许可。BlackHole 与其他 GPL 来源按相应要求处理。

程序图标和菜单栏图标基于项目原创素材（与上游同名的 `Resources/AppIcon.png` / `Resources/AppIcon.icns` 为本项目重新创作并随源码按 `GPL-3.0-only` 授权的全新资产），由 `scripts/generate-icons.py` 生成，未使用原品牌图形。

设置向导截图位于 `Resources/Onboarding`，包括从上游继承的图片以及本项目重新截取或生成的微信、豆包、网易叭哥说与 Voice Buddy 浅色图片；保留上游图片的来源归属，不把全部现有截图都归为上游素材。未使用其受限 App Logo 或遥控器产品照片。小米遥控器图是基于本项目按键布局参考生成的无品牌写实渲染；GY3LE 与 Siri Remote 使用原创 SVG 示意图及 PNG 缩略图。G9N9N 使用项目维护者提供的实物照片，抠去背景后保存为 `Resources/ChromecastG9N9NPhoto.png`，机身下方增加了“Remote Buddy / 遥控搭子”文字。设备页的 `g9n9j-in-hand.jpg`、`mi-vs-g9n9n.jpg` 和 `mi-vs-g9n9n-birdview.jpg` 也由项目维护者实际拍摄并提供，未取自厂商产品图库。`scripts/generate-remote-layout-reference.swift` 仅生成小米布局参考，不覆盖成品；按键位置与映射连线共用归一化坐标。提示词及维护说明见 [artwork.md](artwork.md) 与 [示意图说明](../Resources/RemoteIllustrations/README.md)。构建及安装包检查会验证截图与示意图完整性。

网页 `pages/assets/screenshots` 的 36 张中英文界面与向导 PNG 截图于 2026-11-16 使用当前源码的 Debug App 更新，并做无损 PNG 编码优化。设备选择截图同步展示 GY3LE 和 Siri Remote 尚不支持。渲染使用隔离设置与示例设备、权限及驱动状态，不读取个人设置；G9N9N 按键页展示型号默认映射。渲染画面用于说明界面，不构成硬件或语音验收证据。

README 另使用维护者于 2026-11-16 提供的三张真实应用截图：`readme-connection.jpg`、`readme-integration.jpg` 和 `readme-mapping.jpg`，分别展示双遥控器连接、输入法集成和 G9N9N 按键映射。这三张 JPEG 通过 `jpegtran` 无损优化并移除元数据，保留原始像素和分辨率；README 的显示宽度为 640。它们与自动渲染的示例截图分开维护。

腾讯Chatterfly 的两张浅色向导截图由维护者于 2026-11-18 提供，分别展示语音快捷键与全局可用设置、Remote Buddy Mic 选择。设置截图裁去含商标与账号的侧栏，最长边不超过 1600 像素，以压缩 JPEG 保存；深色界面回退到同一浅色截图。网页的 `integration-*`、`wizard-tool-*` 与 README 的 `readme-integration.jpg` 于 2026-11-18 使用当前源码的 Debug App 重新渲染以包含腾讯Chatterfly。
