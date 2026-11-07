import Foundation

/// UI languages. Raw values are the `.lproj` folder names in PaperDrop.app (see build_app.sh).
public enum Language: String, CaseIterable, Sendable {
    case en
    case ja
    case zhHans = "zh-Hans"
}

/// String table for the app, the CLI and PaperError. Each language is an exhaustive `switch`,
/// so a key without a translation fails to compile; L10nTests checks the placeholders match.
public enum L10n {
    /// Chosen once at launch by the same rule AppKit uses for the bundle's localizations,
    /// so our text matches the system-provided menus (and honours the per-app language setting).
    public static let language: Language = resolve(Locale.preferredLanguages)

    /// `en` is listed first, so it is also what Foundation answers when nothing matches.
    public static func resolve(_ preferences: [String]) -> Language {
        guard !preferences.isEmpty else { return .en }
        let best = Bundle.preferredLocalizations(from: Language.allCases.map(\.rawValue), forPreferences: preferences).first
        return best.flatMap(Language.init(rawValue:)) ?? .en
    }

    /// Text in the app language.
    public static func t(_ key: Key) -> String { format(key, in: language, []) }

    /// Formatted text in the app language.
    public static func t(_ key: Key, _ args: CVarArg...) -> String { format(key, in: language, args) }

    public static func format(_ key: Key, in lang: Language, _ args: CVarArg...) -> String {
        format(key, in: lang, args)
    }

    /// CVarArg has no compile-time arity check, and String(format:) with too few arguments is
    /// undefined behaviour, so a mismatch is logged and the unformatted template is shown instead.
    static func format(_ key: Key, in lang: Language, _ args: [CVarArg]) -> String {
        let template = text(key, in: lang)
        let expected = placeholders(in: template).count
        guard expected == args.count else {
            log.error("L10n: \(String(describing: key), privacy: .public) expects \(expected) argument(s), got \(args.count)")
            return template
        }
        return String(format: template, arguments: args)  // no locale: pixel sizes stay "12000×9000"
    }

    private static let placeholderPattern = try! NSRegularExpression(  // constant pattern; a typo fails every test
        pattern: "%(?:\\d+\\$)?[-+ 0#]*\\d*(?:\\.\\d+)?(?:hh|h|ll|l|q|z|t|j|L)?[@dDiuUxXoOfFeEgGaAcCsSp%]")

    /// printf conversions in `s`, in order, excluding the escaped `%%`.
    static func placeholders(in s: String) -> [String] {
        placeholderPattern.matches(in: s, range: NSRange(s.startIndex..., in: s))
            .map { (s as NSString).substring(with: $0.range) }
            .filter { $0 != "%%" }
    }

    public enum Key: CaseIterable, Sendable {
        // window
        case openImageMenu, dropTitle, dropHint, dropZoneA11y
        case orientation, orientationAuto, landscape, portrait
        case layout, fill, fit
        case dither, rotate180, autoSend, clear, send
        case searching, connectedHelp, disconnected
        // status
        case dropPrompt, loading, fileUnavailable, droppedImage, imageDataUnavailable, imageFallbackName
        case converted, sending, shown, totalSuffix, clearing, cleared
        // errors
        case errTimeout, errDevice, errIO, errNotFound, errProtocol
        case unreadableFile, unreadableData, notAnImage, imageTooLarge, decodeFailed
        case portBusy, portDisconnected
    }

    public static func text(_ key: Key, in lang: Language) -> String {
        switch lang {
        case .en: return en(key)
        case .ja: return ja(key)
        case .zhHans: return zhHans(key)
        }
    }

    private static func en(_ key: Key) -> String {
        switch key {
        case .openImageMenu: "Open Image…"
        case .dropTitle: "Drop an image to show it on M5Paper"
        case .dropHint: "JPEG / PNG / HEIC / TIFF / GIF and more. Or choose one with ⌘O"
        case .dropZoneA11y: "Image drop area"
        case .orientation: "Orientation"
        case .orientationAuto: "Auto"
        case .landscape: "Landscape"
        case .portrait: "Portrait"
        case .layout: "Layout"
        case .fill: "Fill"
        case .fit: "Fit"
        case .dither: "Dither"
        case .rotate180: "Rotate 180°"
        case .autoSend: "Send on drop"
        case .clear: "Clear"
        case .send: "Send"
        case .searching: "Searching…"
        case .connectedHelp: "Connected to M5Paper: %@"
        case .disconnected: "Not connected (search again)"
        case .dropPrompt: "Drop an image here"
        case .loading: "Loading… %@"
        case .fileUnavailable: "Could not get the file"
        case .droppedImage: "Dropped image"
        case .imageDataUnavailable: "Could not get the image data"
        case .imageFallbackName: "Image"
        case .converted: "%@ → %ld×%ld, 16 gray levels"
        case .sending: "Sending…"
        case .shown: "Shown (refresh %.1f s)"
        case .totalSuffix: " · total %.1f s"
        case .clearing: "Clearing…"
        case .cleared: "Screen cleared"
        case .errTimeout: "Response timed out: %@"
        case .errDevice: "The device returned an error: %@"
        case .errIO: "Serial communication error: %@"
        case .errNotFound: "M5Paper (PaperDrop firmware) not found. Check the USB connection and that the firmware is flashed."
        case .errProtocol: "Unexpected response: %@"
        case .unreadableFile: "Cannot read the file: %@"
        case .unreadableData: "Cannot read the data: %@"
        case .notAnImage: "Not recognized as an image: %@"
        case .imageTooLarge: "Image is too large (%ld×%ld): %@"
        case .decodeFailed: "Failed to decode: %@"
        case .portBusy: "%@ is in use by another app"
        case .portDisconnected: "%@ was disconnected"
        }
    }

    private static func ja(_ key: Key) -> String {
        switch key {
        case .openImageMenu: "画像を開く…"
        case .dropTitle: "画像をドロップすると M5Paper に表示します"
        case .dropHint: "JPEG / PNG / HEIC / TIFF / GIF など。⌘O でも選べます"
        case .dropZoneA11y: "画像のドロップ先"
        case .orientation: "向き"
        case .orientationAuto: "自動"
        case .landscape: "横"
        case .portrait: "縦"
        case .layout: "配置"
        case .fill: "全面"
        case .fit: "全体"
        case .dither: "ディザ"
        case .rotate180: "180°回転"
        case .autoSend: "ドロップで即送信"
        case .clear: "クリア"
        case .send: "送信"
        case .searching: "検索中…"
        case .connectedHelp: "M5Paper に接続中: %@"
        case .disconnected: "未接続（再検索）"
        case .dropPrompt: "画像をここにドロップしてください"
        case .loading: "読み込み中… %@"
        case .fileUnavailable: "ファイルを取得できませんでした"
        case .droppedImage: "ドロップされた画像"
        case .imageDataUnavailable: "画像データを取得できませんでした"
        case .imageFallbackName: "画像"
        case .converted: "%@ → %ld×%ld、16階調"
        case .sending: "送信中…"
        case .shown: "表示しました（描画 %.1f 秒）"
        case .totalSuffix: "　合計 %.1f 秒"
        case .clearing: "クリア中…"
        case .cleared: "画面をクリアしました"
        case .errTimeout: "応答タイムアウト: %@"
        case .errDevice: "デバイスがエラーを返しました: %@"
        case .errIO: "シリアル通信エラー: %@"
        case .errNotFound: "M5Paper（PaperDrop ファーム）が見つかりません。USB 接続とファームの書き込みを確認してください。"
        case .errProtocol: "想定外の応答: %@"
        case .unreadableFile: "読み込めないファイルです: %@"
        case .unreadableData: "読み込めないデータです: %@"
        case .notAnImage: "画像として認識できません: %@"
        case .imageTooLarge: "画像が大きすぎます（%ld×%ld）: %@"
        case .decodeFailed: "デコードに失敗しました: %@"
        case .portBusy: "%@ は他のアプリが使用中です"
        case .portDisconnected: "%@ が切断されました"
        }
    }

    private static func zhHans(_ key: Key) -> String {
        switch key {
        case .openImageMenu: "打开图像…"
        case .dropTitle: "拖入图像即可显示在 M5Paper 上"
        case .dropHint: "支持 JPEG / PNG / HEIC / TIFF / GIF 等格式，也可按 ⌘O 选择"
        case .dropZoneA11y: "图像拖放区域"
        case .orientation: "方向"
        case .orientationAuto: "自动"
        case .landscape: "横向"
        case .portrait: "纵向"
        case .layout: "布局"
        case .fill: "填满"
        case .fit: "适应"
        case .dither: "抖动"
        case .rotate180: "旋转 180°"
        case .autoSend: "拖入即发送"
        case .clear: "清屏"
        case .send: "发送"
        case .searching: "正在搜索…"
        case .connectedHelp: "已连接 M5Paper：%@"
        case .disconnected: "未连接（重新搜索）"
        case .dropPrompt: "请将图像拖到这里"
        case .loading: "正在读取… %@"
        case .fileUnavailable: "无法获取文件"
        case .droppedImage: "拖入的图像"
        case .imageDataUnavailable: "无法获取图像数据"
        case .imageFallbackName: "图像"
        case .converted: "%@ → %ld×%ld，16 级灰度"
        case .sending: "正在发送…"
        case .shown: "已显示（刷新 %.1f 秒）"
        case .totalSuffix: "，共 %.1f 秒"
        case .clearing: "正在清屏…"
        case .cleared: "已清屏"
        case .errTimeout: "响应超时：%@"
        case .errDevice: "设备返回错误：%@"
        case .errIO: "串口通信错误：%@"
        case .errNotFound: "未找到 M5Paper（PaperDrop 固件）。请检查 USB 连接以及固件是否已烧录。"
        case .errProtocol: "收到意外响应：%@"
        case .unreadableFile: "无法读取文件：%@"
        case .unreadableData: "无法读取数据：%@"
        case .notAnImage: "无法识别为图像：%@"
        case .imageTooLarge: "图像过大（%ld×%ld）：%@"
        case .decodeFailed: "解码失败：%@"
        case .portBusy: "%@ 正被其他应用占用"
        case .portDisconnected: "%@ 已断开连接"
        }
    }
}
