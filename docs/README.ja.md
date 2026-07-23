# 象棋アシスタント

<div align="center">

<h1>XiangqiAssistant</h1>

---

### 局面を見て、次の一手を読む。

中国象棋の盤面ウィンドウを選択し、局面を認識して Mac 上の Pikafish で解析するメニューバーアプリです。使える結果を、常に目の前に残します。

[简体中文](../README.md) · [English](README.en.md) · **日本語**

Contact: **Jacksun** · [qinji@jack-sun.com](mailto:qinji@jack-sun.com)

`macOS 14+` · `Apple Silicon` · `v1.3.2 · Build 6` · `MIT License`

[最新版をダウンロード](https://github.com/sunqinji666-dotcom/xiangqi-assistant/releases/latest) · [使い始める](#クイックスタート) · [Star](https://github.com/sunqinji666-dotcom/xiangqi-assistant)

</div>

![象棋アシスタント：ローカル盤面認識、エンジン解析、着手提案](assets/product/banner.png)

<div align="center">

*局面を認識し、変化を読み、次の一手を伝える。*

</div>

## ひとことで言うと

象棋アシスタントは自動で指すソフトではありません。明示的に選んだ盤面ウィンドウを解析可能な局面に変換し、ローカルエンジンで候補手・評価・主変化を示します。任意の Qwen 提案はローカルで選別した候補から一手を選び、実戦的な計画を補足します。

![解析、盤面プレビュー、提案の三画面](assets/product/overview.png)

## 使う機能

| ローカルエンジン | 盤面認識 | Qwen 提案 |
|---|---|---|
| ![Pikafish の着手・評価・変化表示](assets/product/analysis.png) | ![盤面プレビューと矢印](assets/product/board.png) | ![Qwen 提案カード](assets/product/qwen-review.png) |
| Pikafish が候補手、評価、深さ、主変化を示します。 | 自動認識、手動選択、盤面反転、各マスの修正に対応します。 | ローカル候補から一手を選び、短い理由と計画を補足します。 |

## クイックスタート

1. [Releases](https://github.com/sunqinji666-dotcom/xiangqi-assistant/releases/latest) から `XiangqiAssistant-v1.3.2-macOS-arm64.zip` をダウンロードします。
2. 解凍し、`象棋助手-TheOne.app` を「アプリケーション」に移動します。
3. 初回起動を macOS が止めた場合は、Finder で右クリックして「開く」を選びます。
4. 「システム設定 → プライバシーとセキュリティ → 画面収録」で許可します。
5. 象棋盤面を開き、メニューバーアイコンからウィンドウを選択します。必要なら手動選択を使います。

## Qwen 提案を有効にする（任意）

ローカル Pikafish の解析には API Key は不要です。**Qwen AI 復核**と**Qwen 提案**にだけ、自分の Alibaba Cloud Bailian / DashScope API Key が必要です。

1. アプリを一度起動してから終了します。Finder で `⌘⇧G` を押し、次の場所を入力します。

   ```text
   ~/Library/Containers/com.xiangqi.XiangqiAssistant.TheOne/Data/Library/Application Support/象棋助手/ModelCredentials
   ```

2. 存在しない場合は、`象棋助手` と `ModelCredentials` のフォルダを作成します。
3. その中に、拡張子なしで名前を正確に `qwen-dashscope` としたプレーンテキストファイルを作成します。
4. API Key だけを1行目に貼り付けて保存し、アプリを再起動します。

Key をソースコード、README、Issue、GitHub に書き込まないでください。このファイルを読むのはローカルアプリだけです。Qwen の機能を明示的に実行したときだけ、盤面の切り抜き画像または局面テキストが設定済みの DashScope 互換エンドポイントに送られます。

## ローカルで、明確に、制御可能に

- キャプチャ、盤面認識、FEN、定跡、Pikafish の探索は Mac 上で処理します。
- 選んだウィンドウだけを読み取り、全画面キャプチャへ黙って切り替えることはありません。
- 象棋サイトのアカウント、Cookie、クラウドログイン、テレメトリ、広告 SDK、クラウド同期、実行時更新確認は不要です。
- 公開ビルドに自動着手やマウス操作はありません。利用するプラットフォームの規則を守ってください。

> 配布版は Apple Silicon 向け、macOS 14+ 対応です。固定ローカル署名を使用し、Apple Developer ID による公証は未実施です。

## ソースからビルド

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

`Tests/BrainLogicHarness.swift` はウィンドウ選別、盤面方向、フレーム安定性、評価の視点、推薦安定性、エンジンのタイムアウトと終局を検証します。

## ダウンロードとライセンス

- 配布パッケージと SHA-256: [GitHub Releases](https://github.com/sunqinji666-dotcom/xiangqi-assistant/releases/latest)。
- オリジナルコード: [MIT License](../LICENSE)。Pikafish、ONNX Runtime、TheOne1006 モデルはそれぞれの条件を保持します。詳細は [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)。
- 再現可能な問題・互換性情報は Issue へ。アカウント、Cookie、私的なスクリーンショット、秘密情報は投稿しないでください。
