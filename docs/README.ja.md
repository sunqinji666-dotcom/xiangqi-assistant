# 象棋アシスタント · XiangqiAssistant

![象棋アシスタント：macOS 向けローカル象棋認識・解析ツール](assets/product/banner.png)

<div align="center">

### 局面を見て、次の一手を読む。

中国象棋の盤面ウィンドウを選択し、局面を認識して Mac 上の Pikafish で解析するメニューバーアプリです。任意の Qwen 提案も表示前にローカルで検証します。

[简体中文](../README.md) · [English](README.en.md) · **日本語**

[v1.3.1 をダウンロード](https://github.com/sunqinji666-dotcom/xiangqi-assistant/releases/latest) · [使い始める](#クイックスタート) · [Star](https://github.com/sunqinji666-dotcom/xiangqi-assistant)

</div>

| 現行版 | 対応環境 | ライセンス |
|---|---|---|
| v1.3.1 · Build 5 | macOS 14+ · Apple Silicon | MIT（第三者コンポーネントを除く） |

## できること

![着手解析・盤面プレビュー・独立提案の三画面](assets/product/overview.png)

- ユーザーが明示的に選んだ盤面ウィンドウだけを読み取り、盤面と局面を認識します。
- ローカルの Pikafish が候補手、評価、深さ、主要変化を解析します。
- Normal、Aggressive、Ultra の三つの解析テンポ。局面が変わらなければ探索を継続します。
- 手動の盤面選択、駒の修正、盤面反転、クライアントごとの調整保存に対応します。
- 任意の Qwen 提案は独立して案を出し、別のローカル Pikafish が合法性と明白な戦術リスクを確認します。

## 一つの盤面、二つの視点

| ローカルエンジン解析 | Qwen の独立提案 |
|---|---|
| ![Pikafish の着手・評価・変化表示](assets/product/analysis.png) | ![盤面下に表示されるローカル検証済み Qwen 提案](assets/product/qwen-review.png) |
| Pikafish が主変化と評価を示します。 | 緑のエンジン推奨を先に渡さず、最大3案をローカルで検証します。 |

![認識状態、矢印、手動修正を備えた盤面プレビュー](assets/product/board.png)

## クイックスタート

1. [Releases](https://github.com/sunqinji666-dotcom/xiangqi-assistant/releases/latest) から `XiangqiAssistant-v1.3.1-macOS-arm64.zip` をダウンロードします。
2. 解凍し、`象棋助手-TheOne.app` を「アプリケーション」に移動します。
3. 初回起動を macOS が止めた場合は、Finder で右クリックして「開く」を選びます。
4. 「システム設定 → プライバシーとセキュリティ → 画面収録」で許可します。
5. 象棋盤面を開き、メニューバーアイコンからウィンドウを選択します。必要なら手動選択を使います。

> 配布版は Apple Silicon 向けで、固定ローカル署名を使用しています。Apple Developer ID による公証は未実施です。Qwen を使うには、自分の API Key をアプリサンドボックスの `Application Support/象棋助手/ModelCredentials/qwen-dashscope` に保存します。資格情報はリポジトリにも配布物にも含まれません。

## ローカルで、明確に、制御可能に

- キャプチャ、盤面認識、FEN、定跡、Pikafish の探索は Mac 上で処理します。
- 象棋サイトのアカウント、Cookie、クラウドログイン、テレメトリ、広告 SDK、クラウド同期、実行時更新確認は不要です。
- 全画面キャプチャへ黙って切り替えることはありません。
- 公開ビルドに自動着手やマウス操作はありません。利用するプラットフォームの規則を守ってください。

## ソースからビルド

macOS 14+、Xcode 15+、Apple Silicon が必要です。

```bash
git clone https://github.com/sunqinji666-dotcom/xiangqi-assistant.git
cd xiangqi-assistant
open XiangqiAssistant.xcodeproj
```

ローカルの署名 ID がない場合は Xcode で自分の Apple Development ID を選ぶか、無署名でビルドします。

```bash
xcodebuild -project XiangqiAssistant.xcodeproj -scheme XiangqiAssistant \
  -configuration Release -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

`Tests/BrainLogicHarness.swift` はウィンドウ選別、盤面方向、フレーム安定性、評価の視点、推薦安定性、エンジンのタイムアウトと終局を検証します。完全な UI テストではありません。

## ダウンロードとライセンス

- 配布パッケージと SHA-256: [GitHub Releases](https://github.com/sunqinji666-dotcom/xiangqi-assistant/releases/latest)。
- オリジナルコード: [MIT License](../LICENSE)。Pikafish、ONNX Runtime、TheOne1006 モデルはそれぞれの条件を保持します。詳細は [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)。
- 再現可能な問題・互換性情報は Issue へ。アカウント、Cookie、私的なスクリーンショット、秘密情報は投稿しないでください。

[Jacksun](https://github.com/sunqinji666-dotcom) · [qinji@jack-sun.com](mailto:qinji@jack-sun.com)
