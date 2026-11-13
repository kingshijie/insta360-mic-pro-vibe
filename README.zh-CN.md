# Vibe Mic Pro

[English](README.md) · **简体中文**

<img src="assets/MicPro.png" alt="Vibe Mic Pro 图标" width="96">

**把 Insta360 Mic Pro 的电源键变成豆包输入法的听写键。短按一次开始，再按一次结束，说话时不用一直按住键盘。**

这个独立开发的 macOS 菜单栏 App 将发射器的电源键映射为右 Option（右 ⌥），触发豆包的「免按模式」。说话时可以松开按钮。Mic Pro 关机或断开后，豆包跟随系统切回 Mac 内置麦克风或你选中的其他输入设备。

[下载 macOS App](https://github.com/kingshijie/insta360-mic-pro-vibe/releases/latest) · [查看安装步骤](#安装) · [中文发布说明](docs/releases.zh-CN.md)

## 准备

- macOS 13 或更新版本，已在 Apple 芯片的 MacBook Pro（macOS 14.7.8）上实测。其他机型和系统版本尚未验证。
- Insta360 Mic Pro 发射器，通过 Mac 蓝牙直接配对。配对列表里显示为 `Insta360 Mic Pro TX …`。
- [豆包输入法 macOS 版](https://ime.doubao.com/pc) 和 [BlackHole 2ch](https://existential.audio/blackhole/)。BlackHole 安装后若提示重启，按安装器提示操作。

## 安装

1. 从 [GitHub Releases](https://github.com/kingshijie/insta360-mic-pro-vibe/releases/latest) 的 Assets 下载 **`MicPro-Doubao-macOS-universal.zip`**。解压后，把 **Mic Pro 听写.app** 拖进「应用程序」并打开。安装包同时支持 Apple 芯片和 Intel Mac，无需编译。
2. 如果 macOS 提示无法验证开发者，先关闭提示，再打开「系统设置 → 隐私与安全性」，针对 **Mic Pro 听写** 选择「仍要打开」。此版本未经过 Apple 公证。[Apple 首次打开说明](https://support.apple.com/zh-cn/102445)
3. 在「系统设置 → 隐私与安全性 → 辅助功能」开启 **Mic Pro 听写**。如果列表里没有，用 **+** 添加刚才解压的 App。如果 macOS 提示蓝牙权限，允许后再连接发射器。
4. 打开「豆包输入法设置 → 语音输入」，将 **免按模式** 设为 **右 Option（右 ⌥）**，将 **麦克风选择** 设为 **自动检测**。如需在其他输入法下触发，在同一页启用「全局唤起语音」。

### 从源码构建

1. 在终端运行 `xcode-select --install`，安装 Xcode 命令行工具。已安装可跳过。
2. 下载源码、构建并打开 App。首次构建需要联网下载指定版本的 liblc3。

   ```sh
   git clone https://github.com/kingshijie/insta360-mic-pro-vibe.git
   cd insta360-mic-pro-vibe
   ./build.zsh
   open "$HOME/Applications/Mic Pro 听写.app"
   ```

3. 按上面的安装步骤配置辅助功能和豆包输入法。

## 使用

| 状态 | 豆包使用的音频 | 操作 |
| --- | --- | --- |
| 菜单显示「已就绪」 | Mic Pro，经 BlackHole 2ch | 光标放进文本框，短按电源键开始，再短按结束 |
| Mic Pro 关机、断开或桥接暂停 | Mac 内置麦克风，或当前选中的其他麦克风 | 使用豆包自己的语音快捷键，例如按住右 ⌘ |

第一次打开 App 后默认随 macOS 登录启动，可在菜单栏「设置…」中关闭。菜单也能查看当前输入、暂停听写和重新连接。

从源码构建后，可在「设置…」开启「结束听写后双击电源键发送 Return」。这个选项默认关闭。在同一个 App 里单击开始、再单击结束，等文字落到输入框后，在结束听写后的 20 秒内双击电源键。双击也会切换麦克风降噪。只有配置为回车发送的输入框才会提交消息。

BlackHole 是虚拟音频设备。App 将收到的 Mic Pro 音频解码后送进 BlackHole，豆包从系统默认输入读取。App 会在收到有效音频后切换输入，断开时恢复。这个切换对其他跟随系统输入的 App 也生效。

## 排障

| 现象 | 怎么处理 |
| --- | --- |
| 找不到菜单栏图标 | 确认已从「应用程序」打开 **Mic Pro 听写**。如果 MacBook 的刘海两侧菜单已满，先收起几个菜单栏项目，再找白色圆形的像素笑脸图标。图标变淡表示麦克风尚未就绪。 |
| 菜单一直未就绪 | 检查蓝牙配对、BlackHole 2ch 和辅助功能授权，点「重新检查并连接」。如果已连接但一直等不到音频，先退出其他正在使用 Mic Pro 的 App，再重启发射器。 |
| 按键有反应，但豆包没出字 | 先在文本框手动点按右 ⌥，检查豆包能否进入免按模式。确认麦克风选「自动检测」。就绪时应显示 BlackHole 2ch，断开后应显示内置麦克风或当前选中的其他设备。 |
| 更新后辅助功能开着，电源键却失效 | App 使用临时签名。移除辅助功能列表里的旧条目，重新添加新版 App，退出并重新打开。 |
| 收音设备没有切回 | 在菜单里退出 App 以恢复内置输入。如果 App 曾被强制结束，可在「系统设置 → 声音 → 输入」手动选回内置麦克风。 |

升级时，先从菜单退出旧版，再下载新版并替换 App。从源码安装的用户也可以运行 `git pull` 和 `./build.zsh`。只想编译检查，可以运行 `./build.zsh --build-only`，产物会留在项目的 `build/` 目录。

卸载时，先在菜单「设置…」里关闭登录启动，再退出 App，将 **Mic Pro 听写.app** 移到废纸篓。BlackHole 可能也被其他 App 使用，可按官网说明单独管理。

## 实现与许可证

`panel.m` 管理菜单、自动连接和系统输入切换。`bridge.m` 通过蓝牙 RFCOMM 通道 12 读取发射器按键和音频，将电源键映射为右 ⌥。`serial-audio.m` 将 48 kHz 单声道 LC3plus 解码后通过 Core Audio 送给 BlackHole。桥接 App 在本机处理音频，听写由豆包输入法完成。

本仓库的项目代码、文档和卡通图标采用 [MIT 许可证](LICENSE)。App 随附 [liblc3 1.1.3（Apache 2.0）](https://github.com/google/liblc3/blob/v1.1.3/LICENSE) 及其许可证。BlackHole 单独安装，适用其 [GPL-3.0 许可证](https://github.com/ExistentialAudio/BlackHole/blob/master/LICENSE)。
