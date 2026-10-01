import XCTest
@testable import baaackaaab

// `Notifier.escape` guards the one human-visible signal an unattended failure
// gets: the string is embedded in an AppleScript double-quoted literal, so an
// unescaped quote would break out of it and an unescaped newline would fail the
// osascript compile — both silently dropping the banner.
final class NotifierEscapeTests: XCTestCase {

    func testEscapesQuotesAndBackslashes() {
        XCTAssertEqual(Notifier.escape(#"say "hi""#), #"say \"hi\""#)
        // Backslash first, so existing backslashes don't double-escape quotes.
        XCTAssertEqual(Notifier.escape(#"a\b"#), #"a\\b"#)
        XCTAssertEqual(Notifier.escape(#"\""#), #"\\\""#)
    }

    func testEscapesNewlinesAndCarriageReturns() {
        XCTAssertEqual(Notifier.escape("line1\nline2"), #"line1\nline2"#)
        XCTAssertEqual(Notifier.escape("a\r\nb"), #"a\r\nb"#)
    }

    // U+2028/U+2029 are line breaks to many parsers; AppleScript has no \u
    // escape, so they map to the escaped \n form instead of riding through raw.
    func testEscapesUnicodeLineAndParagraphSeparators() {
        XCTAssertEqual(Notifier.escape("a\u{2028}b\u{2029}c"), #"a\nb\nc"#)
    }

    func testPlainMessagePassesThrough() {
        XCTAssertEqual(Notifier.escape("backup failed: 3/5 verified"),
                       "backup failed: 3/5 verified")
    }
}
