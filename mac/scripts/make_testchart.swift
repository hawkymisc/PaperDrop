// Renders a 1920x1080 test chart: 16-step gray ramp, smooth gradient, orientation marker.
// usage: swift make_testchart.swift <out.png>
import AppKit
let W = 1920, H = 1080
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor.white.setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
// 16 steps across the top half (y-up coords: top = high y)
for i in 0..<16 {
    NSColor(calibratedWhite: CGFloat(i) / 15, alpha: 1).setFill()
    NSRect(x: i * W / 16, y: H / 2, width: W / 16 + 1, height: H / 2 - 200).fill()
}
// smooth gradient band
NSGradient(starting: .black, ending: .white)!.draw(in: NSRect(x: 0, y: 200, width: W, height: 300), angle: 0)
// orientation marker: black square top-left + label
NSColor.black.setFill(); NSRect(x: 0, y: H - 200, width: 200, height: 200).fill()
let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 110), .foregroundColor: NSColor.black]
("PaperDrop ↖ TOP-LEFT" as NSString).draw(at: NSPoint(x: 240, y: H - 170), withAttributes: attrs)
("bottom" as NSString).draw(at: NSPoint(x: 40, y: 30), withAttributes: attrs)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
