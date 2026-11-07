import XCTest
@testable import PaperKit

/// In-memory model of the firmware's protocol v1 (docs/DESIGN.md, PaperDropReceiver.ino).
final class FakeDevice: ByteTransport {
    enum Behaviour: Equatable {
        case normal
        case corruptCRC
        /// device accepts the header but never ACKs (host must time out)
        case stopAcking
        /// device reports a wrong cumulative count
        case wrongAck
        /// device PSRAM allocation fails
        case noMemory
        /// SHOWN line without a number
        case malformedShown
        /// transport fails on the Nth write call (USB unplugged)
        case ioErrorOnWrite(Int)
    }

    var behaviour: Behaviour
    private var outbox: [String] = []
    private var inLine: [UInt8] = []
    private var expecting = 0
    private var expectedCRC: UInt32 = 0
    private var body: [UInt8] = []
    private var sinceAck = 0
    private var pendingSize = (0, 0)
    private(set) var received: [UInt8]?
    private(set) var receivedSize: (Int, Int)?
    private(set) var writeSizes: [Int] = []
    private(set) var commands: [String] = []

    init(behaviour: Behaviour = .normal, bootNoise: [String] = []) {
        self.behaviour = behaviour
        outbox = bootNoise
    }

    func write(_ data: [UInt8]) throws {
        writeSizes.append(data.count)
        if case .ioErrorOnWrite(let n) = behaviour, writeSizes.count == n {
            throw PaperError.io("fake unplugged")
        }
        for b in data {
            if expecting > 0 {
                body.append(b)
                sinceAck += 1
                if sinceAck == 4096 || body.count == expecting {
                    sinceAck = 0
                    if behaviour != .stopAcking {
                        outbox.append("# log noise between acks")
                        outbox.append("ACK \(behaviour == .wrongAck ? body.count - 1 : body.count)")
                    }
                }
                if body.count == expecting {
                    expecting = 0
                    finishImage()
                }
                continue
            }
            if b == UInt8(ascii: "\n") {
                handle(String(decoding: inLine, as: UTF8.self))
                inLine = []
            } else {
                inLine.append(b)
            }
        }
    }

    private func finishImage() {
        var crc = CRC32.checksum(body)
        if behaviour == .corruptCRC { crc ^= 1 }
        if crc != expectedCRC {
            outbox.append(String(format: "ERR crc %08x", crc))
            return
        }
        outbox.append("OK")
        received = body
        receivedSize = pendingSize
        outbox.append(behaviour == .malformedShown ? "SHOWN" : "SHOWN 1234")
    }

    private func handle(_ line: String) {
        commands.append(line)
        let parts = line.split(separator: " ").map(String.init)
        switch parts.first {
        case "PING":
            outbox.append("PONG PaperDrop 1 960x540 up=4242")
        case "IMG":
            guard parts.count == 5, let w = Int(parts[1]), let h = Int(parts[2]), let len = Int(parts[3]),
                  let crc = UInt32(parts[4], radix: 16) else { outbox.append("ERR unknown"); return }
            // same validation order as cmd_img()
            guard (w == 960 && h == 540) || (w == 540 && h == 960) else { outbox.append("ERR size"); return }
            guard len == (w + 1) / 2 * h else { outbox.append("ERR length"); return }
            guard behaviour != .noMemory else { outbox.append("ERR memory"); return }
            pendingSize = (w, h)
            expecting = len
            expectedCRC = crc
            body = []
            sinceAck = 0
            outbox.append("READY")
        case "CLEAR":
            outbox.append("SHOWN 900")
        case "PIX":
            outbox.append("PIX 7")
        default:
            outbox.append("ERR unknown")
        }
    }

    func readLine(timeout: TimeInterval) throws -> String {
        guard !outbox.isEmpty else { throw PaperError.timeout("fake: nothing to read") }
        return outbox.removeFirst()
    }
}

final class ProtocolTests: XCTestCase {
    private func sampleImage(width: Int = 960, height: Int = 540) -> PaperImage {
        var levels = [UInt8](repeating: 15, count: width * height)
        for i in stride(from: 0, to: levels.count, by: 7) { levels[i] = UInt8(i % 16) }
        return PaperImage(width: width, height: height, levels: levels)
    }

    private func assertDeviceError(_ expr: @autoclosure () throws -> Any, prefix: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expr(), file: file, line: line) { error in
            guard case .device(let reason) = error as? PaperError else { return XCTFail("\(error)", file: file, line: line) }
            XCTAssertTrue(reason.hasPrefix(prefix), reason, file: file, line: line)
        }
    }

    func testPingParsesDeviceInfoAndSkipsBootNoise() throws {
        let dev = FakeDevice(bootNoise: ["ESP-ROM:esp32s3-20210327", "# ready, board=34"])
        let info = try PaperClient(transport: dev).ping()
        XCTAssertEqual(info.protocolVersion, 1)
        XCTAssertEqual(info.longSide, 960)
        XCTAssertEqual(info.shortSide, 540)
        XCTAssertEqual(info.uptimeMs, 4242)
    }

    func testPingIgnoresStaleErrorFromAnAbortedTransfer() throws {
        let dev = FakeDevice(bootNoise: ["ERR timeout 8192", "ERR unknown"])
        XCTAssertEqual(try PaperClient(transport: dev).ping().uptimeMs, 4242)
    }

    func testSendTransfersExactBytesInAckedChunks() throws {
        let dev = FakeDevice()
        let image = sampleImage()
        var progress: [Double] = []
        let ms = try PaperClient(transport: dev).send(image) { progress.append($0) }
        XCTAssertEqual(ms, 1234)
        XCTAssertEqual(dev.received, image.packed())
        XCTAssertEqual(dev.receivedSize?.0, 960)
        XCTAssertEqual(dev.receivedSize?.1, 540)
        XCTAssertEqual(dev.commands.first, String(format: "IMG 960 540 259200 %08x", CRC32.checksum(image.packed())))
        // header line + 64 chunks (63 x 4096 + 1 x 1152)
        XCTAssertEqual(dev.writeSizes.dropFirst().count, 64)
        XCTAssertTrue(dev.writeSizes.dropFirst().allSatisfy { $0 <= 4096 })
        XCTAssertEqual(progress.last, 1.0)
        XCTAssertEqual(progress, progress.sorted())
    }

    func testPortraitFrameIsAccepted() throws {
        let dev = FakeDevice()
        try PaperClient(transport: dev).send(sampleImage(width: 540, height: 960)) { _ in }
        XCTAssertEqual(dev.receivedSize?.0, 540)
    }

    func testUnsupportedSizeIsRejectedByDevice() {
        assertDeviceError(try PaperClient(transport: FakeDevice()).send(sampleImage(width: 100, height: 100)) { _ in }, prefix: "size")
    }

    func testCRCMismatchIsReported() {
        assertDeviceError(try PaperClient(transport: FakeDevice(behaviour: .corruptCRC)).send(sampleImage()) { _ in }, prefix: "crc ")
    }

    func testDeviceOutOfMemoryIsReported() {
        assertDeviceError(try PaperClient(transport: FakeDevice(behaviour: .noMemory)).send(sampleImage()) { _ in }, prefix: "memory")
    }

    func testMissingAckTimesOut() {
        XCTAssertThrowsError(try PaperClient(transport: FakeDevice(behaviour: .stopAcking)).send(sampleImage()) { _ in }) { error in
            guard case .timeout = error as? PaperError else { return XCTFail("\(error)") }
        }
    }

    func testWrongAckCountIsAProtocolViolation() {
        XCTAssertThrowsError(try PaperClient(transport: FakeDevice(behaviour: .wrongAck)).send(sampleImage()) { _ in }) { error in
            guard case .protocolViolation = error as? PaperError else { return XCTFail("\(error)") }
        }
    }

    func testTransportFailureMidTransferPropagatesUnchanged() {
        XCTAssertThrowsError(try PaperClient(transport: FakeDevice(behaviour: .ioErrorOnWrite(5))).send(sampleImage()) { _ in }) { error in
            XCTAssertEqual(error as? PaperError, .io("fake unplugged"))
        }
    }

    func testMalformedShownIsAProtocolViolation() {
        XCTAssertThrowsError(try PaperClient(transport: FakeDevice(behaviour: .malformedShown)).send(sampleImage()) { _ in }) { error in
            guard case .protocolViolation = error as? PaperError else { return XCTFail("\(error)") }
        }
    }

    func testClearAndPixelSendTheDocumentedCommands() throws {
        let dev = FakeDevice()
        let client = PaperClient(transport: dev)
        XCTAssertEqual(try client.clear(), 900)
        XCTAssertEqual(try client.pixel(x: 1, y: 2), 7)
        XCTAssertEqual(dev.commands, ["CLEAR", "PIX 1 2"])
    }

    func testResyncDiscardsPendingOutput() throws {
        let dev = FakeDevice(bootNoise: ["ERR timeout 4096", "# drained"])
        let client = PaperClient(transport: dev)
        client.resync(quiet: 0.01)
        XCTAssertEqual(try client.ping().protocolVersion, 1)
    }

    func testParsePong() {
        XCTAssertNil(DeviceInfo(pong: "PONG Other 1 960x540 up=1"))
        XCTAssertNil(DeviceInfo(pong: "PONG PaperDrop 1 960x540"))
        XCTAssertEqual(DeviceInfo(pong: "PONG PaperDrop 1 960x540 up=99")?.uptimeMs, 99)
    }
}
