import XCTest
@testable import baaackaaab

// The folder-selection storage logic: tilde-relative keys, selection lookup and
// the ancestor "partial" marker. These decide WHAT gets backed up — a silent
// regression here changes the backup set without any error.
final class SetEditorTests: XCTestCase {

    private func tui() -> ConfigTUI {
        ConfigTUI(configPath: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("baaackaaab-seteditor-\(UUID().uuidString).json"))
    }

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    func testTildePathContractsHomeAndKeepsOutsidePathsAbsolute() {
        let t = tui()
        XCTAssertEqual(t.tildePath(of: home), "~")
        XCTAssertEqual(t.tildePath(of: home.appendingPathComponent("Documents/x")), "~/Documents/x")
        XCTAssertEqual(t.tildePath(of: URL(fileURLWithPath: "/Volumes/Ext/data")), "/Volumes/Ext/data")
        // A sibling dir sharing the home PREFIX must not be contracted.
        let sibling = home.path + "2/x"
        XCTAssertEqual(t.tildePath(of: URL(fileURLWithPath: sibling)), sibling)
    }

    func testExpandPathIsInverseOfTildePath() {
        let t = tui()
        for url in [home,
                    home.appendingPathComponent("Documents/Projekte"),
                    URL(fileURLWithPath: "/Volumes/Ext/data")] {
            XCTAssertEqual(t.expandPath(t.tildePath(of: url)), url.path)
        }
    }

    func testToggleAddsThenRemoves() {
        let t = tui()
        let url = home.appendingPathComponent("Documents/x")
        XCTAssertFalse(t.isSelected(url))
        t.toggle(url)
        XCTAssertTrue(t.isSelected(url))
        XCTAssertTrue(t.dirty)
        t.toggle(url)
        XCTAssertFalse(t.isSelected(url))
    }

    // Selection stored tilde-relative must also be found via the absolute URL.
    func testIsSelectedMatchesTildeAndAbsoluteForms() {
        let t = tui()
        _ = t.set.addFolder("~/Documents/x")
        XCTAssertTrue(t.isSelected(home.appendingPathComponent("Documents/x")))
    }

    func testDirStateBubblesPartialUpTheTree() {
        let t = tui()
        _ = t.set.addFolder("~/Documents/deep/branch")
        XCTAssertEqual(t.dirState(home.appendingPathComponent("Documents")), .partial)
        XCTAssertEqual(t.dirState(home.appendingPathComponent("Documents/deep/branch")), .selected)
        XCTAssertEqual(t.dirState(home.appendingPathComponent("Music")), DirState.none)
        // A PREFIX sibling ("DocumentsOld") is not an ancestor.
        XCTAssertEqual(t.dirState(home.appendingPathComponent("Document")), DirState.none)
    }
}
