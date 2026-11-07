import XCTest
@testable import PaperKit

/// Spec: the UI and error messages are available in English, Japanese and Simplified Chinese.
/// The language follows macOS's own choice among the app's localizations (so the app's
/// text matches the system-provided menus), falling back to English.
final class L10nTests: XCTestCase {
    func testLanguageFollowsPreferredLanguages() {
        XCTAssertEqual(L10n.resolve(["ja-JP"]), .ja)
        XCTAssertEqual(L10n.resolve(["en-US"]), .en)
        XCTAssertEqual(L10n.resolve(["en-GB"]), .en)
        XCTAssertEqual(L10n.resolve(["zh-Hans-CN"]), .zhHans)
        XCTAssertEqual(L10n.resolve(["zh-Hans"]), .zhHans)
    }

    func testFirstSupportedPreferenceWins() {
        XCTAssertEqual(L10n.resolve(["fr-FR", "ja-JP", "en-US"]), .ja)
        XCTAssertEqual(L10n.resolve(["zh-Hans-CN", "ja-JP"]), .zhHans)
    }

    func testUnsupportedOrEmptyPreferencesFallBackToEnglish() {
        XCTAssertEqual(L10n.resolve(["fr-FR"]), .en)
        XCTAssertEqual(L10n.resolve([]), .en)
        XCTAssertEqual(L10n.resolve(["JP"]), .en)
        XCTAssertEqual(L10n.resolve(["und"]), .en)
    }

    func testRegionVariantsMapToTheirLanguage() {
        XCTAssertEqual(L10n.resolve(["zh"]), .zhHans)
        XCTAssertEqual(L10n.resolve(["zh-CN"]), .zhHans)
        XCTAssertEqual(L10n.resolve(["en-JP"]), .en)
        XCTAssertEqual(L10n.resolve(["ja-US"]), .ja)
    }

    func testTraditionalChineseGetsEnglishLikeTheSystemMenus() {
        // The bundle has no zh-Hant.lproj, so AppKit shows its menus in English; follow it.
        XCTAssertEqual(L10n.resolve(["zh-Hant-TW"]), .en)
        XCTAssertEqual(L10n.resolve(["zh-TW"]), .en)
        XCTAssertEqual(L10n.resolve(["zh-HK"]), .en)
        XCTAssertEqual(L10n.resolve(["zh-Hant-TW", "ja-JP"]), .ja)
    }

    func testBundleIdentifiersMatchTheLprojFolders() throws {
        XCTAssertEqual(Language.allCases.map(\.rawValue), ["en", "ja", "zh-Hans"])
        // build_app.sh creates the .lproj folders and CFBundleLocalizations from LANGS
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../scripts/build_app.sh").standardized
        let text = try String(contentsOf: script, encoding: .utf8)
        let line = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("LANGS=(") })
        XCTAssertEqual(line.dropFirst("LANGS=(".count).dropLast().split(separator: " ").map(String.init),
                       Language.allCases.map(\.rawValue))
    }

    func testEveryKeyIsTranslatedWithTheSamePlaceholders() {
        for key in L10n.Key.allCases {
            let reference = placeholders(L10n.text(key, in: .en))
            for lang in Language.allCases {
                let s = L10n.text(key, in: lang)
                XCTAssertFalse(s.trimmingCharacters(in: .whitespaces).isEmpty, "\(key) is empty in \(lang)")
                XCTAssertEqual(placeholders(s), reference, "\(key) placeholders differ in \(lang): \(s)")
            }
        }
    }

    func testOnlyKnownPlaceholdersAreUsedAndNoStrayPercentRemains() {
        let allowed: Set = ["%@", "%ld", "%.1f"]
        for key in L10n.Key.allCases {
            for lang in Language.allCases {
                let s = L10n.text(key, in: lang)
                XCTAssertTrue(Set(placeholders(s)).isSubset(of: allowed), "\(key)/\(lang): \(s)")
                var rest = s
                for p in allowed { rest = rest.replacingOccurrences(of: p, with: "") }
                XCTAssertFalse(rest.contains("%"), "\(key)/\(lang) has a stray %: \(s)")
            }
        }
    }

    func testEveryKeyRendersInEveryLanguage() {
        for key in L10n.Key.allCases {
            let args: [CVarArg] = placeholders(L10n.text(key, in: .en)).map { p -> CVarArg in p == "%@" ? "X" : (p == "%.1f" ? 1.25 : 7) }
            for lang in Language.allCases {
                let s = L10n.format(key, in: lang, args)
                XCTAssertFalse(s.contains("%"), "\(key)/\(lang): \(s)")
            }
        }
    }

    func testJapaneseAndChineseAreActuallyTranslated() {
        // Every string carries words, so a copy of the English text means a missing translation.
        for key in L10n.Key.allCases {
            let en = L10n.text(key, in: .en)
            XCTAssertNotEqual(L10n.text(key, in: .ja), en, "\(key) not translated to ja")
            XCTAssertNotEqual(L10n.text(key, in: .zhHans), en, "\(key) not translated to zh-Hans")
        }
    }

    func testFormatSubstitutesArguments() {
        XCTAssertEqual(L10n.format(.imageTooLarge, in: .en, 12000, 9000, "a.png"), "Image is too large (12000×9000): a.png")
        XCTAssertEqual(L10n.format(.imageTooLarge, in: .ja, 12000, 9000, "a.png"), "画像が大きすぎます（12000×9000）: a.png")
        XCTAssertEqual(L10n.format(.shown, in: .en, 1.46), "Shown (refresh 1.5 s)")
    }

    func testWrongArgumentCountReturnsTheTemplateInsteadOfFormatting() {
        // String(format:) with too few arguments is undefined behaviour (garbage or a crash)
        XCTAssertEqual(L10n.format(.converted, in: .en, "a.png"), L10n.text(.converted, in: .en))
        XCTAssertEqual(L10n.format(.dropPrompt, in: .en, "extra"), L10n.text(.dropPrompt, in: .en))
    }

    func testPlaceholderScannerIgnoresEscapedPercent() {
        XCTAssertEqual(L10n.placeholders(in: "100%% %@ %.1f %ld %s"), ["%@", "%.1f", "%ld", "%s"])
    }

    func testErrorMessagesFollowTheRequestedLanguage() {
        XCTAssertTrue(PaperError.notFound.message(in: .en).contains("not found"))
        XCTAssertTrue(PaperError.notFound.message(in: .ja).contains("見つかりません"))
        XCTAssertTrue(PaperError.notFound.message(in: .zhHans).contains("未找到"))
        XCTAssertEqual(PaperError.timeout("waiting for READY").message(in: .en), "Response timed out: waiting for READY")
        XCTAssertEqual(PaperError.device("crc 1234").message(in: .zhHans), "设备返回错误：crc 1234")
        XCTAssertEqual(PaperError.image("already localized").message(in: .zhHans), "already localized")
    }

    func testErrorDescriptionUsesTheAppLanguage() {
        XCTAssertEqual(PaperError.notFound.errorDescription, PaperError.notFound.message(in: L10n.language))
    }

    func testImageLoadErrorsAreLocalized() {
        let url = URL(fileURLWithPath: "/nonexistent/nope.png")
        XCTAssertThrowsError(try ImageConverter.load(url: url)) { error in
            XCTAssertEqual(error as? PaperError, .image(L10n.format(.unreadableFile, in: L10n.language, "nope.png")))
        }
    }

    private func placeholders(_ s: String) -> [String] { L10n.placeholders(in: s) }
}
