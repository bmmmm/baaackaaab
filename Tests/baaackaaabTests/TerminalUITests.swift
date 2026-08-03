import XCTest
@testable import baaackaaab

// The hand-rolled terminal byte parser and the wcwidth-subset math — the most
// bug-sensitive pure logic in the TUI layer, previously untested. Keys are
// decoded from an injected `inbuf` (no real tty involved); a burst must decode
// byte-exactly, and the width functions guard the column layout for
// user-controlled CJK/emoji folder and album names.
final class TerminalUITests: XCTestCase {

    private func tui() -> ConfigTUI {
        ConfigTUI(configPath: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("baaackaaab-tui-\(UUID().uuidString).json"))
    }

    private func keys(_ bytes: [UInt8], count: Int) -> [Key] {
        let t = tui()
        t.inbuf = bytes
        t.inpos = 0
        return (0..<count).map { _ in t.readKey() }
    }

    // MARK: - key decoding

    func testArrowSequencesDecode() {
        XCTAssertEqual(keys([0x1B, 0x5B, 0x41], count: 1), [.up])
        XCTAssertEqual(keys([0x1B, 0x5B, 0x42], count: 1), [.down])
        XCTAssertEqual(keys([0x1B, 0x5B, 0x43], count: 1), [.right])
        XCTAssertEqual(keys([0x1B, 0x5B, 0x44], count: 1), [.left])
    }

    func testControlKeysDecode() {
        XCTAssertEqual(keys([0x0D], count: 1), [.enter])
        XCTAssertEqual(keys([0x0A], count: 1), [.enter])
        XCTAssertEqual(keys([0x20], count: 1), [.space])
        XCTAssertEqual(keys([0x7F], count: 1), [.backspace])
        XCTAssertEqual(keys([0x08], count: 1), [.backspace])
        XCTAssertEqual(keys([0x09], count: 1), [.tab])
        XCTAssertEqual(keys([0x03], count: 1), [.ctrlC])
        XCTAssertEqual(keys([UInt8(ascii: "q")], count: 1), [.char("q")])
    }

    // A held key / paste arrives as one burst; one key is parsed per call and
    // the rest kept — no keystroke may be dropped.
    func testBurstDecodesSequentially() {
        XCTAssertEqual(keys([UInt8(ascii: "a"), 0x1B, 0x5B, 0x42, UInt8(ascii: "b")], count: 3),
                       [.char("a"), .down, .char("b")])
    }

    // An unknown CSI final byte must swallow the sequence as .other, not leak
    // its bytes into later reads.
    func testUnknownEscapeSequenceIsOther() {
        XCTAssertEqual(keys([0x1B, 0x5B, 0x5A, UInt8(ascii: "x")], count: 2),
                       [.other, .char("x")])
    }

    // A lone ESC with the burst already exhausted takes the grace path (a ~30ms
    // poll on stdin, which has no data under the test runner) and must land on
    // .esc — never block forever, never misread as an arrow.
    func testLoneEscDecodesAsEsc() {
        XCTAssertEqual(keys([0x1B], count: 1), [.esc])
    }

    // MARK: - width math (wcwidth subset)

    func testDisplayWidthAsciiAndCJKAndEmoji() {
        let t = tui()
        XCTAssertEqual(t.displayWidth("abc"), 3)
        XCTAssertEqual(t.displayWidth("写真"), 4)          // CJK: 2 cells each
        XCTAssertEqual(t.displayWidth("👍"), 2)            // emoji: 2 cells
        XCTAssertEqual(t.displayWidth("e\u{0301}"), 1)     // combining mark: still 1
        XCTAssertEqual(t.displayWidth("👨\u{200D}👩\u{200D}👧"), 2)  // ZWJ family collapses to 2
    }

    func testFitTruncatesOnCellBoundaryWithEllipsis() {
        let t = tui()
        XCTAssertEqual(t.fit("abcdef", 4), "abc\u{2026}")
        // A wide char that would straddle the boundary is dropped, not halved.
        XCTAssertEqual(t.fit("写真集写真", 5), "写真\u{2026}")
        XCTAssertEqual(t.fit("abc", 3), "abc")   // fits exactly — untouched
        XCTAssertEqual(t.fit("abc", 1), "\u{2026}")
        XCTAssertEqual(t.fit("abc", 0), "")
    }

    func testPadToWidthCountsCellsNotGraphemes() {
        let t = tui()
        XCTAssertEqual(t.padToWidth("写", 4), "写  ")   // 2 cells + 2 spaces
        XCTAssertEqual(t.padToWidth("ab", 2), "ab")
        XCTAssertEqual(t.padToWidth("abc", 2), "abc")  // never truncates
    }

    // MARK: - list arithmetic

    func testClampBounds() {
        let t = tui()
        var v = 7
        t.clamp(&v, 5)
        XCTAssertEqual(v, 4)
        v = -2
        t.clamp(&v, 5)
        XCTAssertEqual(v, 0)
        v = 3
        t.clamp(&v, 0)
        XCTAssertEqual(v, 0)   // empty list pins to 0
    }
}
