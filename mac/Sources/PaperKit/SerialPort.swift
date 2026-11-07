import Darwin
import Foundation
import IOKit
import IOKit.serial

/// Minimal POSIX serial port for USB CDC devices.
/// Not thread-safe: callers must serialize all access (the app uses one dispatch queue).
public final class SerialPort: ByteTransport, @unchecked Sendable {
    public let path: String
    private var fd: Int32
    private var buffer: [UInt8] = []

    public init(path: String) throws {
        self.path = path
        fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw PaperError.io("open \(path): \(String(cString: strerror(errno)))") }
        do {
            try configure()
        } catch {
            Darwin.close(fd)
            fd = -1
            throw error
        }
    }

    deinit { close() }

    public func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    private func configure() throws {
        guard ioctl(fd, TIOCEXCL) == 0 else { throw PaperError.io(L10n.t(.portBusy, path)) }
        var t = termios()
        guard tcgetattr(fd, &t) == 0 else { throw PaperError.io("tcgetattr: \(String(cString: strerror(errno)))") }
        cfmakeraw(&t)
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        cfsetspeed(&t, speed_t(B115200))
        guard tcsetattr(fd, TCSANOW, &t) == 0 else { throw PaperError.io("tcsetattr: \(String(cString: strerror(errno)))") }
        tcflush(fd, TCIOFLUSH)
    }

    public func write(_ data: [UInt8]) throws {
        var off = 0
        while off < data.count {
            let n = data[off...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                off += n
            } else if n < 0 && (errno == EAGAIN || errno == EINTR) {
                var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                guard poll(&p, 1, 5000) > 0 else { throw PaperError.timeout("write to \(path)") }
            } else {
                throw PaperError.io("write: \(String(cString: strerror(errno)))")
            }
        }
    }

    public func readLine(timeout: TimeInterval) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                var line = Array(buffer[..<nl])
                buffer.removeSubrange(...nl)
                if line.last == UInt8(ascii: "\r") { line.removeLast() }
                return String(decoding: line, as: UTF8.self)
            }
            let ms = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
            guard ms > 0 else { throw PaperError.timeout("read from \(path)") }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let r = poll(&p, 1, ms)
            if r < 0 && errno != EINTR { throw PaperError.io("poll: \(String(cString: strerror(errno)))") }
            if r <= 0 { continue }
            if p.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { throw PaperError.io(L10n.t(.portDisconnected, path)) }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                buffer.append(contentsOf: chunk[..<n])
            } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
                throw PaperError.io(L10n.t(.portDisconnected, path))
            }
        }
    }

    /// Espressif's USB vendor ID (ESP32-S3 built-in USB-Serial/JTAG).
    public static let espressifVendorID = 0x303A

    /// USB serial callout devices with their USB vendor ID (nil if IOKit doesn't report one).
    public static func candidates() -> [(path: String, vendorID: Int?)] {
        var result: [(String, Int?)] = []
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOSerialBSDServiceValue), &iterator)
        guard kr == KERN_SUCCESS else {
            log.error("IOServiceGetMatchingServices failed: \(kr)")
            return []
        }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let path = IORegistryEntryCreateCFProperty(service, kIOCalloutDeviceKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String,
                  path.hasPrefix("/dev/cu.usb") || path.hasPrefix("/dev/cu.wchusb") else { continue }
            let vid = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "idVendor" as CFString, kCFAllocatorDefault,
                                                      IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? Int
            result.append((path, vid))
        }
        return result.sorted { $0.0 < $1.0 }
    }
}

public enum DeviceLocator {
    public struct Found: @unchecked Sendable {
        public let port: SerialPort
        public let client: PaperClient
        public let info: DeviceInfo
    }

    /// Opens the first Espressif port that answers PING as a PaperDrop receiver.
    /// Non-Espressif ports (other Arduinos, printers) are never opened unless named explicitly.
    public static func find(preferredPath: String? = nil) throws -> Found {
        var paths = SerialPort.candidates().compactMap { c -> String? in
            if c.vendorID == SerialPort.espressifVendorID || c.vendorID == nil { return c.path }
            log.debug("skip \(c.path, privacy: .public): vendor \(c.vendorID ?? -1)")
            return nil
        }
        if let p = preferredPath { paths.removeAll { $0 == p }; paths.insert(p, at: 0) }
        var lastError: Error = PaperError.notFound
        for path in paths {
            do {
                return try probe(path)
            } catch {
                log.error("probe \(path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                // keep the most actionable cause: "port in use" beats a later timeout elsewhere
                if case PaperError.io(_) = lastError {} else { lastError = error }
            }
        }
        if case PaperError.io(_) = lastError { throw lastError }
        throw PaperError.notFound
    }

    private static func probe(_ path: String) throws -> Found {
        let port = try SerialPort(path: path)
        let client = PaperClient(transport: port)
        for attempt in 0..<2 {
            do {
                return Found(port: port, client: client, info: try client.ping(timeout: 1.0))
            } catch PaperError.timeout(let what) {
                log.info("ping \(path, privacy: .public) attempt \(attempt) timed out (\(what, privacy: .public))")
            }
        }
        // Possibly stuck mid-image after an aborted transfer: let it time out and drain.
        client.resync()
        return Found(port: port, client: client, info: try client.ping(timeout: 2.0))
    }
}
