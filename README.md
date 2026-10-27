# LAN Bridge

在局域网内使用同一副键盘和鼠标控制多台 Windows / macOS 电脑。

> **版权与许可：Copyright © 2026 Idealawliet。禁止未经书面授权的商业使用。**
> 本项目采用[非商业使用许可](LICENSE)，允许遵守许可条件的非商业学习、研究、修改与分发；企业内部生产、办公、商业集成、销售及收费服务等用途须先取得书面授权。第三方依赖遵循各自许可证。本项目为源码可见项目，不采用 OSI 开源许可证。

## 下载与安装

从 [GitHub Releases](https://github.com/Idealawliet/lan_bridge/releases) 下载 Windows EXE 安装器或 macOS DMG，也可选择便携 ZIP。发行包附有 SHA-256 文件，当前为未签名预览版。macOS 需要授予辅助功能、输入监控与本地网络权限。

## 当前功能

- 主界面直接启动服务端（提供键鼠）或客户端（接受控制），支持局域网自动发现及手动 IP 连接。
- 服务端可申请控制、解除连接；客户端可申请加入、同意或拒绝控制、主动离开。
- 6 位 PIN 配对，双向认证及 AES-256-GCM 加密；两端软件版本必须一致。
- 一台服务端管理最多 16 台客户端；支持四向跨屏、错位排列和连接期间拖动屏幕布局。
- 键盘、鼠标、侧键、滚轮与跨分辨率坐标映射，非当前设备隐藏光标。
- 双向文本、图片和原始文件剪贴板；文件传输保留文件名、目录结构和原始字节。
- 跨屏文件拖放：保持左键按住，将文件移至屏幕接缝，等待传输就绪后在另一端目标目录松开。传输采用复制，源文件不删除；原拖拽动画取消不代表文件已丢失。
- GitHub 官方发行检查、下载进度、取消与 SHA-256 校验；版本管理可选择升级、降级或重装。没有更新入口的旧版需手动安装新版才能恢复版本管理。
- 登录自启、后台托盘、连接信号和紧急恢复；断线释放模拟输入。

## 使用流程

1. 键鼠所在电脑启动服务端，其他电脑启动客户端。
2. 从设备列表申请控制或加入，核对客户端 PIN 完成配对。
3. 在服务端排列屏幕，移动指针越过相接边缘切换控制。
4. 文件拖拽期间保持按住左键，等待就绪后再松开。也可使用文件传输面板或复制文件后在对端粘贴。
5. “返回本机”保留连接；“解除控制”或“离开服务端”断开单台设备；“停止服务”关闭所有连接。

紧急返回：Windows 使用 **Ctrl + Alt + Esc**，macOS 使用 **Control + Option + Esc**。

## 软件截图

截图由实际 Flutter 界面渲染，设备与版本列表为演示数据。

![主界面](docs/images/home.png)
![服务端与屏幕布局](docs/images/server.png)
![版本管理](docs/images/versions.png)

## 使用限制

仅映射各电脑主屏幕；更改缩放、主屏幕或分辨率后请重新连接。文件传输不支持符号链接与特殊文件。跨屏拖放涉及 Finder / Explorer、系统权限和驱动，需要真实设备验收；自动化测试不代表实际鼠标帧率或双机拖放已验证。网络隔离或防火墙可能阻止发现，需允许 TCP 24872 与 UDP 24873。

## 开发与构建

使用 Flutter 3.47.7，执行 `flutter pub get --enforce-lockfile`、`flutter analyze` 和 `flutter test`。

Windows 使用 `scripts/build-windows.ps1`（需要 Visual Studio C++ 和 Inno Setup 6）；macOS 使用 `scripts/build-macos.sh`（需要 Xcode 和 CocoaPods）。推送与 pubspec 对应的版本标签后，GitHub Actions 自动验证、打包并发布安装包。

原生桥接位于 `packages/lan_input/`，核心逻辑位于 `lib/core/`，共享功能位于 `lib/sharing/`。实机验收参考 [检查清单](docs/manual-test.md)。

## 商业授权

商业使用请通过[项目 Issues](https://github.com/Idealawliet/lan_bridge/issues) 联系版权所有者，说明使用主体、用途、部署范围和分发方式，并在取得书面授权后使用。仓库公开、下载或 Fork 不代表获得商用授权。完整条款见 [LICENSE](LICENSE)。
