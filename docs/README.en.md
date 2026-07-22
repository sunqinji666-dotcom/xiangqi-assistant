# XiangqiAssistant

![XiangqiAssistant v1.1 concept artwork: local board recognition followed by deep engine analysis](assets/xiangqi-assistant-hero-v2.png)

<div align="center">

### See the position first. Understand the move next.

A quiet macOS menu-bar companion for Chinese-chess study: select a board window, reconstruct the position locally, receive an early candidate move, and let the engine keep verifying it in the background.

[简体中文](../README.md) · **English** · [日本語](README.ja.md)

[Download v1.1.0](https://github.com/sunqinji666-dotcom/xiangqi-assistant/releases/latest) · [One-minute setup](#one-minute-setup) · [How it works](#from-one-frame-to-one-recommendation) · [Star the project](https://github.com/sunqinji666-dotcom/xiangqi-assistant)

</div>

| Stable release | Platform | Runtime model | License | Last verified |
|---|---|---|---|---|
| v1.1.0 · Build 2 | macOS 14+ · Apple Silicon | Menu bar · Local-first | MIT; third-party exceptions | 2026-07-23 |

## A chess game needs clarity, not more noise

Critical positions change in a moment. Manually rebuilding every piece in an analysis board breaks concentration, while a full engine search can make you wait before seeing any direction at all.

XiangqiAssistant turns that gap into a visible local pipeline. You explicitly choose a chess window. The app captures that window, finds the board, reconstructs a trusted FEN position, and hands it to a local Pikafish process. Ultra mode publishes an initial result around the 2-second milestone, deepens an unchanged normal position to about 6 seconds, and may continue to about 15 seconds when the best move churns, the score swings, or a mating line appears.

It is not an automatic player. It behaves more like a quiet analyst beside the board: direction first, stronger evidence next.

## What v1.1.0 changes

### An early answer that remains open to correction

- **Quick milestone:** Ultra mode can publish its first usable result at roughly 2 seconds.
- **Adaptive deepening:** normal positions continue toward 6 seconds; complex positions may use up to 15 seconds.
- **Position isolation:** a result from an old screenshot cannot overwrite a newer position.
- **Stable recommendations:** near-equal moves do not flicker needlessly, while a materially better move or shorter forced mate can still replace the incumbent.

### Opening knowledge must pass engine review

The bundled opening book is offline, read-only, legality-checked, and carries provenance records for its candidates. It never chooses the final move by itself. A book candidate must be legal, appear among Pikafish's verified top candidates, and remain within a narrow safety tolerance before it can be shown.

### Built for real application windows

- Filters system infrastructure such as Dock and Control Center without blanket-blocking Wine, Electron, or iOS-on-Mac chess clients.
- Rebinds a recreated target window by stable identity and never silently falls back to full-screen capture.
- Stores manual calibration relative to the selected window so moving it between displays does not invalidate the crop.
- Canonicalizes opposite board viewpoints and strengthens legality, frame-stability, and recognition diagnostics.

## One-minute setup

1. Download `XiangqiAssistant-v1.1.0-macOS-arm64.zip` from [Releases](https://github.com/sunqinji666-dotcom/xiangqi-assistant/releases/latest).
2. Unzip it and move `象棋助手-TheOne.app` to Applications.
3. If macOS blocks the first launch, right-click the app in Finder and choose **Open**.
4. In **System Settings → Privacy & Security → Screen Recording**, allow the app to read the selected window.
5. Open a standard Xiangqi board, click the menu-bar icon, refresh the window list, and select the target.
6. Confirm the board region. Use manual selection if automatic localization is not reliable for that board skin.

> The current package uses a persistent local signing identity and is not notarized with an Apple Developer ID. macOS may require manual confirmation on first launch.

## From one frame to one recommendation

![Concept workflow: window capture, board recognition, local engine search, and move recommendation](assets/xiangqi-assistant-workflow-v2.png)

> Concept illustration, not an application screenshot.

| Stage | What happens | Reliability boundary |
|---|---|---|
| Select | The user explicitly selects a visible app window | No default whole-screen reading |
| Capture | ScreenCaptureKit reads the target window | No silent full-screen substitution if the target fails |
| Recognize | ONNX models locate the board and classify a 10×9, 16-class layout | Board structure, both kings, and frame stability are checked |
| Canonicalize | View direction is normalized and a side-to-move FEN is generated | A reversed board is not treated as a different game |
| Analyze | Pikafish searches locally over UCI | Every search is tied to a position revision; stale output is discarded |
| Present | Chinese notation, red-perspective evaluation, depth, mate distance, and PV are shown | No-legal-move is a terminal state, not a fake parser failure |

## Three analysis rhythms

| Mode | Search policy | Intended use |
|---|---|---|
| Normal | One main line, about 2 seconds | Quickly confirm the main direction |
| Aggressive | About 3.5 seconds over up to four candidates | Compare more active practical choices without preferring a faster loss |
| Ultra | 2-second answer → 6-second deepening → up to 15 seconds for complex positions | Review, tactics, and mating-line confirmation |

These values are configured search budgets, not a performance guarantee for every machine or position.

## Local-first by design

![Concept illustration: board pixels, recognition, and search remain inside a local processing enclosure](assets/xiangqi-assistant-local-v2.png)

> Concept illustration. The current project has no cloud analysis service.

- Captured frames, recognition, FEN generation, opening data, and Pikafish search remain on the Mac.
- No chess-platform account, Cookie, API key, or cloud login is required.
- The source contains no telemetry, advertising SDK, cloud sync, or runtime update checker.
- Screen Recording permission is controlled by macOS and can be revoked at any time.
- The public build explicitly excludes `UI/AutoPlayManager.swift`; it does not click the board or control the mouse.

## Technical design

| Layer | Implementation |
|---|---|
| Desktop experience | SwiftUI + AppKit `NSPanel` menu-bar application |
| Window capture | Apple ScreenCaptureKit with stable target-window rebinding |
| Board localization | TheOne1006 pose ONNX model |
| Position recognition | TheOne1006 10×9, 16-class layout model |
| Inference runtime | Microsoft ONNX Runtime 1.24.2 |
| Position model | Legality checks, viewpoint canonicalization, FEN, and revision identity |
| Engine | Pikafish as a separate local process over asynchronous UCI |
| Search resilience | Wall-clock timeouts, EOF/process recovery, stop-and-drain cancellation, terminal handling |
| Local knowledge | Provenance-carrying, legality-checked opening book with engine verification |
| Target | Apple Silicon arm64 |
| Bundle ID | `com.xiangqi.XiangqiAssistant.TheOne` |

### Supported today

- User-selected window capture, refresh, and continuous observation;
- automatic board localization plus window-relative manual calibration across displays;
- canonicalization of normal and opposite board viewpoints;
- stability protection, FEN generation, and position history;
- Normal, Aggressive, and Ultra local analysis modes;
- Chinese notation, red-perspective score, depth, mate distance, and principal variation;
- automatic engine recovery and clean no-legal-move terminal handling.

### Not promised today

- Native Intel Mac support;
- perfect recognition for every skin, scale, animation, obstruction, or variant;
- Apple Developer ID signing and notarization;
- automatic move execution, mouse control, or bypassing third-party platform rules;
- universal opening-book coverage or book authority over independent engine review.

Use the project for learning, review, UI-recognition research, and offline analysis, and follow the rules of any platform you use.

## Build from source

Requirements: macOS 14+, Xcode 15+, Apple Silicon.

```bash
git clone https://github.com/sunqinji666-dotcom/xiangqi-assistant.git
cd xiangqi-assistant
open XiangqiAssistant.xcodeproj
```

Select the `XiangqiAssistant` scheme in Xcode. If the persistent local signing identity is unavailable on your Mac, choose your own Apple Development identity or build unsigned:

```bash
xcodebuild \
  -project XiangqiAssistant.xcodeproj \
  -scheme XiangqiAssistant \
  -configuration Release \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

`Tests/BrainLogicHarness.swift` exercises window filtering, viewpoint canonicalization, score and mate perspective, recommendation stability, opening-book legality, terminal engine states, wall-clock timeout, cancellation, and search replacement. It is a focused logic harness, not a complete UI automation suite.

## Repository map

```text
Sources/XiangqiAssistant/
├── App/            # Lifecycle, menu bar, recognition and analysis coordination
├── Capture/        # Window policy, capture, rebinding, selection and geometry
├── Recognition/    # ONNX models, calibration, orientation and stability
├── Engine/         # Pikafish UCI, adaptive search, opening book and move policy
├── UI/             # Floating panel, board preview and status presentation
└── Resources/      # Engine, NNUE, ONNX models and offline opening data
```

## Download and verify

Release packages and checksums are published on [GitHub Releases](https://github.com/sunqinji666-dotcom/xiangqi-assistant/releases/latest).

```bash
shasum -a 256 -c XiangqiAssistant-v1.1.0-macOS-arm64.zip.sha256
```

Do not run a package if its filename, size, or digest differs from the Release page.

## Licensing and contribution

Original source code is MIT-licensed. Pikafish, ONNX Runtime, and TheOne1006 model files retain their own licenses or terms. Pikafish redistribution and modification remain subject to GPLv3. See [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) before redistributing a build.

Reproducible issues and compatibility reports are welcome. Never post accounts, Cookies, private screenshots, or other secrets in a public Issue.

**Jacksun** · [qinji@jack-sun.com](mailto:qinji@jack-sun.com)

If the project helps you understand a position, consider [starring the repository](https://github.com/sunqinji666-dotcom/xiangqi-assistant).
