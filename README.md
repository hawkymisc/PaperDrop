# PaperDrop

**English** | [日本語](README.ja.md) | [简体中文](README.zh-CN.md)

A macOS app that shows any image on a USB-connected **M5Stack Paper DIY** (M5PaperS3 compatible) e-paper display — just drag and drop.

- Drop an image on the window (or the Dock icon) → the device is found and the image sent automatically → shown in about 3 seconds
- JPEG / PNG / HEIC / TIFF / GIF and any other ImageIO format. Images dragged from a browser work too
- 960×540 (landscape) / 540×960 (portrait), 16 gray levels with Floyd–Steinberg dithering. The preview is exactly what the panel shows
- The last image is saved to the device's flash and restored after a reboot
- UI in English / Japanese / Simplified Chinese (follows the macOS language; can be set per app in System Settings → General → Language & Region → Applications)

Design and protocol (Japanese): [docs/DESIGN.md](docs/DESIGN.md)

## 1. Flash the firmware (first time only)

Requires `arduino-cli` with the `m5stack:esp32` core and the `M5Unified` / `M5GFX` libraries (PaperDIY support: M5GFX ≥ 0.2.33).

```bash
arduino-cli compile -b m5stack:esp32:m5stack_papers3 --output-dir build/fw firmware/PaperDropReceiver
```

```bash
arduino-cli upload -b m5stack:esp32:m5stack_papers3 -p /dev/cu.usbmodem11401 --input-dir build/fw firmware/PaperDropReceiver
```

The board's default options (OPI PSRAM / 16MB / HW CDC / `app3M_fat9M_16MB`) are fine. After flashing, the screen shows "PaperDrop".

## 2. Build the Mac app

```bash
mac/scripts/build_app.sh
```

This produces `mac/build/PaperDrop.app`. You can copy it to `/Applications` (ad-hoc signed).

## Usage

| Control | What it does |
|---|---|
| Drop | Converts and sends immediately (with "Send on drop" off, use the Send button / ⌘↩) |
| Orientation | Auto (from the image's aspect ratio) / Landscape / Portrait |
| Layout | Fill (center crop) / Fit (white margins) |
| Rotate 180° | For a device placed upside down |
| Clear | Blanks the screen and deletes the saved image |

## CLI (automation and verification)

```bash
mac/.build/release/paperdrop-cli send testdata/testchart.png --verify 200
```

`ping` / `send <file> [--portrait|--landscape] [--fit] [--no-dither] [--rotate180] [--verify N] [--preview out.png] [--trace]` / `clear` / `pix x y`. Common option: `--port /dev/cu.xxx`. `--verify N` reads N pixels back from the device's frame buffer after display and compares them with what was sent; `--trace` prints every line received from the device with a timestamp. Device and image error messages follow the macOS language.

While the app is running it holds the port exclusively, so quit the app before using the CLI.

## Performance (measured on the device, 2026-11-07)

Send start → displayed (`SHOWN`) in about 2.6 s (1.1 s transfer + 1.5 s refresh). The device then spends about 2.6 s saving to flash.

## Tests

```bash
cd mac && swift test
```

## Restoring the factory firmware

Write back the full 16MB backup taken before flashing (`backup/`, not in git).

```bash
esptool --port /dev/cu.usbmodem11401 -b 921600 write-flash 0 backup/factory_PaperDIY_V1.0_full16MB.bin
```

## License

[MIT](LICENSE)
