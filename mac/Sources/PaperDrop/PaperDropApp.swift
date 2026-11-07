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
                Button("画像を開く…") { openPanel() }.keyboardShortcut("o")
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
                    Text("画像をドロップすると M5Paper に表示します").font(.headline)
                    Text("JPEG / PNG / HEIC / TIFF / GIF など。⌘O でも選べます").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(height: 340)
        .onDrop(of: [.fileURL, .image], isTargeted: $targeted) { model.handleDrop($0) }
        .accessibilityLabel("画像のドロップ先")
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("向き", selection: $model.options.orientation) {
                    Text("自動").tag(Orientation.auto)
                    Text("横").tag(Orientation.landscape)
                    Text("縦").tag(Orientation.portrait)
                }
                .pickerStyle(.segmented)
                .frame(width: 210)
                Picker("配置", selection: $model.options.fit) {
                    Text("全面").tag(FitMode.fill)
                    Text("全体").tag(FitMode.fit)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                Spacer()
            }
            HStack(spacing: 16) {
                Toggle("ディザ", isOn: $model.options.dither)
                Toggle("180°回転", isOn: $model.options.rotate180)
                Toggle("ドロップで即送信", isOn: $model.autoSend)
                Spacer()
                Button("クリア") { model.clearPanel() }.disabled(model.isBusy)
                Button("送信") { model.send() }
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
            Label("検索中…", systemImage: "antenna.radiowaves.left.and.right").foregroundStyle(.secondary)
        case .connected(let path):
            Label((path as NSString).lastPathComponent, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                .help("M5Paper に接続中: \(path)")
        case .disconnected(let message):
            Button {
                model.connect()
            } label: {
                Label("未接続（再検索）", systemImage: "exclamationmark.triangle.fill")
            }
            .buttonStyle(.link)
            .foregroundStyle(.orange)
            .disabled(model.isBusy)
            .help(message)
        }
    }
}
