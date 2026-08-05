import XCTest
@testable import baaackaaab

// `--log-tail` is the path an operator reaches for when a backup is broken, so its
// arithmetic must not be the thing that fails: a log ending in a newline (every
// well-formed one) must not spend the last requested line on the empty string
// after it.
final class LogTailTests: XCTestCase {

    func testTrailingNewlineDoesNotConsumeALine() {
        XCTAssertEqual(LogTail.tail("a\nb\nc\n", lines: 1), ["c"])
        XCTAssertEqual(LogTail.tail("a\nb\nc\n", lines: 2), ["b", "c"])
    }

    func testWithoutTrailingNewline() {
        XCTAssertEqual(LogTail.tail("a\nb\nc", lines: 2), ["b", "c"])
    }

    func testAsksForMoreThanExist() {
        XCTAssertEqual(LogTail.tail("a\nb\n", lines: 50), ["a", "b"])
    }

    func testEmptyAndZero() {
        XCTAssertEqual(LogTail.tail("", lines: 10), [])
        XCTAssertEqual(LogTail.tail("a\nb\n", lines: 0), [])
    }

    func testBlankLinesInsideAreKept() {
        // Blank lines separate the sections of a run in the real log — dropping them
        // would silently reflow what the operator sees.
        XCTAssertEqual(LogTail.tail("a\n\nb\n", lines: 3), ["a", "", "b"])
    }
}
