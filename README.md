# 象棋助手 · XiangqiAssistant

![象棋助手主视觉：从棋盘画面到本地引擎建议的概念示意](docs/assets/xiangqi-assistant-hero-v1.png)

> 当你在复盘一盘棋，却说不清局势从哪一步开始改变，象棋助手会安静地待在 macOS 菜单栏里：读取你选择的棋盘画面，在本地识别局面，再由 Pikafish 给出值得思考的候选着法。

**简体中文** · [English](docs/README.en.md) · [日本語](docs/README.ja.md)

当前版本：**v1.0.0（Build 1）** · 平台：**macOS 14+ / Apple Silicon** · 许可证：**MIT（第三方组件除外）**

[下载最新版本](https://github.com/sunqinji666-dotcom/xiangqi-assistant/releases/latest) · [一分钟上手](#一分钟上手) · [收藏项目](https://github.com/sunqinji666-dotcom/xiangqi-assistant)

## 它是什么

象棋助手是一款本地运行的 macOS 菜单栏工具。它通过 ScreenCaptureKit 读取用户明确选择的窗口，用 ONNX 模型定位和识别中国象棋棋盘，再把局面转换为 FEN，交给本机 Pikafish 引擎分析。

它的目标是帮助复盘、研究开局与理解局势。当前公开构建只负责观察和建议，不会替用户点击棋盘，也不会自动走棋。

## 为什么值得用

- **不必手抄局面**：直接从屏幕画面中读取棋盘。
- **分析留在本机**：识别模型和棋力引擎随应用运行，不上传棋盘截图。
- **菜单栏常驻**：需要时展开浮窗，不占据 Dock。
- **局面证据可见**：展示识别状态、候选着法、评分、深度和主要变化。
- **可校准、可复核**：首次使用可针对当前棋盘皮肤校准，识别不稳定时不会把结果伪装成确定答案。

## 一分钟上手

1. 前往 [Releases](https://github.com/sunqinji666-dotcom/xiangqi-assistant/releases/latest) 下载 `XiangqiAssistant-v1.0.0-macOS-arm64.zip`。
2. 解压后，把 `象棋助手-TheOne.app` 拖入“应用程序”。
3. 首次打开若 macOS 提示来源未验证，请在 Finder 中右键应用并选择“打开”。
4. 在“系统设置 → 隐私与安全性 → 屏幕录制”中允许象棋助手读取屏幕。
5. 打开一个标准中国象棋棋盘，点击菜单栏图标，选择目标窗口并开始分析。

> 当前下载包使用固定本地签名，尚未使用 Apple Developer ID 公证。macOS 可能要求用户手动确认首次打开。

## 工作原理

```text
用户选择棋盘窗口
        ↓
ScreenCaptureKit 捕获画面
        ↓
TheOne1006 ONNX 模型定位并识别 10×9 棋盘
        ↓
局面合法性与连续帧稳定性检查
        ↓
生成 FEN → Pikafish 本地分析
        ↓
浮窗显示候选着法、评分、深度与变化线
```

识别结果必须先通过棋盘结构、双将存在和连续帧变化检查。系统无法确认局面时会显示不稳定状态，而不是直接输出看似精确的建议。

## 专业实现

| 层级 | 实现 |
|---|---|
| 桌面体验 | SwiftUI + AppKit `NSPanel` 菜单栏应用 |
| 屏幕捕获 | Apple ScreenCaptureKit |
| 棋盘定位 | TheOne1006 pose ONNX 模型 |
| 局面识别 | TheOne1006 10×9、16 类布局模型 |
| 模型运行时 | Microsoft ONNX Runtime 1.24.2 |
| 棋力分析 | Pikafish，通过 UCI 协议异步通信 |
| 目标架构 | Apple Silicon arm64 |
| Bundle ID | `com.xiangqi.XiangqiAssistant.TheOne` |

## 功能与边界

当前版本支持：

- 选择并持续观察目标窗口；
- 自动定位棋盘，必要时手动框选；
- 初始局面校准与棋盘皮肤适配；
- FEN 生成、Pikafish 多候选分析；
- 中文着法、分数、搜索深度和变化线显示；
- 局面历史与识别稳定性保护。

当前版本不承诺：

- Intel Mac 原生支持；
- 对所有棋盘皮肤、缩放比例和动画遮挡都能准确识别；
- Apple Developer ID 公证；
- 替用户落子或控制鼠标。

请将它用于学习、复盘和离线研究，并遵守所使用平台的规则。

## 隐私与安全

- 画面捕获由 macOS 权限系统管理；用户可以随时撤销权限。
- 棋盘识别、FEN 生成和引擎分析均在本机完成。
- 项目不包含账号登录、云端同步、遥测或广告 SDK。
- 当前 Xcode target 明确排除自动控制模块，发布版不会点击棋盘。

## 从源码构建

要求：macOS 14+、Xcode 15+、Apple Silicon。

```bash
git clone https://github.com/sunqinji666-dotcom/xiangqi-assistant.git
cd xiangqi-assistant
open XiangqiAssistant.xcodeproj
```

在 Xcode 选择 `XiangqiAssistant` scheme 后构建。若本机没有项目使用的固定签名身份，可把 Signing 改为自己的 Apple Development 身份，或使用命令行无签名构建：

```bash
xcodebuild \
  -project XiangqiAssistant.xcodeproj \
  -scheme XiangqiAssistant \
  -configuration Release \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

## 项目结构

```text
Sources/XiangqiAssistant/
├── App/            # 生命周期、菜单栏和分析循环
├── Capture/        # 窗口捕获、棋盘框选和几何换算
├── Recognition/    # ONNX 识别、模板校准和局面稳定性
├── Engine/         # Pikafish UCI、着法与记谱转换
├── UI/             # 浮窗、棋盘预览和状态展示
└── Resources/      # 本地模型与引擎运行文件
```

## 下载与校验

正式下载包和 SHA-256 文件位于 [GitHub Releases](https://github.com/sunqinji666-dotcom/xiangqi-assistant/releases/latest)。

```bash
shasum -a 256 -c XiangqiAssistant-v1.0.0-macOS-arm64.zip.sha256
```

## 第三方组件

Pikafish、ONNX Runtime 与模型文件拥有各自许可证或使用条款，不因本项目采用 MIT 许可证而改变。详情见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 联系与贡献

问题和改进建议请提交 GitHub Issue。联系邮箱：[qinji@jack-sun.com](mailto:qinji@jack-sun.com)。

如果这个项目对你的复盘有帮助，欢迎收藏仓库并分享真实棋盘皮肤的兼容情况。
