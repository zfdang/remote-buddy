# First setup

Download the PKG for your Mac architecture from this project's GitHub Releases. It installs both the app and microphone driver. Open `/Applications/Remote Buddy.app`.

The initial guide follows Permissions and Microphone, Remote Model, Connect Remote, Button Test, Voice Trigger, Input Tool, Voice Test, and Complete. Grant Bluetooth, Input Monitoring, and Accessibility permissions as requested. Xiaomi RC001/RC003, T1 air-mouse keyboard voice remotes, and G9N9N have connection adapters; GY3LE and Siri Remote adapters remain incomplete.

**G9N9N:** Validated versions support voice and configurable ordinary buttons. Press OK, then three different buttons during setup. See the [device guide](https://remote.zfdang.com/device_en.html) for supported versions.

The app automatically routes audio to **Remote Buddy Mic**, without a loopback output picker. Select that microphone in your input tool, then configure and test its voice shortcut. Buddy routes audio and buttons; your input tool performs recognition. Buddy does not collect usage statistics, save recordings or transcript history, or upload logs.

Driver installation requires administrator authorization and briefly restarts audio. Current PKGs are unsigned and not notarized; the app and driver use a fixed self-signed identity. Windows is not implemented. More information: https://github.com/zfdang/remote-buddy/blob/main/docs/interface.md
