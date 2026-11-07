// PaperDrop receiver for M5Stack Paper DIY / M5PaperS3
// Receives 16-level grayscale images (4bpp packed) over USB CDC and shows them
// on the e-paper. The last image is stored in FFat and redrawn on boot.
// Protocol: see docs/DESIGN.md ("シリアルプロトコル v1").

#include <M5Unified.h>
#include <FFat.h>

static constexpr const char* kProtoName = "PaperDrop";
static constexpr int kProtoVersion = 1;
static constexpr int kLongSide = 960;
static constexpr int kShortSide = 540;
static constexpr size_t kChunk = 4096;
static constexpr uint32_t kRxTimeoutMs = 3000;
static constexpr const char* kImagePath = "/image.pd";
static constexpr const char* kTmpPath = "/image.tmp";
static constexpr uint32_t kFileMagic = 0x31445050;  // "PPD1" little-endian

static bool g_fs_ok = false;
static lgfx::rgb888_t g_palette[16];

// ---- CRC32 (IEEE 802.3, same as zlib) -------------------------------------
static uint32_t g_crc_table[256];
static void crc32_init() {
  for (uint32_t i = 0; i < 256; ++i) {
    uint32_t c = i;
    for (int k = 0; k < 8; ++k) c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
    g_crc_table[i] = c;
  }
}
static uint32_t crc32_calc(const uint8_t* p, size_t n) {
  uint32_t c = 0xFFFFFFFFu;
  for (size_t i = 0; i < n; ++i) c = g_crc_table[(c ^ p[i]) & 0xFF] ^ (c >> 8);
  return c ^ 0xFFFFFFFFu;
}

// ---- helpers ---------------------------------------------------------------
static void logline(const String& s) { Serial.print("# "); Serial.println(s); }

static size_t packed_len(int w, int h) { return (size_t)((w + 1) / 2) * (size_t)h; }

static bool valid_size(int w, int h) {
  return (w == kLongSide && h == kShortSide) || (w == kShortSide && h == kLongSide);
}

// Rotation such that Display.width() == w.
static void set_rotation_for(int w, int h) {
  for (int r = 0; r < 4; ++r) {
    M5.Display.setRotation(r);
    if (M5.Display.width() == w && M5.Display.height() == h) return;
  }
}

static uint32_t show_image(int w, int h, const uint8_t* data) {
  uint32_t t0 = millis();
  set_rotation_for(w, h);
  M5.Display.setEpdMode(epd_mode_t::epd_quality);
  M5.Display.startWrite();
  M5.Display.pushImage(0, 0, w, h, data, lgfx::color_depth_t::palette_4bit, g_palette);
  M5.Display.endWrite();
  M5.Display.display();
  M5.Display.waitDisplay();
  return millis() - t0;
}

static void show_idle_screen() {
  set_rotation_for(kLongSide, kShortSide);
  M5.Display.setEpdMode(epd_mode_t::epd_quality);
  M5.Display.fillScreen(TFT_WHITE);
  M5.Display.setTextColor(TFT_BLACK, TFT_WHITE);
  M5.Display.setTextDatum(middle_center);
  M5.Display.setFont(&fonts::FreeSansBold24pt7b);
  M5.Display.drawString("PaperDrop", kLongSide / 2, kShortSide / 2 - 30);
  M5.Display.setFont(&fonts::FreeSans12pt7b);
  M5.Display.drawString("Drop an image on the Mac app", kLongSide / 2, kShortSide / 2 + 30);
  M5.Display.display();
  M5.Display.waitDisplay();
}

static bool save_image(int w, int h, uint32_t crc, const uint8_t* data, size_t len) {
  if (!g_fs_ok) return false;
  File f = FFat.open(kTmpPath, FILE_WRITE);
  if (!f) { logline("save: open failed"); return false; }
  uint32_t hdr[4] = { kFileMagic, ((uint32_t)w << 16) | (uint32_t)h, (uint32_t)len, crc };
  bool ok = f.write((const uint8_t*)hdr, sizeof(hdr)) == sizeof(hdr) && f.write(data, len) == len;
  f.close();
  if (!ok) { logline("save: write failed"); FFat.remove(kTmpPath); return false; }
  // FAT rename cannot overwrite. A crash between remove and rename leaves only the
  // complete tmp file, which recover_tmp() promotes on the next boot.
  if (FFat.exists(kImagePath) && !FFat.remove(kImagePath)) { logline("save: remove old failed"); return false; }
  if (!FFat.rename(kTmpPath, kImagePath)) { logline("save: rename failed"); return false; }
  return true;
}

static void recover_tmp() {
  if (!g_fs_ok || !FFat.exists(kTmpPath)) return;
  if (FFat.exists(kImagePath)) {
    // tmp is an interrupted write; the previous image is still intact
    if (!FFat.remove(kTmpPath)) logline("recover: cannot remove stale tmp");
  } else if (!FFat.rename(kTmpPath, kImagePath)) {
    logline("recover: rename failed");
  } else {
    logline("recover: promoted tmp image");
  }
}

static bool load_and_show_saved() {
  if (!g_fs_ok || !FFat.exists(kImagePath)) return false;
  File f = FFat.open(kImagePath, FILE_READ);
  if (!f) { logline("load: open failed"); return false; }
  uint32_t hdr[4];
  if (f.read((uint8_t*)hdr, sizeof(hdr)) != sizeof(hdr) || hdr[0] != kFileMagic) {
    logline("load: bad header"); f.close(); return false;
  }
  int w = hdr[1] >> 16, h = hdr[1] & 0xFFFF;
  size_t len = hdr[2];
  if (!valid_size(w, h) || len != packed_len(w, h)) { logline("load: bad size"); f.close(); return false; }
  uint8_t* buf = (uint8_t*)ps_malloc(len);
  if (!buf) { logline("load: no memory"); f.close(); return false; }
  bool ok = f.read(buf, len) == len;
  f.close();
  if (!ok) {
    logline("load: short read");
  } else if (crc32_calc(buf, len) != hdr[3]) {
    logline("load: crc mismatch");
    ok = false;
  } else {
    uint32_t ms = show_image(w, h, buf);
    logline(String("restored saved image in ") + ms + "ms");
  }
  free(buf);
  return ok;
}

// Discards input until the host has been silent for `quiet_ms`, so the rest of an
// aborted image body is not parsed as commands.
static void drain_input(uint32_t quiet_ms) {
  uint32_t last = millis();
  while (millis() - last < quiet_ms) {
    if (Serial.available()) {
      while (Serial.available()) Serial.read();
      last = millis();
    }
    delay(5);
  }
}

// ---- command handlers ------------------------------------------------------
static void cmd_img(int w, int h, size_t len, uint32_t crc) {
  if (!valid_size(w, h)) { Serial.println("ERR size"); return; }
  if (len != packed_len(w, h)) { Serial.println("ERR length"); return; }
  uint8_t* buf = (uint8_t*)ps_malloc(len);
  if (!buf) { Serial.println("ERR memory"); return; }
  Serial.println("READY");

  size_t got = 0;
  while (got < len) {
    size_t want = min(kChunk, len - got);
    size_t n = Serial.readBytes(buf + got, want);
    got += n;
    if (n < want) {
      Serial.printf("ERR timeout %u\n", (unsigned)got);
      free(buf);
      drain_input(300);
      return;
    }
    Serial.printf("ACK %u\n", (unsigned)got);
  }

  uint32_t actual = crc32_calc(buf, len);
  if (actual != crc) {
    Serial.printf("ERR crc %08x\n", (unsigned)actual);
    free(buf);
    return;
  }
  Serial.println("OK");
  uint32_t ms = show_image(w, h, buf);
  // Report success as soon as the panel shows it; persisting can take seconds
  // (flash erase) and the host buffers its next command meanwhile.
  Serial.printf("SHOWN %u\n", (unsigned)ms);
  uint32_t t0 = millis();
  if (save_image(w, h, crc, buf, len)) logline(String("saved in ") + (millis() - t0) + "ms");
  else logline("image not persisted");
  free(buf);
}

static void cmd_clear() {
  uint32_t t0 = millis();
  // also drop a pending tmp, or recover_tmp() would bring the image back on reboot
  for (const char* path : { kImagePath, kTmpPath }) {
    if (g_fs_ok && FFat.exists(path) && !FFat.remove(path)) {
      Serial.println("ERR remove");
      return;
    }
  }
  M5.Display.setEpdMode(epd_mode_t::epd_quality);
  M5.Display.fillScreen(TFT_WHITE);
  M5.Display.display();
  M5.Display.waitDisplay();
  Serial.printf("SHOWN %u\n", (unsigned)(millis() - t0));
}

static void cmd_pix(int x, int y) {
  if (x < 0 || y < 0 || x >= M5.Display.width() || y >= M5.Display.height()) {
    Serial.println("ERR range");
    return;
  }
  auto c = M5.Display.readPixelRGB(x, y);
  int gray = (c.R8() + c.G8() + c.B8()) / 3;
  Serial.printf("PIX %d\n", (gray + 8) / 17);
}

static void handle_line(String line) {
  line.trim();
  if (line.isEmpty()) return;
  int w, h; unsigned len; unsigned crc;
  if (line == "PING") {
    Serial.printf("PONG %s %d %dx%d up=%u\n", kProtoName, kProtoVersion, kLongSide, kShortSide, (unsigned)millis());
  } else if (sscanf(line.c_str(), "IMG %d %d %u %x", &w, &h, &len, &crc) == 4) {
    cmd_img(w, h, len, crc);
  } else if (line == "CLEAR") {
    cmd_clear();
  } else if (sscanf(line.c_str(), "PIX %d %d", &w, &h) == 2) {
    cmd_pix(w, h);
  } else {
    Serial.println("ERR unknown");
  }
}

// ---- Arduino entry points --------------------------------------------------
void setup() {
  Serial.setRxBufferSize(kChunk * 4);
  Serial.begin(115200);
  Serial.setTimeout(kRxTimeoutMs);

  auto cfg = M5.config();
  M5.begin(cfg);
  crc32_init();
  // Panel_EPD quantizes 8-bit gray with its own 4x4 Bayer dither: level = (v + b - 8) >> 4, b in 0..15.
  // v = 16*L + 8 is the only value that maps to exactly L for every b, so host-side levels pass through.
  for (int i = 0; i < 16; ++i) g_palette[i] = lgfx::rgb888_t(i * 16 + 8, i * 16 + 8, i * 16 + 8);

  g_fs_ok = FFat.begin(true);
  if (!g_fs_ok) logline("FFat mount failed; images will not persist");

  recover_tmp();
  if (!load_and_show_saved()) show_idle_screen();
  logline(String("ready, board=") + (int)M5.getBoard() + " display=" + M5.Display.width() + "x" + M5.Display.height());
}

void loop() {
  static String line;
  static bool overflow = false;
  while (Serial.available()) {
    char ch = (char)Serial.read();
    if (ch == '\n') {
      if (overflow) Serial.println("ERR toolong"); else handle_line(line);
      line = "";
      overflow = false;
    } else if (ch != '\r') {
      if (line.length() < 128) line += ch; else overflow = true;
    }
  }
  delay(2);
}
