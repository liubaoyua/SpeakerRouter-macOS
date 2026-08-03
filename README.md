# SpeakerRouter

<p align="center">
  <img src="Assets/IconSources/AppIcon-Transparent.png" width="128" alt="SpeakerRouter icon">
</p>

SpeakerRouter 是一个 macOS 菜单栏应用。它把系统声音发送到优先级最高的
物理输出设备，并为 HDMI、DisplayPort 等不支持系统音量调节的设备提供软件
音量控制。

> [!IMPORTANT]
> 当前项目适合自行构建和测试。构建产物使用 ad-hoc 签名，尚未提供 Developer
> ID 签名、notarization 或自动更新。虚拟音频驱动需要管理员授权安装。

## 功能

- 支持内建扬声器、有线耳机、蓝牙、USB、HDMI、DisplayPort 和 AirPlay 输出。
- 为新设备提供默认分类优先级，并允许手动调整设备顺序。
- 手动选择会保持到该设备断开；断开后恢复自动选择。
- 分设备记忆音量，支持系统音量键、静音键和原生音量 HUD。
- 通过虚拟输出设备和共享内存转发系统混音，不打开麦克风输入。
- App 异常退出或心跳停止时，守护进程恢复最近可用的物理输出。
- App 内提供驱动安装、更新、重新安装和卸载入口。

## 系统要求

- macOS 14 或更高版本。
- Xcode 26 或兼容 Swift 6.2 的工具链。
- Apple Silicon 或 Intel Mac。
- 安装驱动时需要管理员权限。

## 音频路径

```text
macOS 应用与系统声音
          │
          ▼
SpeakerRouter 虚拟输出
          │  共享内存环形缓冲
          ▼
软件音量与静音 → AUHAL → 选中的物理输出
```

虚拟设备保留完整的 Core Audio 对象模型，但输入流只返回静音，SpeakerRouterApp
不会打开它。因此正常路由不会请求麦克风权限，也不会触发录音指示器。更多实现
细节见 [Technical Design](Documentation/TechnicalDesign.md)。

## 构建与测试

```sh
swift test
./Scripts/build-driver.sh
./Scripts/build-app.sh
```

输出位置：

- App：`DerivedData/Products/SpeakerRouter.app`
- 驱动：`DerivedData/ManualBuild/SpeakerRouterHAL.driver`

`build-app.sh` 会构建通用架构驱动、App 和崩溃守护进程，并对最终 App bundle
执行 ad-hoc 签名。构建过程不会安装 App 或修改系统驱动目录。

## 安装和使用

1. 将 `DerivedData/Products/SpeakerRouter.app` 复制到 `/Applications`。
2. 打开 SpeakerRouter。
3. 在菜单栏面板的“驱动”区域选择“安装驱动”。
4. 通过管理员授权后，等待 Core Audio 服务恢复。
5. 调整设备顺序、选择自动或手动路由，并设置各设备音量。

登录时启动仅会在 App 位于 `/Applications` 后注册。开发目录中的构建不会创建
持久登录项。

## 卸载

先在 App 的驱动区域选择“卸载驱动”，输入管理员密码并等待音频服务恢复，然后
退出并删除 `/Applications/SpeakerRouter.app`。如果启用了登录时启动，请在删除
App 前先关闭该选项。

命令行开发环境也可以运行：

```sh
sudo ./Scripts/uninstall-driver.sh
```

驱动管理脚本只会操作 bundle identifier 为
`com.liubaoyuan.SpeakerRouterHAL` 的目标，避免误删其他 HAL 驱动。

## 数据与隐私

SpeakerRouter 不包含网络请求、遥测或崩溃上报。设备顺序、手动锁定状态和分设备
音量保存在：

```text
~/Library/Application Support/SpeakerRouter/routing-state.json
```

守护进程的心跳文件位于同一目录。共享音频内存使用一次性随机名称，驱动成功映射
后名称立即解除链接。

## 项目结构

- `Sources/SpeakerRouterApp`：菜单栏 UI、驱动管理和路由生命周期。
- `Sources/SpeakerRouterCore`：设备发现、路由状态、音量和 AUHAL 转发。
- `Sources/SpeakerRouterAudioSupport`：实时安全的共享内存环形缓冲。
- `Sources/SpeakerRouterGuard`：异常退出后的物理输出恢复。
- `Driver/SpeakerRouterHAL`：基于 Apple NullAudio 示例的 AudioServerPlugIn。
- `Tests`：路由策略、持久化和共享传输测试。
- `Documentation`：需求、技术设计、状态和故障排查。

## 已知限制

- 当前固定请求 48 kHz；显式的跨设备采样率转换尚未实现。
- 不同硬件时钟之间没有长期漂移校正，长时间运行仍需更多设备验证。
- AirPlay、蓝牙和部分 USB 设备的热插拔行为依赖对应 Core Audio 驱动。
- 公共二进制发布前仍需 Developer ID 签名和 notarization。

遇到无声、驱动状态不一致或菜单栏未出现时，请先查看
[Troubleshooting](Documentation/Troubleshooting.md)。

## 参与贡献

提交修改前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md) 和
[SECURITY.md](SECURITY.md)。路线行为和安全边界记录在
[Requirements](Documentation/Requirements.md) 中。

## 许可证

除特别说明外，项目使用 [MIT License](LICENSE)。
`Driver/SpeakerRouterHAL` 派生自 Apple 的 NullAudio 示例，并保留该目录内的
[LICENSE.txt](Driver/SpeakerRouterHAL/LICENSE.txt)。
