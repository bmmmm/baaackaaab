import XCTest
@testable import baaackaaab

// The schedules section answers "what runs unattended, and when". Its riskiest
// claim is the quiet one: a job whose plist exists but which launchd never loaded
// looks scheduled everywhere else and silently never fires. These pin that it is
// called out rather than rendered as healthy.
final class ScheduleDashboardTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_785_000_000)   // fixed, so countdowns are exact

    private func daily(_ hour: Int) -> Schedule {
        Schedule(times: [(hour: hour, minute: 0)], weekdays: [])
    }

    func testNotInstalledReadsAsNotScheduled() {
        let (level, text) = ScheduleDashboard.row(kind: .check, installed: false, loaded: false,
                                                  schedule: nil, now: now)
        XCTAssertEqual(level, .none)
        XCTAssertTrue(text.contains("not scheduled"), text)
        XCTAssertTrue(text.contains("integrity check"), text)
    }

    func testInstalledAndLoadedShowsCadenceAndNextRun() {
        let (level, text) = ScheduleDashboard.row(kind: .backup, installed: true, loaded: true,
                                                  schedule: daily(20), now: now)
        XCTAssertEqual(level, .ok)
        XCTAssertTrue(text.contains("daily at 20:00"), text)
        XCTAssertTrue(text.contains("next in"), text)
    }

    func testPlistPresentButNotLoadedIsFlaggedBroken() {
        // The silent-failure case: it is installed, so every listing shows it, but
        // launchd never loaded it and it will never fire.
        let (level, text) = ScheduleDashboard.row(kind: .backup, installed: true, loaded: false,
                                                  schedule: daily(20), now: now)
        XCTAssertEqual(level, .broken)
        XCTAssertTrue(text.contains("NOT loaded"), text)
    }

    func testUnreadableScheduleIsFlaggedRatherThanHidden() {
        let (level, text) = ScheduleDashboard.row(kind: .drill, installed: true, loaded: true,
                                                  schedule: nil, now: now)
        XCTAssertEqual(level, .broken)
        XCTAssertTrue(text.contains("unreadable"), text)
    }

    func testTitlesAreColumnAligned() {
        // Every row pads its title to the same width, so the cadence column lines up.
        let texts = LaunchdTimer.Kind.allCases.map {
            ScheduleDashboard.row(kind: $0, installed: true, loaded: true,
                                  schedule: daily(3), now: now).text
        }
        let cadenceColumns = texts.map { $0.range(of: "daily at")!.lowerBound.utf16Offset(in: $0) }
        XCTAssertEqual(Set(cadenceColumns).count, 1, "cadence column drifted: \(texts)")
    }

    func testCountdownUsesTheCoarsestUsefulUnit() {
        XCTAssertEqual(ScheduleDashboard.countdown(from: now, to: now.addingTimeInterval(90)), "in 1m")
        XCTAssertEqual(ScheduleDashboard.countdown(from: now, to: now.addingTimeInterval(3 * 3600)), "in 3h")
        XCTAssertEqual(ScheduleDashboard.countdown(from: now, to: now.addingTimeInterval(5 * 86_400)), "in 5d")
        // A schedule the clock has already overtaken must not render a negative wait.
        XCTAssertEqual(ScheduleDashboard.countdown(from: now, to: now.addingTimeInterval(-60)), "now")
    }

    // MARK: - Kind wiring

    func testEachKindMapsToItsOwnLabelAndFlags() {
        // A copy-paste slip here would point the drill's "delete" at the backup job.
        let labels = LaunchdTimer.Kind.allCases.map { $0.label }
        XCTAssertEqual(Set(labels).count, LaunchdTimer.Kind.allCases.count, "labels collide: \(labels)")
        let flags = LaunchdTimer.Kind.allCases.flatMap { [$0.installFlag, $0.uninstallFlag] }
        XCTAssertEqual(Set(flags).count, flags.count, "install/uninstall flags collide: \(flags)")
        XCTAssertEqual(LaunchdTimer.Kind.backup.label, LaunchdTimer.label)
        XCTAssertEqual(LaunchdTimer.Kind.check.label, LaunchdTimer.checkLabel)
        XCTAssertEqual(LaunchdTimer.Kind.drill.label, LaunchdTimer.drillLabel)
    }

    func testOnlyTheDrillIsMonthly() {
        XCTAssertTrue(LaunchdTimer.Kind.drill.isMonthly)
        XCTAssertFalse(LaunchdTimer.Kind.backup.isMonthly)
        XCTAssertFalse(LaunchdTimer.Kind.check.isMonthly)
    }
}
