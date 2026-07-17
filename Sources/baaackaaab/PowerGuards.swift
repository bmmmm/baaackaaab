import Foundation
#if canImport(IOKit)
import IOKit.pwr_mgt
import IOKit.ps
#endif

/// A best-effort IOKit power assertion that prevents IDLE system sleep for as long
/// as it is held — taken for the duration of a real backup or a rotating integrity
/// check so a long unattended upload/re-read is not cut short by the idle-sleep
/// timer. Pure IOKit, no `caffeinate` child process.
///
/// Honest scope: this holds off IDLE sleep only. A lid close (or an explicit Sleep)
/// still sleeps the machine — the assertion type is PreventUserIdleSystemSleep, not
/// PreventSystemSleep. It is harmless outside a run, so it is always on with no knob.
/// The assertion is released explicitly via `release()` (and `deinit`); the kernel
/// also releases every assertion a process holds when it exits, which is the backstop
/// for the code paths that terminate via `exit()` without unwinding.
final class SleepHold {
    #if canImport(IOKit)
    private var id: IOPMAssertionID = IOPMAssertionID(0)
    private var held = false
    #endif

    /// Take the assertion with `reason` as its human-readable name (shown by
    /// `pmset -g assertions`). Silent no-op if the assertion can't be created.
    init(reason: String) {
        #if canImport(IOKit)
        var aid: IOPMAssertionID = IOPMAssertionID(0)
        let rc = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &aid)
        if rc == kIOReturnSuccess { id = aid; held = true }
        #endif
    }

    /// Release the assertion (idempotent). Safe to call more than once.
    func release() {
        #if canImport(IOKit)
        if held { IOPMAssertionRelease(id); held = false }
        #endif
    }

    deinit { release() }
}

/// Thin IOKit wrapper around the current power source. Untested (a bare syscall
/// bridge); the decision that consumes it, `ScheduledBackup.shouldDeferOnBattery`,
/// is the pure, unit-tested part.
enum PowerSource {
    /// True when the Mac is currently drawing from the battery (not AC / UPS).
    /// Fails safe: any inability to read the power state returns false (assume
    /// wall power), so a read glitch never defers a backup that should have run.
    static func onBattery() -> Bool {
        #if canImport(IOKit)
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(blob)?.takeRetainedValue() as String?
        else { return false }
        return type == kIOPSBatteryPowerValue
        #else
        return false
        #endif
    }
}

/// Pure decision for the opt-in battery-defer guard. Kept separate from the IOKit
/// read so it is unit-testable. A run defers ONLY when all three hold: it is a
/// scheduled/catch-up invocation (an interactive run always proceeds), the
/// `defer_on_battery` knob is set, and the Mac is actually on battery.
enum ScheduledBackup {
    static func shouldDeferOnBattery(isScheduled: Bool, deferConfigured: Bool, onBattery: Bool) -> Bool {
        isScheduled && deferConfigured && onBattery
    }
}
