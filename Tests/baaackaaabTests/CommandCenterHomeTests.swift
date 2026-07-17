import XCTest
@testable import baaackaaab

// homeStatusSummary is the dashboard's one-line-per-destination summary; these
// pin the "oldest <age>" segment added on top of the existing snapshot-count /
// size / per-source-latest parts. ConfigTUI's init only loads a (possibly
// nonexistent) backup set from disk — no TTY/termios touched — so it is safe
// to instantiate directly in a unit test.
final class CommandCenterHomeTests: XCTestCase {

    private func makeTUI() -> ConfigTUI {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("baaackaaab-cc-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("backup-set.json")
        return ConfigTUI(configPath: path)
    }

    func testHomeStatusSummaryAppendsOldestAge() {
        let tui = makeTUI()
        var status = ResticBackend.RemoteStatus()
        status.snapshotCount = 3
        status.oldestTime = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3 * 86_400))
        let line = tui.homeStatusSummary(status)
        XCTAssertTrue(line.contains("oldest 3d ago"), line)
    }

    func testHomeStatusSummaryOmitsOldestWhenAbsent() {
        let tui = makeTUI()
        var status = ResticBackend.RemoteStatus()
        status.snapshotCount = 0
        let line = tui.homeStatusSummary(status)
        XCTAssertFalse(line.contains("oldest"), line)
    }

    // MARK: - parseResticTime

    func testParseResticTimeHandlesResticsHighPrecisionFractionalSeconds() {
        let tui = makeTUI()
        // The exact shape restic's `find --json` / `snapshots --json` emit:
        // nanosecond-precision fractional seconds, which ISO8601DateFormatter
        // cannot parse directly.
        let date = tui.parseResticTime("2026-07-17T19:58:13.038282390+02:00")
        XCTAssertNotNil(date)
    }

    func testParseResticTimeHandlesNoFractionalSeconds() {
        let tui = makeTUI()
        XCTAssertNotNil(tui.parseResticTime("2026-07-17T19:58:13+02:00"))
    }

    func testParseResticTimeRejectsGarbage() {
        let tui = makeTUI()
        XCTAssertNil(tui.parseResticTime("not-a-date"))
        XCTAssertNil(tui.parseResticTime(""))
    }
}
