import XCTest
@testable import baaackaaab

// `Staging.sanitize` turns user-controlled strings (Photos asset ids contain
// "/", original filenames are arbitrary) into staging path components. If it
// ever lets a separator or a dot-name through, a staged file escapes or
// collapses its asset directory — path safety, so every rule is pinned.
final class StagingSanitizeTests: XCTestCase {

    func testReplacesPathSeparatorsAndColons() {
        XCTAssertEqual(Staging.sanitize("a/b\\c:d"), "a_b_c_d")
        // The typical PhotoKit asset id shape: UUID/L0/001.
        XCTAssertEqual(Staging.sanitize("A1B2/L0/001"), "A1B2_L0_001")
    }

    func testNeutralizesDotNamesAndEmpty() {
        XCTAssertEqual(Staging.sanitize(""), "_")
        XCTAssertEqual(Staging.sanitize("."), "_")
        XCTAssertEqual(Staging.sanitize(".."), "__")
    }

    func testDotDotWithSeparatorCannotEscape() {
        // "../x" must not survive as a traversal: the separator is replaced, so
        // the result is one harmless component.
        XCTAssertEqual(Staging.sanitize("../x"), ".._x")
        XCTAssertFalse(Staging.sanitize("../../etc/passwd").contains("/"))
    }

    func testOrdinaryFilenamePassesThrough() {
        XCTAssertEqual(Staging.sanitize("IMG_0042.HEIC"), "IMG_0042.HEIC")
    }
}
