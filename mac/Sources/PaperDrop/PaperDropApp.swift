import AppKit
import PaperKit
import SwiftUI
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onOpen: (([URL]) -> Void)?
    private var pending: [URL] = []

    /// Files dropped on the Dock icon or opened via Finder's "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        if let onOpen { onOpen(urls) } else { pending += urls }
    }

    func attach(_ handler: @escaping ([URL]) -> Void) {
        onOpen = handler
        if !pending.isEmpty { handler(pending); pending = [] }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct PaperDropApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = PaperDropModel()

    var body: some Scene {
        Window("PaperDrop", id: "main") {
            ContentView(model: model)
                .onAppear { delegate.attach { urls in model.open(urls: urls) } }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L10n.t(.openImageMenu)) { openPanel() }.keyboardShortcut("o")
            }
        }
    }

    @MainActor
    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK { model.open(urls: panel.urls) }
    }
}

struct ContentView: View {
    @ObservedObject var model: PaperDropModel
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 14) {
            dropZone
            controls
            statusBar
        }
        .padding(18)
        .frame(width: 620)
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.4),
                              style: StrokeStyle(lineWidth: targeted ? 3 : 1.5, dash: model.preview == nil ? [8, 6] : []))
            if let preview = model.preview {
                Image(nsImage: preview)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .shadow(radius: 2)
                    .padding(14)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 44)).foregroundStyle(.secondary)
                    Text(L10n.t(.dropTitle)).font(.headline)
                    Text(L10n.t(.dropHint)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(height: 340)
        .onDrop(of: [.fileURL, .image], isTargeted: $targeted) { model.handleDrop($0) }
        .accessibilityLabel(L10n.t(.dropZoneA11y))
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker(L10n.t(.orientation), selection: $model.options.orientation) {
                    Text(L10n.t(.orientationAuto)).tag(Orientation.auto)
                    Text(L10n.t(.landscape)).tag(Orientation.landscape)
                    Text(L10n.t(.portrait)).tag(Orientation.portrait)
                }
                .pickerStyle(.segmented)
                .frame(width: 210)
                Picker(L10n.t(.layout), selection: $model.options.fit) {
                    Text(L10n.t(.fill)).tag(FitMode.fill)
                    Text(L10n.t(.fit)).tag(FitMode.fit)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                Spacer()
            }
            HStack(spacing: 16) {
                Toggle(L10n.t(.dither), isOn: $model.options.dither)
                Toggle(L10n.t(.rotate180), isOn: $model.options.rotate180)
                Toggle(L10n.t(.autoSend), isOn: $model.autoSend)
                Spacer()
                Button(L10n.t(.clear)) { model.clearPanel() }.disabled(model.isBusy)
                Button(L10n.t(.send)) { model.send() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canSend)
            }
        }
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let p = model.progress {
                ProgressView(value: p).progressViewStyle(.linear)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(model.status)
                    .foregroundStyle(model.isError ? Color.red : Color.primary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer()
                connectionBadge
            }
            .font(.callout)
        }
    }

    @ViewBuilder
    private var connectionBadge: some View {
        switch model.connection {
        case .searching:
            Label(L10n.t(.searching), systemImage: "antenna.radiowaves.left.and.right").foregroundStyle(.secondary)
        case .connected(let path):
            Label((path as NSString).lastPathComponent, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                .help(L10n.t(.connectedHelp, path))
        case .disconnected(let message):
            Button {
                model.connect()
            } label: {
                Label(L10n.t(.disconnected), systemImage: "exclamationmark.triangle.fill")
            }
            .buttonStyle(.link)
            .foregroundStyle(.orange)
            .disabled(model.isBusy)
            .help(message)
        }
    }
}
