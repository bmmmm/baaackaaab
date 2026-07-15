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

    func testPlainMessagePassesThrough() {
        XCTAssertEqual(Notifier.escape("backup failed: 3/5 verified"),
                       "backup failed: 3/5 verified")
    }
}
