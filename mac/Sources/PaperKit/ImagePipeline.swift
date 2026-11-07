import CoreGraphics
import Foundation
import ImageIO

public enum Orientation: String, CaseIterable, Identifiable, Sendable {
    case auto, landscape, portrait
    public var id: String { rawValue }
}

public enum FitMode: String, CaseIterable, Identifiable, Sendable {
    /// Crop to fill the whole panel.
    case fill
    /// Show the whole image with white margins.
    case fit
    public var id: String { rawValue }
}

public struct ConvertOptions: Equatable, Sendable {
    public var orientation: Orientation
    public var fit: FitMode
    public var dither: Bool
    public var rotate180: Bool

    public init(orientation: Orientation = .auto, fit: FitMode = .fill, dither: Bool = true, rotate180: Bool = false) {
        self.orientation = orientation
        self.fit = fit
        self.dither = dither
        self.rotate180 = rotate180
    }
}

/// 16-level grayscale frame (0 = black, 15 = white), row-major, top row first.
public struct PaperImage: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let levels: [UInt8]

    public init(width: Int, height: Int, levels: [UInt8]) {
        precondition(levels.count == width * height, "levels.count must equal width*height")
        self.width = width
        self.height = height
        self.levels = levels
    }

    public func level(x: Int, y: Int) -> UInt8 { levels[y * width + x] }

    public func packed() -> [UInt8] { Packer.pack(levels: levels, width: width, height: height) }

    /// What the e-paper will show.
    public func previewImage() -> CGImage? {
        let gray = levels.map { $0 * 17 }
        guard let provider = CGDataProvider(data: Data(gray) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

public enum Panel {
    public static let longSide = 960
    public static let shortSide = 540
}

public enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    public static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

public enum Packer {
    public static func packedLength(width: Int, height: Int) -> Int { (width + 1) / 2 * height }

    /// 2 px per byte, high nibble = left pixel. Odd widths pad with white.
    public static func pack(levels: [UInt8], width: Int, height: Int) -> [UInt8] {
        let rowBytes = (width + 1) / 2
        var out = [UInt8](repeating: 0, count: rowBytes * height)
        for y in 0..<height {
            for bx in 0..<rowBytes {
                let x = bx * 2
                let hi = levels[y * width + x] & 0x0F
                let lo = x + 1 < width ? levels[y * width + x + 1] & 0x0F : 0x0F
                out[y * rowBytes + bx] = hi << 4 | lo
            }
        }
        return out
    }
}

public enum Quantizer {
    /// Maps 8-bit gray to 16 levels. With `dither`, Floyd–Steinberg error diffusion.
    public static func quantize(gray: [UInt8], width: Int, height: Int, dither: Bool) -> [UInt8] {
        guard dither else { return gray.map { UInt8((Int($0) + 8) / 17) } }
        var buf = gray.map { Float($0) }
        var out = [UInt8](repeating: 0, count: gray.count)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let v = min(max(buf[i], 0), 255)
                let q = min(max(Int((v / 17).rounded()), 0), 15)
                out[i] = UInt8(q)
                let err = v - Float(q * 17)
                if x + 1 < width { buf[i + 1] += err * 7 / 16 }
                if y + 1 < height {
                    if x > 0 { buf[i + width - 1] += err * 3 / 16 }
                    buf[i + width] += err * 5 / 16
                    if x + 1 < width { buf[i + width + 1] += err * 1 / 16 }
                }
            }
        }
        return out
    }
}

public enum Layout {
    public static func targetSize(sourceWidth: Int, sourceHeight: Int, orientation: Orientation) -> (width: Int, height: Int) {
        switch orientation {
        case .landscape: return (Panel.longSide, Panel.shortSide)
        case .portrait: return (Panel.shortSide, Panel.longSide)
        case .auto:
            return sourceHeight > sourceWidth ? (Panel.shortSide, Panel.longSide) : (Panel.longSide, Panel.shortSide)
        }
    }

    /// Rect (in target pixel space, top-left origin) to draw the source into.
    public static func drawRect(sourceWidth: Int, sourceHeight: Int, targetWidth: Int, targetHeight: Int, fit: FitMode) -> CGRect {
        let sx = Double(targetWidth) / Double(sourceWidth)
        let sy = Double(targetHeight) / Double(sourceHeight)
        let s = fit == .fill ? max(sx, sy) : min(sx, sy)
        let w = (Double(sourceWidth) * s).rounded()
        let h = (Double(sourceHeight) * s).rounded()
        return CGRect(x: ((Double(targetWidth) - w) / 2).rounded(), y: ((Double(targetHeight) - h) / 2).rounded(), width: w, height: h)
    }
}

public enum ImageConverter {
    /// Decoding stops at this long side; 2x the panel is plenty for resampling quality.
    public static let maxDecodedSide = 2 * Panel.longSide
    /// Refuse files claiming more pixels than this (decompression-bomb guard).
    public static let maxSourcePixels = 100_000_000

    /// Loads any ImageIO-supported file, applying EXIF orientation.
    public static func load(url: URL) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw PaperError.image(L10n.t(.unreadableFile, url.lastPathComponent))
        }
        return try decode(src, name: url.lastPathComponent)
    }

    /// Loads encoded image bytes (e.g. an image dragged from a browser).
    public static func load(data: Data, name: String = L10n.t(.droppedImage)) throws -> CGImage {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw PaperError.image(L10n.t(.unreadableData, name))
        }
        return try decode(src, name: name)
    }

    private static func decode(_ src: CGImageSource, name: String) throws -> CGImage {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let pw = props[kCGImagePropertyPixelWidth] as? Int,
              let ph = props[kCGImagePropertyPixelHeight] as? Int else {
            throw PaperError.image(L10n.t(.notAnImage, name))
        }
        guard pw > 0, ph > 0, pw * ph <= maxSourcePixels else {
            throw PaperError.image(L10n.t(.imageTooLarge, pw, ph, name))
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(pw, ph), maxDecodedSide),
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw PaperError.image(L10n.t(.decodeFailed, name))
        }
        return img
    }

    public static func convert(_ image: CGImage, options: ConvertOptions) -> PaperImage {
        let (tw, th) = Layout.targetSize(sourceWidth: image.width, sourceHeight: image.height, orientation: options.orientation)
        var gray = [UInt8](repeating: 255, count: tw * th)
        gray.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: tw,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.interpolationQuality = .high
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: tw, height: th))
            // Bitmap row 0 is the top of the image in CG's y-up space, so convert the
            // top-left-origin layout rect into CG coordinates instead of flipping the CTM.
            if options.rotate180 {
                ctx.translateBy(x: CGFloat(tw), y: CGFloat(th))
                ctx.rotate(by: .pi)
            }
            let r = Layout.drawRect(sourceWidth: image.width, sourceHeight: image.height, targetWidth: tw, targetHeight: th, fit: options.fit)
            ctx.draw(image, in: CGRect(x: r.minX, y: CGFloat(th) - r.maxY, width: r.width, height: r.height))
        }
        let levels = Quantizer.quantize(gray: gray, width: tw, height: th, dither: options.dither)
        return PaperImage(width: tw, height: th, levels: levels)
    }
}
