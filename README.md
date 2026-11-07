# PaperDrop

Mac から画像をドラッグ&ドロップするだけで、USB 接続した **M5Stack Paper DIY**（M5PaperS3 互換）の e-paper に表示する macOS アプリ。

- 画像を窓（または Dock アイコン）にドロップ → 自動でデバイスを検出して送信 → 約 3 秒で表示
- JPEG / PNG / HEIC / TIFF / GIF など ImageIO 対応形式。ブラウザからの画像ドラッグも可
- 960×540（横）/ 540×960（縦）、16 階調 + Floyd–Steinberg ディザ。プレビュー＝実機の見え方
- 最後に送った画像はデバイスの Flash に保存され、再起動後も復元

設計・プロトコル: [docs/DESIGN.md](docs/DESIGN.md)

## 1. ファームウェアを書き込む（初回のみ）

必要: `arduino-cli` + `m5stack:esp32` コア、ライブラリ `M5Unified` / `M5GFX`（PaperDIY 対応版: M5GFX ≥ 0.2.33）。

```bash
arduino-cli compile -b m5stack:esp32:m5stack_papers3 --output-dir build/fw firmware/PaperDropReceiver
```

```bash
arduino-cli upload -b m5stack:esp32:m5stack_papers3 -p /dev/cu.usbmodem11401 --input-dir build/fw firmware/PaperDropReceiver
```

ボードの既定オプション（OPI PSRAM / 16MB / HW CDC / `app3M_fat9M_16MB`）のままで OK。書き込み後、画面に「PaperDrop」と表示されます。

## 2. Mac アプリをビルドする

```bash
mac/scripts/build_app.sh
```

`mac/build/PaperDrop.app` ができます。`/Applications` にコピーして使えます（ad-hoc 署名）。

## 使い方

| 操作 | 内容 |
|---|---|
| ドロップ | 変換して即送信（「ドロップで即送信」OFF なら送信ボタン / ⌘↩） |
| 向き | 自動（画像の縦横比）/ 横 / 縦 |
| 配置 | 全面（中央クロップ）/ 全体（余白は白） |
| 180°回転 | デバイスを逆さに置くとき |
| クリア | 画面を白にし、保存画像も削除 |

## CLI（自動化・検証用）

```bash
mac/.build/release/paperdrop-cli send testdata/testchart.png --verify 200
```

`ping` / `send <file> [--portrait|--landscape] [--fit] [--no-dither] [--rotate180] [--verify N] [--preview out.png] [--trace]` / `clear` / `pix x y`。共通オプション `--port /dev/cu.xxx`。`--verify N` は表示後のフレームバッファから N 画素を読み戻して送信データと照合、`--trace` はデバイスからの受信行を時刻付きで表示します。

アプリ起動中はアプリがポートを排他的に開いているため、CLI を使うときはアプリを終了してください。

## 性能（実機 2026-11-07）

送信開始 → 表示完了（`SHOWN`）約 2.6 秒（転送 1.1 秒 + 描画 1.5 秒）。その後デバイスが約 2.6 秒かけて Flash に保存します。

## テスト

```bash
cd mac && swift test
```

## 工場ファームへ戻す

書き込み前に取得した 16MB 全体バックアップ（`backup/`、git 管理外）を書き戻します。

```bash
esptool --port /dev/cu.usbmodem11401 -b 921600 write-flash 0 backup/factory_PaperDIY_V1.0_full16MB.bin
```
