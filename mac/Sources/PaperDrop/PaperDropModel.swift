import AppKit
import Foundation
import PaperKit
import UniformTypeIdentifiers

@MainActor
final class PaperDropModel: ObservableObject {
    enum Connection: Equatable {
        case searching
        case connected(path: String)
        case disconnected(message: String)
    }

    @Published var options = ConvertOptions() { didSet { if options != oldValue { reconvert() } } }
    @Published var autoSend = true
    @Published private(set) var preview: NSImage?
    @Published private(set) var sourceName: String?
    @Published private(set) var progress: Double?
    @Published private(set) var status = L10n.t(.dropPrompt)
    @Published private(set) var isError = false
    @Published private(set) var connection: Connection = .searching

    private var source: CGImage?
    private var converted: PaperImage?
    private let io = DispatchQueue(label: "paperdrop.serial")
    /// Touched only on `io`.
    private let session = DeviceSession()

    var isBusy: Bool { progress != nil }
    var canSend: Bool { converted != nil && !isBusy }

    init() { connect() }

    // MARK: - input

    func open(urls: [URL]) {
        guard let url = urls.first else { return }
        decode(name: url.lastPathComponent, context: "open \(url.path)") { try ImageConverter.load(url: url) }
    }

    /// Decodes off the main thread (large photos take a while), then applies on main.
    private func decode(name: String, context: String, _ load: @escaping @Sendable () throws -> CGImage) {
        setStatus(L10n.t(.loading, name), error: false)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try load() }
            DispatchQueue.main.async {
                switch result {
                case .success(let image): self?.setSource(image, name: name)
                case .failure(let error): self?.report(error, context: context)
                }
            }
        }
    }

    /// Handles items dropped onto the window. Returns false if nothing usable was offered.
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadDataRepresentation(for: .fileURL) { data, error in
                let url = data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                Task { @MainActor in
                    if let url { self.open(urls: [url]) } else { self.report(error ?? PaperError.image(L10n.t(.fileUnavailable)), context: "drop fileURL") }
                }
            }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            let name = provider.suggestedName ?? L10n.t(.droppedImage)
            _ = provider.loadDataRepresentation(for: .image) { data, error in
                Task { @MainActor in
                    guard let data else {
                        self.report(error ?? PaperError.image(L10n.t(.imageDataUnavailable)), context: "drop image data")
                        return
                    }
                    self.decode(name: name, context: "drop image data") { try ImageConverter.load(data: data, name: name) }
                }
            }
            return true
        }
        return false
    }

    private func setSource(_ image: CGImage, name: String) {
        source = image
        sourceName = name
        reconvert()
        if autoSend { send() }
    }

    private func reconvert() {
        guard let source else { return }
        let img = ImageConverter.convert(source, options: options)
        converted = img
        preview = img.previewImage().map { NSImage(cgImage: $0, size: NSSize(width: img.width, height: img.height)) }
        if !isBusy { setStatus(L10n.t(.converted, sourceName ?? L10n.t(.imageFallbackName), img.width, img.height), error: false) }
    }

    // MARK: - device

    func connect() {
        guard !isBusy else { return }
        connection = .searching
        io.async { [weak self, session] in
            let result = Result { try session.ensureConnected() }
            DispatchQueue.main.async { self?.applyConnection(result.map { $0.port.path }) }
        }
    }

    private func applyConnection(_ result: Result<String, Error>) {
        switch result {
        case .success(let path):
            connection = .connected(path: path)
        case .failure(let error):
            connection = .disconnected(message: error.localizedDescription)
            NSLog("PaperDrop: device search failed: %@", String(describing: error))
        }
    }

    func send() {
        guard let image = converted, !isBusy else { return }
        run(start: L10n.t(.sending), context: "send") { client, progress in
            let ms = try client.send(image, progress: progress)
            return L10n.t(.shown, Double(ms) / 1000)
        }
    }

    func clearPanel() {
        guard !isBusy else { return }
        run(start: L10n.t(.clearing), context: "clear") { client, _ in
            try client.clear()
            return L10n.t(.cleared)
        }
    }

    /// Runs one device operation on the serial queue. Progress and completion are delivered
    /// to the main queue in FIFO order, so a late progress update can never follow completion.
    private func run(start: String, context: String,
                     _ body: @escaping (PaperClient, (Double) -> Void) throws -> String) {
        progress = 0
        setStatus(start, error: false)
        io.async { [weak self, session] in
            let started = Date()
            let result = Result { () -> (String, String) in
                try session.perform { client in
                    try body(client) { p in DispatchQueue.main.async { self?.progress = p } }
                }
            }
            let elapsed = Date().timeIntervalSince(started)
            DispatchQueue.main.async {
                guard let self else { return }
                self.progress = nil
                switch result {
                case .success(let (message, path)):
                    self.connection = .connected(path: path)
                    self.setStatus(message + L10n.t(.totalSuffix, elapsed), error: false)
                case .failure(let error):
                    self.connection = .disconnected(message: error.localizedDescription)
                    self.report(error, context: context)
                }
            }
        }
    }

    // MARK: - status

    private func setStatus(_ s: String, error: Bool) {
        status = s
        isError = error
    }

    private func report(_ error: Error, context: String) {
        NSLog("PaperDrop: %@ failed: %@", context, String(describing: error))
        setStatus(error.localizedDescription, error: true)
    }
}

/// Owns the open serial port. Every method must be called on the model's serial `io` queue,
/// so there is exactly one opener and the exclusive (TIOCEXCL) lock never races itself.
final class DeviceSession: @unchecked Sendable {
    private var device: DeviceLocator.Found?

    func ensureConnected() throws -> DeviceLocator.Found {
        if let device {
            do {
                // the device may still be persisting the previous image (seconds); wait it out
                _ = try device.client.ping(timeout: 15)
                return device
            } catch {
                NSLog("PaperDrop: ping on %@ failed (%@), searching again", device.port.path, String(describing: error))
                drop()
            }
        }
        let found = try DeviceLocator.find()
        device = found
        return found
    }

    /// Runs `body` against a live device; on failure the port is closed so the next call re-probes
    /// (and resyncs a device left mid-transfer).
    func perform<T>(_ body: (PaperClient) throws -> T) throws -> (T, String) {
        let dev = try ensureConnected()
        do {
            return (try body(dev.client), dev.port.path)
        } catch {
            drop()
            throw error
        }
    }

    private func drop() {
        device?.port.close()
        device = nil
    }
}
