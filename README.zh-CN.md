# PaperDrop

[English](README.md) | [日本語](README.ja.md) | **简体中文**

一款 macOS 应用：只需拖放，即可把任意图像显示在通过 USB 连接的 **M5Stack Paper DIY**（兼容 M5PaperS3）电子纸上。

- 将图像拖到窗口（或程序坞图标）上 → 自动查找设备并发送 → 约 3 秒后显示
- 支持 JPEG / PNG / HEIC / TIFF / GIF 等所有 ImageIO 格式，也可以直接从浏览器拖入图像
- 960×540（横向）/ 540×960（纵向），16 级灰度 + Floyd–Steinberg 抖动。预览即为电子纸上的实际效果
- 最后发送的图像会保存到设备的 Flash 中，重启后自动恢复
- 界面支持英语 / 日语 / 简体中文（跟随 macOS 语言设置；也可在“系统设置 → 通用 → 语言与地区 → 应用程序”中单独设置）

设计与协议（日语）：[docs/DESIGN.md](docs/DESIGN.md)

## 1. 烧录固件（仅首次）

需要 `arduino-cli`、`m5stack:esp32` 内核，以及 `M5Unified` / `M5GFX` 库（支持 PaperDIY：M5GFX ≥ 0.2.33）。

```bash
arduino-cli compile -b m5stack:esp32:m5stack_papers3 --output-dir build/fw firmware/PaperDropReceiver
```

```bash
arduino-cli upload -b m5stack:esp32:m5stack_papers3 -p /dev/cu.usbmodem11401 --input-dir build/fw firmware/PaperDropReceiver
```

开发板使用默认选项（OPI PSRAM / 16MB / HW CDC / `app3M_fat9M_16MB`）即可。烧录完成后，屏幕上会显示“PaperDrop”。

## 2. 构建 Mac 应用

```bash
mac/scripts/build_app.sh
```

会生成 `mac/build/PaperDrop.app`，可复制到 `/Applications` 使用（ad-hoc 签名）。

## 使用方法

| 操作 | 说明 |
|---|---|
| 拖入 | 转换后立即发送（关闭“拖入即发送”时，使用“发送”按钮 / ⌘↩） |
| 方向 | 自动（按图像宽高比）/ 横向 / 纵向 |
| 布局 | 填满（居中裁剪）/ 适应（留白为白色） |
| 旋转 180° | 设备倒置摆放时使用 |
| 清屏 | 将屏幕清为白色，并删除已保存的图像 |

## 命令行工具（自动化与验证）

```bash
mac/.build/release/paperdrop-cli send testdata/testchart.png --verify 200
```

`ping` / `send <file> [--portrait|--landscape] [--fit] [--no-dither] [--rotate180] [--verify N] [--preview out.png] [--trace]` / `clear` / `pix x y`。通用选项 `--port /dev/cu.xxx`。`--verify N` 在显示后从设备帧缓冲区读回 N 个像素并与发送的数据比对；`--trace` 带时间戳打印从设备收到的每一行。设备和图像相关的错误信息跟随 macOS 语言。

应用运行时会独占串口，使用命令行工具前请先退出应用。

## 性能（实机测量，2026-11-07）

从开始发送到显示完成（`SHOWN`）约 2.6 秒（传输 1.1 秒 + 刷新 1.5 秒）。之后设备还需约 2.6 秒将图像保存到 Flash。

## 测试

```bash
cd mac && swift test
```

## 恢复出厂固件

写回烧录前备份的 16MB 完整镜像（`backup/`，不在 git 中）。

```bash
esptool --port /dev/cu.usbmodem11401 -b 921600 write-flash 0 backup/factory_PaperDIY_V1.0_full16MB.bin
```

## 许可证

[MIT](LICENSE)
