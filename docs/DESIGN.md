# PaperDrop 設計

macOS の画像をドラッグ&ドロップするだけで、USB 接続した M5Stack Paper DIY（M5PaperDIY）の e-paper に表示させる。

## 対象ハードウェア（2026-11-07 実機で確認）

| 項目 | 値 | 確認方法 |
|---|---|---|
| SoC | ESP32-S3 (QFN56) rev v0.2, PSRAM 8MB (OPI), Flash 16MB | `esptool flash-id` |
| USB | 内蔵 USB-Serial/JTAG（`/dev/cu.usbmodem*`, VID 0x303A） | `ioreg` |
| ボード判定 | M5GFX `board_M5PaperDIY`（M5PM1 PMIC で識別） | 工場ファームのブートログ |
| 表示 | 540x960（ネイティブ縦）, 16 階調 | 同上 |
| 工場ファーム | `PaperDIY` V1.0（Mooncake, ESP-IDF v5.5.1） | 同上。`backup/` に 16MB 全体バックアップ |

## 構成

```
mac/        Swift Package
  PaperKit         画像変換・プロトコル・シリアル（UI 非依存、テスト対象）
  PaperDrop        SwiftUI アプリ（.app にバンドル）
  paperdrop-cli    ヘッドレス送信 CLI（E2E 検証・自動化用）
firmware/PaperDropReceiver/   Arduino スケッチ（M5Unified/M5GFX）
```

## 画像パイプライン（Mac 側）

1. ImageIO で読み込み（EXIF 回転を反映）。JPEG/PNG/HEIC/TIFF/GIF/WebP 等 ImageIO 対応形式すべて。
2. 向き決定: `auto`（画像の縦横比に合わせる）/ `landscape` 960x540 / `portrait` 540x960。
3. 配置: `fill`（中央クロップで全面）/ `fit`（余白は白）。
4. 8bit グレースケールへ描画 → 16 階調へ量子化（Floyd–Steinberg 誤差拡散、OFF 可）。
5. 4bpp パック（1 byte = 2 px、**上位ニブルが左の画素**、0=黒 … 15=白）。
6. プレビューは量子化後の画素から生成（=実機で見える絵）。

## シリアルプロトコル v1

USB CDC（ボーレートは無意味だが 115200 を設定）。コマンドは ASCII 1 行（`\n` 終端）、応答も 1 行。デバイスのログ行は `#` で始まり、ホストは無視する。

| ホスト → | デバイス → | 説明 |
|---|---|---|
| `PING` | `PONG PaperDrop 1 <W>x<H> up=<ms>` | 疎通・ネイティブ解像度（横長換算 960x540） |
| `IMG <w> <h> <len> <crc32hex>` | `READY` / `ERR <reason>` | 画像ヘッダ。`len == ceil(w/2)*h`、w×h は 960x540 か 540x960 |
| （生データ 4096B ずつ） | チャンク毎に `ACK <受信累計>` | ホストは ACK を待って次を送る（取りこぼし防止のフロー制御） |
| （全量受信後） | `OK` → 描画後 `SHOWN <ms>` / `ERR crc <実CRC>` | CRC32(IEEE) 検証 → 表示 → `SHOWN`（`<ms>` は描画時間）→ FFat `/image.pd` に保存（`# saved in <ms>`）。保存中に届いた次コマンドは RX バッファで待つため、ホストは `READY` を最大 15 秒待つ |
| `CLEAR` | `SHOWN <ms>` / `ERR remove` | 白で全面クリア（保存画像と未確定 tmp も削除） |
| `PIX <x> <y>` | `PIX <level>` | 表示中フレームバッファ内の画素値（0–15）。E2E 検証用 |

- 受信途中で 3 秒データが途絶えたら `ERR timeout <受信済>` で中断し、入力が 300ms 静かになるまで読み捨ててから待機状態へ戻る。
- ホストは転送を中断した後、次の探索時に PING が 2 回応答しなければ 3.4 秒沈黙して出力を読み捨て（resync）、再度 PING する。PING 応答待ちでは古い `ERR` 行を無視する。
- 128 文字を超える行は `ERR toolong`。保存は tmp に書いてから置き換え、起動時に孤立 tmp を回収する。
- ホストは VID 0x303A（Espressif）または VID 不明のポートのみ探索する（他社 Arduino 等を開いてリセットさせないため）。
- ホストは送信前の生存確認 PING を最大 15 秒待つ（直前画像の保存中でも誤って切断扱いにしない）。
- 起動時、保存画像があれば再描画する（リセット・電池交換後も復元）。

## 受入基準

1. Finder から画像をアプリ窓（または Dock アイコン）へドロップすると、自動でデバイスを見つけて送信し、M5Paper に表示される。
2. 送信中は進捗が出る。デバイス未接続・CRC 不一致などは画面にエラー理由を表示する。
3. 再起動後も最後の画像が表示される。
4. `PIX` で読み戻した画素値が送信データと一致する（E2E 自動検証）。

## 検証結果（2026-11-07 実機）

- ポートを開いても ESP32-S3 はリセットされない（連続 `PING` で `up=` が単調増加）。
- 転送 259,200B: READY→OK 約 1.13 秒、描画（quality）約 1.45–1.5 秒、送信開始→`SHOWN` 約 4.2 秒（保存込みの旧仕様時）。
- **想定外 1**: Panel_EPD は 8bit 灰色を `(v + Bayer - 8) >> 4`（Bayer 0–15）で 4bit 化する独自ディザを持つ。パレット `L*17` だと Mac 側ディザに二重ディザがかかり ±1 ずれた（`PIX` 照合 266/300）。パレットを `16L+8` にして素通しにし、照合 500/500 一致。
- **想定外 2**: 書き込み直後 2 回目の送信で 100% 到達後に応答タイムアウトが 1 回発生（以後 6 回連続で再現せず、デバイスはリセットなし）。初回の上書き保存（FFat の消去）が遅かったと推定し、`SHOWN` を保存前に返す設計に変更。

## 既知の未知数（検証前）

- macOS でポートを開くときの DTR/RTS 変化で ESP32-S3 がリセットされないか → `PONG` の `up=` で確認する。
- HWCDC の RX バッファ溢れ → ACK 方式で回避する想定。
- LGFX の 4bit パレット転送のニブル順 → `PIX` 読み戻しで確認する。
- e-paper 全面更新時間（quality モード）→ `SHOWN <ms>` で計測。

## 不採用案

- **Wi-Fi / HTTP 経由**: 設定（SSID 入力）が増え「USB 接続済み」という前提に対し過剰。
- **SD カード / USB マスストレージ経由**: PaperDIY の SD 有無が不明、MSC 化は TinyUSB 切替が必要で書き込み経路も変わるため不採用。
- **デバイス側で JPEG/PNG デコード**: 変換・ディザを Mac 側で行えばプレビューと実表示が一致し、ファームも単純になる。
- **Electron / Python GUI**: 配布物が重い。SwiftUI ならドラッグ&ドロップ・ImageIO がネイティブで揃う。
