import Foundation
#if canImport(IOKit)
import IOKit.pwr_mgt
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
