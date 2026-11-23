# Mac iPhone Stream

把 Mac 上选定的窗口和所属应用的声音串流到 iPhone。在 Mac 主机打开触控演示窗口后，iPhone 可以把多点触控回传到该窗口。其他窗口用于观看和收听。

## 要求

- Apple 芯片 Mac，macOS 14.2 或更新版本。
- Xcode，安装 macOS 和 iOS 构建组件。iPhone 客户端的部署目标是 iOS 17。
- Mac 安装 Python 3.11 或更新版本，无需安装 Python 包。
- 局域网模式需要两台设备在同一可信局域网。USB 模式需要数据线和 iPhone 对 Mac 的系统信任。

## 构建

在项目根目录运行以下命令。

    ./macos/build.sh
    ./ios/build.sh simulator

Mac App 位于 macos/build 目录。iPhone 模拟器 App 位于 ios/build/Simulator/Build/Products/Release-iphonesimulator。可在 Xcode 打开 ios/MacIPhoneStream.xcodeproj，选择自己的签名 Team 和唯一 Bundle Identifier，然后运行到自己的 iPhone。./ios/build.sh device 生成未签名的 arm64 设备构建。

## 连接

1. 打开 Mac 主机。首次使用时，通过主机界面检查「屏幕与系统音频录制」权限，再刷新窗口列表。
2. 选择要串流的窗口。为了体验多点触控，点击「使用触控测试窗口」。
3. 在 Mac 点击开始串流。iPhone 可以扫描 Mac 显示的二维码，或粘贴完整会话链接。局域网模式需要允许 iPhone App 的本地网络权限。
4. 如需重复连接，在 Mac 打开设备配对，在 iPhone 选择或扫描该 Mac，核对两端六位码后在 Mac 批准。之后受信任的手机可启动 Mac 主机已选窗口的串流。配对需要 Mac 主机处于运行状态。
5. USB 模式下，连接数据线并在 iPhone 选择 USB，再使用同一会话二维码或链接。若该系统版本未在 usbmux 中列出设备，使用局域网模式。
6. 在 Mac 点击停止会使本次链接失效。撤销受信任设备也会停止当前会话。

设备配对和远程启动使用固定主机证书的 HTTPS。局域网音视频和触控使用带短时令牌的 HTTP，仅在可信的本地网络使用。二维码和链接包含本次会话的访问令牌。主机可采集窗口所属应用的声音，采集范围可能包括同一应用其他窗口的音频。

USB 中继使用系统已有的 usbmux 通道，并通过会话令牌验证手机端。现有回环测试覆盖中继与 iPhone 端实现，实体线缆上的设备枚举和完整串流仍需验证。

## 测试

    python3 -B -m unittest discover -s host -p 'test_*.py'
    python3 -B -m unittest discover -s host/usb -p 'test_*.py'
    ./macos/test-capture.sh
    ./ios/test.sh

主机集成测试使用回环地址、临时设备身份和合成采集数据，验证媒体帧、静止画面心跳、多触点、断流释放及会话撤销。

## 源码来源与许可

本项目由原有本地串流原型的媒体、触控、配对和传输代码整理而成。Apple 框架由系统与 Xcode 提供。USB 通道的协议实现参考了 [libimobiledevice 的 usbmuxd 文档](https://github.com/libimobiledevice/usbmuxd/blob/9ff690acc10bce8307cfba809a5998b218589e16/README.md)。

本构建为源码审阅版本。项目所有者尚未选定分发许可。
