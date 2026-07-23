# 象棋助手

<div align="center">

<h1>XiangqiAssistant</h1>

---

### 看清局势，也看见下一步。

一款运行在 macOS 菜单栏的中国象棋分析工具。选择棋盘窗口，它识别局面、调用本机 Pikafish 分析，并把建议清楚地放回眼前。

**简体中文** · [English](docs/README.en.md) · [日本語](docs/README.ja.md)

Contact: **Jacksun** · [qinji@jack-sun.com](mailto:qinji@jack-sun.com)

`macOS 14+` · `Apple Silicon` · `v1.3.2 · Build 6` · `MIT License`

[下载最新版本](https://github.com/sunqinji666-dotcom/xiangqi-assistant/releases/latest) · [快速开始](#快速开始) · [Star / 收藏](https://github.com/sunqinji666-dotcom/xiangqi-assistant)

</div>

![象棋助手主视觉：本地棋局识别、引擎分析与建议展示](docs/assets/product/banner.png)

<div align="center">

*识别局面，分析变化，把下一步讲清楚。*

</div>

## 先说人话：它到底是什么？

象棋助手不是替你下棋的机器人。它把你明确选择的棋盘窗口变成可分析的局面，再用本机引擎给出候选着法、分数与主线；可选的千问建议会从本地筛出的候选中补充一条实战计划。

![完整三栏界面：分析、棋盘预览与建议](docs/assets/product/overview.png)

## 你实际会用到的

| 本机引擎 | 棋盘识别 | 千问建议 |
|---|---|---|
| ![本机引擎着法、评分与变化](docs/assets/product/analysis.png) | ![棋盘预览与走法箭头](docs/assets/product/board.png) | ![千问建议卡片](docs/assets/product/qwen-review.png) |
| Pikafish 给出候选着法、评分、深度和主要变化。 | 支持自动识别、手动框选、翻转和按格修正。 | 从本机筛出的候选中选一招，补充简短理由与计划。 |

## 快速开始

1. 在 [Releases](https://github.com/sunqinji666-dotcom/xiangqi-assistant/releases/latest) 下载 `XiangqiAssistant-v1.3.2-macOS-arm64.zip`。
2. 解压后将 `象棋助手-TheOne.app` 拖入“应用程序”。
3. 首次打开如被系统拦截，请在 Finder 中右键应用并选择“打开”。
4. 在“系统设置 → 隐私与安全性 → 屏幕录制”允许应用读取窗口。
5. 打开象棋棋盘，点菜单栏图标，刷新窗口列表并选择目标窗口；必要时手动框选棋盘区域。

## 启用千问建议（可选）

本机 Pikafish 分析无需 API Key；只有“千问 AI 复核”和“千问建议”需要你的阿里云百炼 / DashScope API Key。

1. 先启动一次应用后退出。打开 Finder，按 `⌘⇧G`，粘贴下面的目录：

   ```text
   ~/Library/Containers/com.xiangqi.XiangqiAssistant.TheOne/Data/Library/Application Support/象棋助手/ModelCredentials
   ```

2. 如目录不存在，请自行新建 `象棋助手` 和 `ModelCredentials` 两层文件夹。
3. 在该目录新建一个**无扩展名**的纯文本文件，文件名必须是 `qwen-dashscope`。
4. 将 API Key 单独粘贴到文件第一行，保存后重新打开应用即可。

不要把 Key 写进源码、`README`、Issue 或 GitHub。该文件只由本机应用读取；发起你主动点击的千问请求时，棋盘裁图或局面文本会发送到配置的 DashScope 兼容接口。

## 本地、明确、可控

- 截图、识别、FEN、开局库与 Pikafish 搜索都在本机完成。
- 只读取你选择的窗口；不会静默改为全屏捕获。
- 不需要棋类平台账号、Cookie 或云端登录；没有遥测、广告 SDK、云同步或运行时更新检查。
- 公开构建不包含自动落子或鼠标控制。请遵守所用平台的规则。

> 当前安装包仅支持 Apple Silicon、macOS 14+，使用固定本地签名，尚未 Apple Developer ID 公证。

## 从源码运行

```bash
git clone https://github.com/sunqinji666-dotcom/xiangqi-assistant.git
cd xiangqi-assistant
open XiangqiAssistant.xcodeproj
```

如没有本地签名身份，可在 Xcode 选择自己的 Apple Development 身份，或执行无签名构建：

```bash
xcodebuild -project XiangqiAssistant.xcodeproj -scheme XiangqiAssistant \
  -configuration Release -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

`Tests/BrainLogicHarness.swift` 覆盖窗口筛选、棋盘方向、连续帧稳定性、评分视角、推荐稳定性、引擎超时与终局等核心逻辑。

## 下载与许可证

- 最新安装包和 SHA-256 校验文件见 [GitHub Releases](https://github.com/sunqinji666-dotcom/xiangqi-assistant/releases/latest)。
- 原创代码采用 [MIT License](LICENSE)。Pikafish、ONNX Runtime 与 TheOne1006 模型保留各自许可证或使用条款，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
- 欢迎通过 Issue 提交可复现的问题或棋盘兼容信息；请不要上传账号、Cookie、私人截图或其他敏感内容。
