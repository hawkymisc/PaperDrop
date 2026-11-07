import Foundation
import ImageIO
import PaperKit
import UniformTypeIdentifiers

// paperdrop-cli: headless sender for automation and E2E checks.
//   paperdrop-cli ping
//   paperdrop-cli send <image> [--portrait|--landscape] [--fit] [--no-dither] [--rotate180] [--verify N] [--preview out.png]
//   paperdrop-cli clear
//   paperdrop-cli pix <x> <y>

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + msg + "\n").utf8))
    exit(1)
}

func savePNG(_ image: CGImage, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw PaperError.image("cannot create \(path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw PaperError.image("cannot write \(path)") }
}

/// Prints every line received from the device with a timestamp (--trace).
final class TracingTransport: ByteTransport {
    let inner: ByteTransport
    let t0 = Date()
    init(_ inner: ByteTransport) { self.inner = inner }
    func write(_ data: [UInt8]) throws {
        if data.count < 64 { trace(">> " + String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)) }
        try inner.write(data)
    }
    func readLine(timeout: TimeInterval) throws -> String {
        do {
            let line = try inner.readLine(timeout: timeout)
            trace("<< " + line)
            return line
        } catch {
            trace("!! \(error)")
            throw error
        }
    }
    private func trace(_ s: String) {
        FileHandle.standardError.write(Data(String(format: "[%7.3f] %@\n", Date().timeIntervalSince(t0), s).utf8))
    }
}

var args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { fail("usage: paperdrop-cli ping|send|clear|pix ...") }
args.removeFirst()

func flag(_ name: String) -> Bool {
    if let i = args.firstIndex(of: name) { args.remove(at: i); return true }
    return false
}

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

do {
    let port = option("--port")
    let tracing = flag("--trace")
    func client(_ dev: DeviceLocator.Found) -> PaperClient {
        tracing ? PaperClient(transport: TracingTransport(dev.port)) : dev.client
    }
    switch cmd {
    case "ping":
        let dev = try DeviceLocator.find(preferredPath: port)
        print("found \(dev.port.path): protocol v\(dev.info.protocolVersion) \(dev.info.longSide)x\(dev.info.shortSide) up=\(dev.info.uptimeMs)ms")

    case "send":
        var opts = ConvertOptions()
        if flag("--portrait") { opts.orientation = .portrait }
        if flag("--landscape") { opts.orientation = .landscape }
        if flag("--fit") { opts.fit = .fit }
        if flag("--no-dither") { opts.dither = false }
        if flag("--rotate180") { opts.rotate180 = true }
        let verify = option("--verify").flatMap(Int.init) ?? 0
        let preview = option("--preview")
        guard let file = args.first else { fail("send: image path required") }

        let t0 = Date()
        let image = ImageConverter.convert(try ImageConverter.load(url: URL(fileURLWithPath: file)), options: opts)
        print(String(format: "converted %@ -> %dx%d in %.2fs", file, image.width, image.height, Date().timeIntervalSince(t0)))
        if let preview, let cg = image.previewImage() { try savePNG(cg, to: preview) }

        let dev = try DeviceLocator.find(preferredPath: port)
        print("device \(dev.port.path) up=\(dev.info.uptimeMs)ms")
        let t1 = Date()
        var lastPct = -1
        let refreshMs = try client(dev).send(image) { p in
            let pct = Int(p * 100)
            if pct / 25 != lastPct / 25 { print("  progress \(pct)%"); lastPct = pct }
        }
        print(String(format: "sent %d bytes, total %.2fs (panel refresh %dms)", image.packed().count, Date().timeIntervalSince(t1), refreshMs))

        if verify > 0 {
            var rng = SystemRandomNumberGenerator()
            var mismatches = 0
            for _ in 0..<verify {
                let x = Int.random(in: 0..<image.width, using: &rng)
                let y = Int.random(in: 0..<image.height, using: &rng)
                let got = try client(dev).pixel(x: x, y: y)
                let want = Int(image.level(x: x, y: y))
                if got != want { mismatches += 1; print("  mismatch at (\(x),\(y)): device=\(got) sent=\(want)") }
            }
            print("verify: \(verify - mismatches)/\(verify) pixels match")
            if mismatches > 0 { exit(2) }
        }

    case "clear":
        let dev = try DeviceLocator.find(preferredPath: port)
        print("cleared in \(try dev.client.clear())ms")

    case "pix":
        guard args.count >= 2, let x = Int(args[0]), let y = Int(args[1]) else { fail("pix: x y required") }
        let dev = try DeviceLocator.find(preferredPath: port)
        print(try dev.client.pixel(x: x, y: y))

    default:
        fail("unknown command \(cmd)")
    }
} catch {
    fail(error.localizedDescription)
}
