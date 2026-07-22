# 象棋助手 · XiangqiAssistant

![画面上の中国象棋盤からローカルエンジンの候補手までを示すコンセプト画像](assets/xiangqi-assistant-hero-v1.png)

> 対局を振り返るとき、どの一手から形勢が変わったのか分からないことがあります。XiangqiAssistant は macOS のメニューバーに常駐し、ユーザーが選択した盤面ウィンドウを読み取り、局面をローカルで認識して、Pikafish に検討すべき候補手を問い合わせます。

[简体中文](../README.md) · [English](README.en.md) · **日本語**

現行版：**v1.0.0（Build 1）** · **macOS 14+ / Apple Silicon** · **MIT（第三者コンポーネントを除く）**

[最新版をダウンロード](https://github.com/sunqinji666-dotcom/xiangqi-assistant/releases/latest) · [クイックスタート](#クイックスタート) · [リポジトリを保存](https://github.com/sunqinji666-dotcom/xiangqi-assistant)

## このアプリについて

XiangqiAssistant はローカル動作の macOS メニューバーツールです。ScreenCaptureKit でユーザーが明示的に選んだウィンドウだけを取得し、ONNX モデルで中国象棋の盤面を検出・認識します。局面は FEN に変換され、Mac 上の Pikafish エンジンで解析されます。

公開ビルドは学習、棋譜検討、定跡研究を目的としています。盤面を観察して候補手を示しますが、クリックや自動着手は行いません。

## 主な価値

- 盤面を一駒ずつ入力せず、画面から読み取れます。
- スクリーンショット、認識、エンジン解析は Mac 内で完結します。
- メニューバーから小さなフローティングパネルを開けます。
- 認識状態、候補手、評価値、探索深度、主要変化を確認できます。
- 不安定な認識結果を確定情報のように表示しません。

## クイックスタート

1. [Releases](https://github.com/sunqinji666-dotcom/xiangqi-assistant/releases/latest) から `XiangqiAssistant-v1.0.0-macOS-arm64.zip` をダウンロードします。
2. 展開後、`象棋助手-TheOne.app` を「アプリケーション」へ移動します。
3. 未確認の開発元として警告された場合は、Finder で Control キーを押しながらアプリをクリックし、「開く」を選びます。
4. 「システム設定 → プライバシーとセキュリティ → 画面収録」で許可します。
5. 中国象棋の盤面を開き、メニューバーから対象ウィンドウを選択して解析を開始します。

現在の配布物は固定ローカル署名ですが、Apple Developer ID による公証は未実施です。

## 技術構成

```text
選択ウィンドウ → ScreenCaptureKit → TheOne1006 ONNX 認識
→ 局面合法性・連続フレーム安定性検査 → FEN → ローカル Pikafish
→ 候補手・評価値・深度・主要変化を表示
```

SwiftUI / AppKit、Microsoft ONNX Runtime 1.24.2、ローカル認識モデル、arm64 版 Pikafish を使用します。Bundle ID は `com.xiangqi.XiangqiAssistant.TheOne` です。

## 対応範囲と制限

ウィンドウ取得、自動・手動の盤面指定、校正、FEN 生成、複数候補解析、中国語棋譜表記、安定性検査に対応します。現時点では Apple Silicon 専用で、未公証です。すべての盤面スキン、倍率、アニメーションへの対応は保証しません。

学習、棋譜検討、オフライン研究に使用し、利用先の規約を守ってください。

## プライバシー

認識と解析はローカルで実行されます。アカウントログイン、クラウド同期、テレメトリ、広告 SDK はありません。画面収録権限は macOS からいつでも取り消せます。配布 target では自動操作モジュールを除外しています。

## ソースからビルド

```bash
git clone https://github.com/sunqinji666-dotcom/xiangqi-assistant.git
cd xiangqi-assistant
open XiangqiAssistant.xcodeproj
```

必要環境は macOS 14+、Xcode 15+、Apple Silicon です。詳細なビルド方法は中国語 README を参照してください。

## ダウンロード検証

```bash
shasum -a 256 -c XiangqiAssistant-v1.0.0-macOS-arm64.zip.sha256
```

第三者コンポーネントにはそれぞれのライセンスが適用されます。[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) を参照してください。連絡先：[qinji@jack-sun.com](mailto:qinji@jack-sun.com)。
