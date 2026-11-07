// Renders a simple app icon (e-paper tablet with a picture) to an .icns file.
// usage: swift make_icon.swift <out.icns>
import AppKit

let out = CommandLine.arguments[1]
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("PaperDrop-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    // device body
    NSColor(calibratedWhite: 0.18, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 100 * s, y: 200 * s, width: 824 * s, height: 624 * s), xRadius: 70 * s, yRadius: 70 * s).fill()
    // e-paper
    NSColor(calibratedWhite: 0.93, alpha: 1).setFill()
    let screen = NSRect(x: 160 * s, y: 260 * s, width: 704 * s, height: 504 * s)
    NSBezierPath(rect: screen).fill()
    // mountains + sun in grays
    NSColor(calibratedWhite: 0.55, alpha: 1).setFill()
    let m = NSBezierPath()
    m.move(to: NSPoint(x: screen.minX, y: screen.minY))
    m.line(to: NSPoint(x: screen.minX + 230 * s, y: screen.minY + 280 * s))
    m.line(to: NSPoint(x: screen.minX + 380 * s, y: screen.minY + 140 * s))
    m.line(to: NSPoint(x: screen.minX + 520 * s, y: screen.minY + 330 * s))
    m.line(to: NSPoint(x: screen.maxX, y: screen.minY + 120 * s))
    m.line(to: NSPoint(x: screen.maxX, y: screen.minY))
    m.close()
    m.fill()
    NSColor(calibratedWhite: 0.3, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: screen.maxX - 200 * s, y: screen.maxY - 190 * s, width: 120 * s, height: 120 * s)).fill()
    // drop arrow
    NSColor.systemBlue.setFill()
    let a = NSBezierPath()
    a.move(to: NSPoint(x: 512 * s, y: 330 * s))
    a.line(to: NSPoint(x: 400 * s, y: 470 * s))
    a.line(to: NSPoint(x: 465 * s, y: 470 * s))
    a.line(to: NSPoint(x: 465 * s, y: 640 * s))
    a.line(to: NSPoint(x: 559 * s, y: 640 * s))
    a.line(to: NSPoint(x: 559 * s, y: 470 * s))
    a.line(to: NSPoint(x: 624 * s, y: 470 * s))
    a.close()
    a.fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: tmp.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: tmp.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", tmp.path, "-o", out]
try p.run()
p.waitUntilExit()
do {
    try FileManager.default.removeItem(at: tmp)
} catch {
    FileHandle.standardError.write(Data("warning: could not remove \(tmp.path): \(error)\n".utf8))
}
if p.terminationStatus != 0 {
    FileHandle.standardError.write(Data("iconutil failed (\(p.terminationStatus))\n".utf8))
    exit(1)
}
