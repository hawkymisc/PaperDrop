import CoreGraphics
import ImageIO
import XCTest
@testable import PaperKit

final class CRC32Tests: XCTestCase {
    func testStandardCheckValue() {
        // IEEE 802.3 / zlib check value
        XCTAssertEqual(CRC32.checksum(Array("123456789".utf8)), 0xCBF4_3926)
    }

    func testEmpty() {
        XCTAssertEqual(CRC32.checksum([]), 0)
    }
}

final class PackerTests: XCTestCase {
    func testHighNibbleIsLeftPixel() {
        let packed = Packer.pack(levels: [0x0, 0xF, 0x8, 0x1], width: 4, height: 1)
        XCTAssertEqual(packed, [0x0F, 0x81])
    }

    func testOddWidthPadsEachRow() {
        // 3x2: each row needs 2 bytes, last nibble padded with white (0xF)
        let packed = Packer.pack(levels: [1, 2, 3, 4, 5, 6], width: 3, height: 2)
        XCTAssertEqual(packed, [0x12, 0x3F, 0x45, 0x6F])
        XCTAssertEqual(Packer.packedLength(width: 3, height: 2), 4)
    }

    func testDeviceFrameLength() {
        XCTAssertEqual(Packer.packedLength(width: 960, height: 540), 259_200)
    }
}

final class QuantizerTests: XCTestCase {
    func testWithoutDitherMapsToNearestOf16Levels() {
        let out = Quantizer.quantize(gray: [0, 255, 128, 8, 9], width: 5, height: 1, dither: false)
        XCTAssertEqual(out, [0, 15, 8, 0, 1])
    }

    func testDitherPreservesAverageBrightness() {
        let w = 64, h = 64
        let gray = [UInt8](repeating: 100, count: w * h)
        let out = Quantizer.quantize(gray: gray, width: w, height: h, dither: true)
        XCTAssertTrue(out.allSatisfy { $0 <= 15 })
        let mean = Double(out.reduce(0) { $0 + Int($1) * 17 }) / Double(w * h)
        XCTAssertEqual(mean, 100, accuracy: 2.0)
        // 100/17 = 5.88: dithering must mix neighbouring levels, not collapse to one
        XCTAssertEqual(Set(out), [5, 6])
    }

    func testDitherKeepsPureBlackAndWhite() {
        let out = Quantizer.quantize(gray: [0, 0, 255, 255], width: 2, height: 2, dither: true)
        XCTAssertEqual(out, [0, 0, 15, 15])
    }
}

final class LayoutTests: XCTestCase {
    func testAutoOrientationFollowsImageAspect() {
        XCTAssertEqual(Layout.targetSize(sourceWidth: 4000, sourceHeight: 3000, orientation: .auto).width, 960)
        XCTAssertEqual(Layout.targetSize(sourceWidth: 3000, sourceHeight: 4000, orientation: .auto).width, 540)
        XCTAssertEqual(Layout.targetSize(sourceWidth: 1000, sourceHeight: 1000, orientation: .auto).width, 960)
    }

    func testForcedOrientation() {
        let p = Layout.targetSize(sourceWidth: 4000, sourceHeight: 3000, orientation: .portrait)
        XCTAssertEqual(p.width, 540)
        XCTAssertEqual(p.height, 960)
        let l = Layout.targetSize(sourceWidth: 3000, sourceHeight: 4000, orientation: .landscape)
        XCTAssertEqual(l.width, 960)
        XCTAssertEqual(l.height, 540)
    }

    func testFillCropsCentered() {
        let r = Layout.drawRect(sourceWidth: 1000, sourceHeight: 1000, targetWidth: 960, targetHeight: 540, fit: .fill)
        XCTAssertEqual(r, CGRect(x: 0, y: -210, width: 960, height: 960))
    }

    func testFitLetterboxesCentered() {
        let r = Layout.drawRect(sourceWidth: 1000, sourceHeight: 1000, targetWidth: 960, targetHeight: 540, fit: .fit)
        XCTAssertEqual(r, CGRect(x: 210, y: 0, width: 540, height: 540))
    }
}

final class ConverterTests: XCTestCase {
    /// Left half black, right half white, 200x100.
    private func makeHalfImage() -> CGImage {
        let ctx = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        return ctx.makeImage()!
    }

    func testConvertProducesDeviceFrameWithCorrectOrientation() {
        let img = ImageConverter.convert(makeHalfImage(), options: ConvertOptions(orientation: .auto, fit: .fill, dither: false))
        XCTAssertEqual(img.width, 960)
        XCTAssertEqual(img.height, 540)
        XCTAssertEqual(img.levels.count, 960 * 540)
        // top-left is black, top-right is white (no vertical/horizontal flip)
        XCTAssertEqual(img.level(x: 10, y: 10), 0)
        XCTAssertEqual(img.level(x: 950, y: 10), 15)
        XCTAssertEqual(img.packed().count, 259_200)
    }

    func testTopOfSourceIsTopOfFrame() {
        // CG y-up: fill the upper half (y 50..100) black
        let ctx = CGContext(data: nil, width: 160, height: 90, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 160, height: 90))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 45, width: 160, height: 45))
        let img = ImageConverter.convert(ctx.makeImage()!, options: ConvertOptions(dither: false))
        XCTAssertEqual(img.level(x: 480, y: 10), 0)
        XCTAssertEqual(img.level(x: 480, y: 530), 15)
    }

    func testRotate180() {
        let img = ImageConverter.convert(makeHalfImage(), options: ConvertOptions(orientation: .auto, fit: .fill, dither: false, rotate180: true))
        XCTAssertEqual(img.level(x: 10, y: 10), 15)
        XCTAssertEqual(img.level(x: 950, y: 530), 0)
    }

    func testFitLeavesWhiteMargins() {
        // 200x100 (2:1) into portrait 540x960 with fit: bands top/bottom are white
        let img = ImageConverter.convert(makeHalfImage(), options: ConvertOptions(orientation: .portrait, fit: .fit, dither: false))
        XCTAssertEqual(img.width, 540)
        XCTAssertEqual(img.level(x: 10, y: 5), 15)
        XCTAssertEqual(img.level(x: 10, y: 480), 0)
    }

    func testTransparentPixelsBecomeWhite() {
        let ctx = CGContext(data: nil, width: 16, height: 9, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.clear(CGRect(x: 0, y: 0, width: 16, height: 9))
        let img = ImageConverter.convert(ctx.makeImage()!, options: ConvertOptions(orientation: .auto, fit: .fill, dither: false))
        XCTAssertTrue(img.levels.allSatisfy { $0 == 15 })
    }

    func testPreviewMatchesLevels() throws {
        let img = ImageConverter.convert(makeHalfImage(), options: ConvertOptions(orientation: .auto, fit: .fill, dither: false))
        let preview = try XCTUnwrap(img.previewImage())
        XCTAssertEqual(preview.width, 960)
        XCTAssertEqual(preview.height, 540)
    }
}

final class LoaderTests: XCTestCase {
    func testLoadFromEncodedPNGData() throws {
        let ctx = CGContext(data: nil, width: 30, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let img = try ImageConverter.load(data: data as Data)
        XCTAssertEqual(img.width, 30)
        XCTAssertEqual(img.height, 20)
    }

    func testNonImageFileIsRejectedWithReadableError() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("not-an-image-\(UUID()).txt")
        try Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try ImageConverter.load(url: url)) { error in
            guard case .image(let msg) = error as? PaperError else { return XCTFail("\(error)") }
            XCTAssertTrue(msg.contains(url.lastPathComponent), msg)
        }
    }
}

final class SpecGapTests: XCTestCase {
    /// Encodes a 200x100 image (left half black) as JPEG with the given EXIF orientation.
    private func jpeg(orientation: Int) throws -> Data {
        let ctx = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    func testExifOrientationIsApplied() throws {
        // orientation 6 = rotate 90° CW for display: 200x100 stored becomes 100x200 upright
        let img = try ImageConverter.load(data: try jpeg(orientation: 6))
        XCTAssertEqual(img.width, 100)
        XCTAssertEqual(img.height, 200)
        let frame = ImageConverter.convert(img, options: ConvertOptions(orientation: .auto, dither: false))
        XCTAssertEqual(frame.width, 540)
        XCTAssertEqual(frame.height, 960)
        // stored left half (black) ends up on top after the 90° CW rotation
        XCTAssertEqual(frame.level(x: 270, y: 20), 0)
        XCTAssertEqual(frame.level(x: 270, y: 940), 15)
    }

    func testHugeImagesAreDownscaledOnLoad() throws {
        let ctx = CGContext(data: nil, width: 6000, height: 4000, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let img = try ImageConverter.load(data: data as Data)
        XCTAssertLessThanOrEqual(max(img.width, img.height), ImageConverter.maxDecodedSide)
        XCTAssertEqual(Double(img.width) / Double(img.height), 1.5, accuracy: 0.01)
    }

    func testPreviewPixelsAreLevelTimes17() throws {
        let levels: [UInt8] = (0..<(960 * 540)).map { UInt8($0 % 16) }
        let preview = try XCTUnwrap(PaperImage(width: 960, height: 540, levels: levels).previewImage())
        let bytes = try XCTUnwrap(preview.dataProvider?.data as Data?)
        XCTAssertEqual(Array(bytes.prefix(16)), (0..<16).map { UInt8($0 * 17) })
    }

    func testCMYKAndSixteenBitSourcesMapBlackAndWhite() throws {
        for (space, bpc, info) in [
            (CGColorSpaceCreateDeviceCMYK(), 8, CGImageAlphaInfo.none.rawValue),
            (CGColorSpaceCreateDeviceRGB(), 16, CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
        ] {
            let ctx = try XCTUnwrap(CGContext(data: nil, width: 160, height: 90, bitsPerComponent: bpc, bytesPerRow: 0, space: space, bitmapInfo: info))
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 160, height: 90))
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 80, height: 90))
            let frame = ImageConverter.convert(ctx.makeImage()!, options: ConvertOptions(dither: false))
            XCTAssertLessThanOrEqual(frame.level(x: 100, y: 270), 1, "\(space)")
            XCTAssertEqual(frame.level(x: 860, y: 270), 15, "\(space)")
        }
    }
}
