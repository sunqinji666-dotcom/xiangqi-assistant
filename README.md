# 象棋助手 · XiangqiAssistant

![象棋助手：macOS 本地棋局识别与分析工具](docs/assets/product/banner.png)

<div align="center">

### 看清局势，也看见下一步。

macOS 菜单栏里的中国象棋分析工具：选择棋盘窗口，识别局面，由本机 Pikafish 给出着法；可选的千问建议会再经过本地验证。

**简体中文** · [English](docs/README.en.md) · [日本語](docs/README.ja.md)

[下载 v1.3.1](https://github.com/sunqinji666-dotcom/xiangqi-assistant/releases/latest) · [快速开始](#快速开始) · [Star / 收藏](https://github.com/sunqinji666-dotcom/xiangqi-assistant)

</div>

| 当前版本 | 支持平台 | 许可证 |
|---|---|---|
| v1.3.1 · Build 5 | macOS 14+ · Apple Silicon | MIT（第三方组件除外） |

## 它做什么

![完整的三栏工作界面：着法分析、棋盘预览和独立建议](docs/assets/product/overview.png)

- 读取你**明确选择**的棋盘窗口，自动识别棋盘和局面。
- 本机 Pikafish 分析候选着法、分数、深度与主要变化。
- 支持普通、主动、超强三种分析节奏；局面不变时会继续深化。
- 可手动框选、修正棋子、翻转棋盘，并为不同棋类客户端记住校准区域。
- 可选千问独立建议：先提出方案，再由另一条本地 Pikafish 流程检查合法性和明显战术风险。

## 两条思路，同时摆在棋盘上

| 本机引擎分析 | 千问独立建议 |
|---|---|
| ![本机引擎的着法、评分与变化展示](docs/assets/product/analysis.png) | ![千问建议经过本地验证后显示在棋盘下方](docs/assets/product/qwen-review.png) |
| 用 Pikafish 给出主线和评分。 | 不预先读取绿色引擎推荐；最多给出三套思路，再本地复核。 |

![棋盘预览支持识别状态、走法箭头和手动修正](docs/assets/product/board.png)

## 快速开始

1. 在 [Releases](https://github.com/sunqinji666-dotcom/xiangqi-assistant/releases/latest) 下载 `XiangqiAssistant-v1.3.1-macOS-arm64.zip`。
2. 解压后将 `象棋助手-TheOne.app` 拖入“应用程序”。
3. 首次打开若被系统拦截，请在 Finder 中右键应用并选择“打开”。
4. 在“系统设置 → 隐私与安全性 → 屏幕录制”允许该应用读取窗口。
5. 打开象棋棋盘，点菜单栏图标，刷新窗口列表并选择目标窗口；必要时手动框选棋盘区域。

> 目前下载包为 Apple Silicon 版本，使用固定本地签名，尚未 Apple Developer ID 公证。千问功能需要你自行配置 API Key；凭证仅保存在应用沙盒的 `Application Support/象棋助手/ModelCredentials/qwen-dashscope`，不包含在源码或安装包中。

## 本地、明确、可控

- 截图、棋盘识别、FEN、开局库与 Pikafish 搜索均在本机完成。
- 不需要棋类平台账号、Cookie 或云端登录；项目没有遥测、广告 SDK、云同步或运行时更新检查。
- 只读取你选择的窗口；不会静默回退为全屏捕获。
- 公开构建不包含自动落子或鼠标控制功能。请遵守所使用平台的规则。

## 从源码运行

要求：macOS 14+、Xcode 15+、Apple Silicon。

```bash
git clone https://github.com/sunqinji666-dotcom/xiangqi-assistant.git
cd xiangqi-assistant
open XiangqiAssistant.xcodeproj
```

如果没有项目所用的本地签名身份，可在 Xcode 选择自己的 Apple Development 身份，或无签名构建：

```bash
xcodebuild -project XiangqiAssistant.xcodeproj -scheme XiangqiAssistant \
  -configuration Release -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

仓库中的 `Tests/BrainLogicHarness.swift` 覆盖窗口筛选、棋盘方向、连续帧稳定性、评分视角、推荐稳定性、引擎超时与终局等核心逻辑；它不是完整 UI 自动化测试。

## 下载与许可证

- 最新安装包与 SHA-256 校验文件见 [GitHub Releases](https://github.com/sunqinji666-dotcom/xiangqi-assistant/releases/latest)。
- 原创代码采用 [MIT License](LICENSE)。Pikafish、ONNX Runtime 与 TheOne1006 模型保留各自许可证或使用条款，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
- 问题反馈与兼容性信息欢迎通过 Issue 提交；不要公开账号、Cookie、私人截图或其他敏感内容。

[Jacksun](https://github.com/sunqinji666-dotcom) · [qinji@jack-sun.com](mailto:qinji@jack-sun.com)
