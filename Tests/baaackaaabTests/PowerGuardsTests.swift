import XCTest
@testable import baaackaaab

// The battery-defer decision gates whether a scheduled run skips on battery. The
// IOKit power-source read and the sleep assertion are thin syscall wrappers (not
// unit-tested); the DECISION that consumes them is pure and fully pinned here —
// deferring when it shouldn't silently starves the backup; not deferring when it
// should drains the battery.
final class PowerGuardsTests: XCTestCase {

    func testDefersOnlyWhenAllThreeHold() {
        XCTAssertTrue(ScheduledBackup.shouldDeferOnBattery(
            isScheduled: true, deferConfigured: true, onBattery: true))
    }

    func testInteractiveRunNeverDefers() {
        // Not scheduled → always proceed, even configured + on battery.
        XCTAssertFalse(ScheduledBackup.shouldDeferOnBattery(
            isScheduled: false, deferConfigured: true, onBattery: true))
    }

    func testNotConfiguredNeverDefers() {
        XCTAssertFalse(ScheduledBackup.shouldDeferOnBattery(
            isScheduled: true, deferConfigured: false, onBattery: true))
    }

    func testOnWallPowerNeverDefers() {
        XCTAssertFalse(ScheduledBackup.shouldDeferOnBattery(
            isScheduled: true, deferConfigured: true, onBattery: false))
    }
}
