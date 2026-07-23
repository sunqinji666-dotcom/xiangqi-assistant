# XiangqiAssistant

<div align="center">

<h1>XiangqiAssistant</h1>

---

### See the position. See the next move.

A macOS menu-bar tool for Chinese-chess analysis. Choose a board window; it reconstructs the position, runs local Pikafish analysis, and keeps the useful result in view.

[简体中文](../README.md) · **English** · [日本語](README.ja.md)

Contact: **Jacksun** · [qinji@jack-sun.com](mailto:qinji@jack-sun.com)

`macOS 14+` · `Apple Silicon` · `v1.3.2 · Build 6` · `MIT License`

[Download latest](https://github.com/sunqinji666-dotcom/xiangqi-assistant/releases/latest) · [Quick start](#quick-start) · [Star the project](https://github.com/sunqinji666-dotcom/xiangqi-assistant)

</div>

![XiangqiAssistant hero: local board recognition, engine analysis, and move advice](assets/product/banner.png)

<div align="center">

*Recognize the position, analyse the line, explain the next move.*

</div>

## In plain words

XiangqiAssistant is not an automatic player. It turns the board window you explicitly choose into an analysable position, then uses a local engine for candidate moves, evaluation, and principal variation. Optional Qwen advice selects from locally screened candidates and adds a practical plan.

![Three-pane workspace: analysis, board preview, and advice](assets/product/overview.png)

## What you use

| Local engine | Board recognition | Qwen advice |
|---|---|---|
| ![Local engine move, score, and continuation](assets/product/analysis.png) | ![Board preview and move arrows](assets/product/board.png) | ![Qwen advice card](assets/product/qwen-review.png) |
| Pikafish provides candidates, evaluation, depth, and principal variation. | Automatic recognition, manual selection, orientation flip, and per-square correction. | Chooses a locally screened move and adds a concise rationale and plan. |

## Quick start

1. Download `XiangqiAssistant-v1.3.2-macOS-arm64.zip` from [Releases](https://github.com/sunqinji666-dotcom/xiangqi-assistant/releases/latest).
2. Unzip it and move `象棋助手-TheOne.app` to Applications.
3. If macOS blocks the first launch, right-click the app in Finder and choose **Open**.
4. Allow Screen Recording in **System Settings → Privacy & Security**.
5. Open a Xiangqi board, click the menu-bar icon, refresh the window list, and choose the target. Use manual board selection when needed.

## Local and deliberate

- Captures, recognition, FEN generation, opening data, and Pikafish search run locally.
- The app reads only the window you choose and never silently falls back to full-screen capture.
- No chess-platform account, Cookie, cloud login, telemetry, ad SDK, cloud sync, or runtime update check is required.
- The public build has no automatic move or mouse-control behavior. Follow the rules of the platform you use.

> The package supports Apple Silicon on macOS 14+ and uses a persistent local signature; it is not Apple Developer ID notarized. Qwen requires your own API key, stored only in the app sandbox at `Application Support/象棋助手/ModelCredentials/qwen-dashscope`.

## Build from source

```bash
git clone https://github.com/sunqinji666-dotcom/xiangqi-assistant.git
cd xiangqi-assistant
open XiangqiAssistant.xcodeproj
```

Choose your own Apple Development identity in Xcode if the local identity is unavailable, or build unsigned:

```bash
xcodebuild -project XiangqiAssistant.xcodeproj -scheme XiangqiAssistant \
  -configuration Release -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

`Tests/BrainLogicHarness.swift` covers core logic including window filtering, orientation, frame stability, score perspective, recommendation stability, engine timeout, and terminal positions.

## Download and license

- Packages and SHA-256 files: [GitHub Releases](https://github.com/sunqinji666-dotcom/xiangqi-assistant/releases/latest).
- Original code: [MIT License](../LICENSE). Pikafish, ONNX Runtime, and TheOne1006 models retain their own terms; see [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).
- File reproducible issues or compatibility reports through Issues. Do not post accounts, Cookies, private screenshots, or secrets.
