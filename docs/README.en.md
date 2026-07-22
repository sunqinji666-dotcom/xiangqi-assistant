# XiangqiAssistant

![Concept visual showing the path from a captured Xiangqi board to a local engine suggestion](assets/xiangqi-assistant-hero-v1.png)

> When a game turns and you cannot tell which move changed the position, XiangqiAssistant stays quietly in the macOS menu bar, reads the board window you select, recognizes the position locally, and asks Pikafish for moves worth studying.

[简体中文](../README.md) · **English** · [日本語](README.ja.md)

Current release: **v1.0.0 (Build 1)** · **macOS 14+ / Apple Silicon** · **MIT, excluding third-party components**

[Download](https://github.com/sunqinji666-dotcom/xiangqi-assistant/releases/latest) · [Quick start](#quick-start) · [Star the project](https://github.com/sunqinji666-dotcom/xiangqi-assistant)

## What it is

XiangqiAssistant is a local macOS menu-bar utility. It captures only the window selected by the user through ScreenCaptureKit, locates and recognizes a Chinese-chess board with ONNX models, converts the position to FEN, and sends it to a local Pikafish engine.

The public build is designed for study, review, and opening research. It observes and recommends; it does not click the board or play moves for the user.

## Why it is useful

- Read a position from the screen instead of entering every piece manually.
- Keep screenshots, recognition, and engine analysis on the Mac.
- Open a compact floating panel from the menu bar.
- Inspect recognition state, candidate moves, evaluation, depth, and principal variation.
- Calibrate for a board skin and refuse to present unstable recognition as certainty.

## Quick start

1. Download `XiangqiAssistant-v1.0.0-macOS-arm64.zip` from [Releases](https://github.com/sunqinji666-dotcom/xiangqi-assistant/releases/latest).
2. Unzip it and move `象棋助手-TheOne.app` to Applications.
3. If macOS reports an unidentified source, Control-click the app in Finder and choose Open.
4. Allow Screen Recording in System Settings → Privacy & Security.
5. Open a Xiangqi board, select its window from the menu-bar app, and start analysis.

The current package has a stable local signature but is not notarized with Apple Developer ID, so first launch may require manual confirmation.

## Technical pipeline

```text
Selected window → ScreenCaptureKit → TheOne1006 ONNX recognition
→ legality and temporal-stability checks → FEN → local Pikafish
→ move, evaluation, depth, and principal variation
```

The application uses SwiftUI and AppKit, Microsoft ONNX Runtime 1.24.2, two local recognition models, and an arm64 Pikafish process communicating through UCI. The bundle identifier is `com.xiangqi.XiangqiAssistant.TheOne`.

## Scope and limits

The release supports window capture, automatic or manual board localization, calibration, FEN generation, multi-candidate engine analysis, Chinese notation, and stability checks. It is currently Apple-Silicon-only, not notarized, and cannot guarantee recognition across every board skin, scale, or animation.

Use it for learning, review, and offline research, and follow the rules of any platform you use.

## Privacy

Recognition and engine analysis run locally. The project contains no account login, cloud sync, telemetry, or advertising SDK. macOS controls screen-capture permission and lets the user revoke it at any time. The release target excludes the automatic-control module.

## Build from source

```bash
git clone https://github.com/sunqinji666-dotcom/xiangqi-assistant.git
cd xiangqi-assistant
open XiangqiAssistant.xcodeproj
```

Requirements: macOS 14+, Xcode 15+, and Apple Silicon. See the Chinese README for the unsigned command-line build and package structure.

## Download verification

```bash
shasum -a 256 -c XiangqiAssistant-v1.0.0-macOS-arm64.zip.sha256
```

Third-party components retain their own licenses. See [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md). Contact: [qinji@jack-sun.com](mailto:qinji@jack-sun.com).
