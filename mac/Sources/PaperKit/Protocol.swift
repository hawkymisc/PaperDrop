import Foundation
import os

let log = Logger(subsystem: "local.paperdrop", category: "PaperKit")

public enum PaperError: Error, Equatable, LocalizedError {
    case timeout(String)
    case device(String)
    case io(String)
    case notFound
    case image(String)
    case protocolViolation(String)

    public var errorDescription: String? { message(in: L10n.language) }

    /// The wrapper text follows `lang`. The payloads are not re-translated: `.image` and the
    /// port-busy / port-disconnected `.io` messages were localized in `L10n.language` when thrown;
    /// the rest are technical details (errno text, protocol lines) and stay as they are.
    public func message(in lang: Language) -> String {
        switch self {
        case .timeout(let s): return L10n.format(.errTimeout, in: lang, s)
        case .device(let s): return L10n.format(.errDevice, in: lang, s)
        case .io(let s): return L10n.format(.errIO, in: lang, s)
        case .notFound: return L10n.text(.errNotFound, in: lang)
        case .image(let s): return s
        case .protocolViolation(let s): return L10n.format(.errProtocol, in: lang, s)
        }
    }
}

public protocol ByteTransport: AnyObject {
    func write(_ data: [UInt8]) throws
    /// Returns one line without the terminator.
    func readLine(timeout: TimeInterval) throws -> String
}

public struct DeviceInfo: Equatable, Sendable {
    public let protocolVersion: Int
    public let longSide: Int
    public let shortSide: Int
    public let uptimeMs: Int

    /// Parses `PONG PaperDrop <ver> <W>x<H> up=<ms>`.
    public init?(pong line: String) {
        let p = line.split(separator: " ").map(String.init)
        guard p.count >= 5, p[0] == "PONG", p[1] == "PaperDrop", let v = Int(p[2]) else { return nil }
        let wh = p[3].split(separator: "x").compactMap { Int($0) }
        guard wh.count == 2, p[4].hasPrefix("up="), let up = Int(p[4].dropFirst(3)) else { return nil }
        protocolVersion = v
        longSide = wh[0]
        shortSide = wh[1]
        uptimeMs = up
    }
}

/// Host side of protocol v1 (docs/DESIGN.md).
/// Not thread-safe: callers must serialize all access, like the underlying transport.
public final class PaperClient: @unchecked Sendable {
    public static let chunkSize = 4096
    private let transport: ByteTransport

    public init(transport: ByteTransport) { self.transport = transport }

    public func ping(timeout: TimeInterval = 2) throws -> DeviceInfo {
        try sendLine("PING")
        // PING never fails on the device, so ERR lines here are leftovers (e.g. an aborted transfer)
        let line = try waitFor(prefixes: ["PONG"], timeout: timeout, errorsAreFatal: false)
        guard let info = DeviceInfo(pong: line) else { throw PaperError.protocolViolation(line) }
        return info
    }

    /// Sends the image and returns the device's reported refresh time in ms.
    @discardableResult
    public func send(_ image: PaperImage, progress: (Double) -> Void) throws -> Int {
        let data = image.packed()
        let crc = CRC32.checksum(data)
        try sendLine("IMG \(image.width) \(image.height) \(data.count) \(String(format: "%08x", crc))")
        // generous: the device may still be persisting the previous image
        _ = try waitFor(prefixes: ["READY"], timeout: 15)
        progress(0)

        var sent = 0
        while sent < data.count {
            let end = min(sent + Self.chunkSize, data.count)
            try transport.write(Array(data[sent..<end]))
            let ack = try waitFor(prefixes: ["ACK"], timeout: 5)
            guard let n = Int(ack.dropFirst(4)), n == end else {
                throw PaperError.protocolViolation("ACK mismatch: expected \(end), got \(ack)")
            }
            sent = end
            progress(Double(sent) / Double(data.count))
        }
        _ = try waitFor(prefixes: ["OK"], timeout: 3)
        return try shownMs(try waitFor(prefixes: ["SHOWN"], timeout: 30))
    }

    /// Waits until the device has been silent for `quiet` seconds, discarding its output.
    /// After an aborted image transfer the device is still collecting body bytes; staying
    /// silent longer than its 3 s receive timeout lets it give up, report and drain.
    public func resync(quiet: TimeInterval = 3.4) {
        var discarded = 0
        while true {
            do {
                let line = try transport.readLine(timeout: quiet)
                discarded += 1
                log.debug("resync discarded: \(line, privacy: .public)")
            } catch {
                // a timeout is the expected way out; anything else is surfaced by the next command
                if case PaperError.timeout = error {} else { log.error("resync ended by \(String(describing: error), privacy: .public)") }
                break
            }
        }
        log.info("resync done, discarded \(discarded) line(s)")
    }

    private func shownMs(_ line: String) throws -> Int {
        guard let ms = Int(line.dropFirst(6)) else { throw PaperError.protocolViolation(line) }
        return ms
    }

    @discardableResult
    public func clear() throws -> Int {
        try sendLine("CLEAR")
        return try shownMs(try waitFor(prefixes: ["SHOWN"], timeout: 30))
    }

    public func pixel(x: Int, y: Int) throws -> Int {
        try sendLine("PIX \(x) \(y)")
        let line = try waitFor(prefixes: ["PIX"], timeout: 15)  // may queue behind a save
        guard let v = Int(line.dropFirst(4)) else { throw PaperError.protocolViolation(line) }
        return v
    }

    private func sendLine(_ s: String) throws { try transport.write(Array((s + "\n").utf8)) }

    /// Waits for a line starting with one of `prefixes` (or `ERR`), skipping log/boot noise.
    private func waitFor(prefixes: [String], timeout: TimeInterval, errorsAreFatal: Bool = true) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw PaperError.timeout("waiting for \(prefixes.joined(separator: "/"))") }
            let line = try transport.readLine(timeout: remaining).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("ERR") && errorsAreFatal {
                throw PaperError.device(String(line.dropFirst(4)))
            }
            if prefixes.contains(where: { line == $0 || line.hasPrefix($0 + " ") }) { return line }
            // anything else ("# log", ROM boot messages) is ignored
        }
    }
}
