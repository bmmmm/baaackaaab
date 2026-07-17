import XCTest
@testable import baaackaaab

// Argument parsing is pure (an instance is built from an explicit token list, not
// the process argv), so the whole surface is unit-testable. The two exit(1)-on-
// error helpers (`positiveInt`, `schedule`) are intentionally NOT exercised here:
// they terminate the process on a bad value, which would kill the test runner.
final class CLIArgumentsTests: XCTestCase {

    func testValueReturnsTokenAfterFlag() {
        let cli = CLIArguments(tokens: ["--at", "09:00", "--days", "mon"])
        XCTAssertEqual(cli.value("--at"), "09:00")
        XCTAssertEqual(cli.value("--days"), "mon")
    }

    func testValueFallsBackWhenFlagAbsentOrTrailing() {
        let cli = CLIArguments(tokens: ["--at"])           // flag is the last token
        XCTAssertNil(cli.value("--at"))                    // nothing follows it
        XCTAssertNil(cli.value("--missing"))
        XCTAssertEqual(cli.value("--missing", default: "x"), "x")
    }

    func testValuesCollectsEveryRepeat() {
        let cli = CLIArguments(tokens: ["--drive-folder", "a", "--drive-folder", "b", "--at", "1"])
        XCTAssertEqual(cli.values("--drive-folder"), ["a", "b"])
        XCTAssertEqual(cli.values("--none"), [])
    }

    func testValuesIgnoresATrailingFlagWithNoValue() {
        let cli = CLIArguments(tokens: ["--x", "1", "--x"])  // second --x has no value
        XCTAssertEqual(cli.values("--x"), ["1"])
    }

    func testPairReturnsTwoFollowingTokens() {
        let cli = CLIArguments(tokens: ["--diff", "aaaa", "bbbb"])
        let p = cli.pair("--diff")
        XCTAssertEqual(p?.0, "aaaa")
        XCTAssertEqual(p?.1, "bbbb")
    }

    func testPairNilWhenFewerThanTwoFollow() {
        XCTAssertNil(CLIArguments(tokens: ["--diff", "only"]).pair("--diff"))
        XCTAssertNil(CLIArguments(tokens: ["--diff"]).pair("--diff"))
    }

    func testHasAndHasAnyAndCount() {
        let cli = CLIArguments(tokens: ["--check", "--verbose"])
        XCTAssertTrue(cli.has("--check"))
        XCTAssertFalse(cli.has("--restore"))
        XCTAssertTrue(cli.hasAny(["--restore", "--verbose"]))
        XCTAssertFalse(cli.hasAny(["--restore", "--snapshots"]))
        XCTAssertEqual(cli.count, 2)
    }

    // MARK: - parseAtTime

    func testParseAtTimeAcceptsValid24Hour() {
        XCTAssertEqual(CLIArguments.parseAtTime("00:00").map { [$0.hour, $0.minute] }, [0, 0])
        XCTAssertEqual(CLIArguments.parseAtTime("09:05").map { [$0.hour, $0.minute] }, [9, 5])
        XCTAssertEqual(CLIArguments.parseAtTime("23:59").map { [$0.hour, $0.minute] }, [23, 59])
    }

    func testParseAtTimeRejectsOutOfRangeAndMalformed() {
        XCTAssertNil(CLIArguments.parseAtTime("24:00"))   // hour overflow
        XCTAssertNil(CLIArguments.parseAtTime("12:60"))   // minute overflow
        XCTAssertNil(CLIArguments.parseAtTime("12"))      // no colon
        XCTAssertNil(CLIArguments.parseAtTime("ab:cd"))   // non-numeric
        XCTAssertNil(CLIArguments.parseAtTime(""))
        XCTAssertNil(CLIArguments.parseAtTime("-1:00"))
    }

    // MARK: - parseDays

    func testParseDaysMapsWeekdaysToLaunchdNumbers() {
        let (days, unknown) = CLIArguments.parseDays("mon,wed,fri")
        XCTAssertEqual(days, [1, 3, 5])      // Sun=0 … Sat=6
        XCTAssertTrue(unknown.isEmpty)
    }

    func testParseDaysIsCaseAndWhitespaceTolerantAndDedups() {
        let (days, unknown) = CLIArguments.parseDays("Mon, MONDAY tue")  // prefix match + dup
        XCTAssertEqual(days, [1, 2])
        XCTAssertTrue(unknown.isEmpty)
    }

    func testParseDaysEmptyMeansEveryDay() {
        XCTAssertEqual(CLIArguments.parseDays(nil).days, [])
        XCTAssertEqual(CLIArguments.parseDays("").days, [])
    }

    func testParseDaysReportsUnknownTokens() {
        // Matching is on the first 3 letters, so a real typo only fails when its
        // prefix doesn't collide with a weekday ("xyz", not "saturdy"→"sat").
        let (days, unknown) = CLIArguments.parseDays("mon,xyzzy,fri")
        XCTAssertEqual(days, [1, 5])
        XCTAssertEqual(unknown, ["xyzzy"])
    }

    // MARK: - unknownArgument (the typo guard before the backup dispatch)

    /// argv[0] is always present and ignored; a bare invocation is accepted.
    func testUnknownArgumentAcceptsBareAndKnownFlags() {
        XCTAssertNil(CLIArguments.unknownArgument(in: ["baaackaaab"]))
        XCTAssertNil(CLIArguments.unknownArgument(in: ["baaackaaab", "--check"]))
        XCTAssertNil(CLIArguments.unknownArgument(in: ["baaackaaab", "--snapshots"]))
        XCTAssertNil(CLIArguments.unknownArgument(in: ["baaackaaab", "--doctor"]))
        XCTAssertNil(CLIArguments.unknownArgument(in: ["baaackaaab", "--check-updates"]))
    }

    /// The regression: a bare word (e.g. `check` typed for `--check`) must be
    /// rejected, not silently fall through the dispatch to a full backup.
    func testUnknownArgumentRejectsBarePositional() {
        let msg = CLIArguments.unknownArgument(in: ["baaackaaab", "check"])
        XCTAssertNotNil(msg)
        XCTAssertTrue(msg?.contains("--check") ?? false, "should suggest the flag form")
        XCTAssertNotNil(CLIArguments.unknownArgument(in: ["baaackaaab", "snapshots"]))
        XCTAssertNotNil(CLIArguments.unknownArgument(in: ["baaackaaab", "doctor"]))
    }

    /// A bare word with no matching flag is still rejected, just without a suggestion.
    func testUnknownArgumentRejectsBareWordWithoutSuggestion() {
        let msg = CLIArguments.unknownArgument(in: ["baaackaaab", "wat"])
        XCTAssertNotNil(msg)
        XCTAssertFalse(msg?.contains("did you mean") ?? true)
    }

    func testUnknownArgumentRejectsMistypedFlag() {
        XCTAssertNotNil(CLIArguments.unknownArgument(in: ["baaackaaab", "--snapshtos"]))
        XCTAssertNotNil(CLIArguments.unknownArgument(in: ["baaackaaab", "--docktor"]))
    }

    // MARK: - --rest-connections (persist + clear)

    /// `--rest-connections <n>` and `--clear-rest-connections` mirror the
    /// pack-size / repo-quota persistent knobs: a value flag and a standalone
    /// clear flag, both recognized (not rejected as an unknown argument), with
    /// the value reachable through `value(_:)`.
    func testRestConnectionsFlagsAreRecognizedAndParsed() {
        XCTAssertNil(CLIArguments.unknownArgument(in: ["baaackaaab", "--rest-connections", "2"]))
        XCTAssertNil(CLIArguments.unknownArgument(in: ["baaackaaab", "--clear-rest-connections"]))
        XCTAssertEqual(CLIArguments(tokens: ["--rest-connections", "2"]).value("--rest-connections"), "2")
        XCTAssertTrue(CLIArguments(tokens: ["--clear-rest-connections"]).has("--clear-rest-connections"))
    }

    // MARK: - --read-concurrency (persist + clear)

    /// `--read-concurrency <n>` and `--clear-read-concurrency` mirror the
    /// rest-connections / pack-size persistent knobs: a value flag and a
    /// standalone clear flag, both recognized, with the value reachable
    /// through `value(_:)`.
    func testReadConcurrencyFlagsAreRecognizedAndParsed() {
        XCTAssertNil(CLIArguments.unknownArgument(in: ["baaackaaab", "--read-concurrency", "4"]))
        XCTAssertNil(CLIArguments.unknownArgument(in: ["baaackaaab", "--clear-read-concurrency"]))
        XCTAssertEqual(CLIArguments(tokens: ["--read-concurrency", "4"]).value("--read-concurrency"), "4")
        XCTAssertTrue(CLIArguments(tokens: ["--clear-read-concurrency"]).has("--clear-read-concurrency"))
    }

    // MARK: - --history

    /// `--history <path>` is a value flag like --find, recognized (not rejected
    /// as unknown) with its value reachable through `value(_:)`.
    func testHistoryFlagIsRecognizedAndParsed() {
        XCTAssertNil(CLIArguments.unknownArgument(in: ["baaackaaab", "--history", "report.pdf"]))
        XCTAssertEqual(CLIArguments(tokens: ["--history", "report.pdf"]).value("--history"), "report.pdf")
    }

    // MARK: - Monitoring & notification flags

    /// The heartbeat/notify flags mirror the exclude-glob shape: repeatable value
    /// flags (--set-heartbeat, --add-ntfy, --add-webhook, --remove-notify) plus a
    /// standalone clear flag and a standalone test flag.
    func testMonitoringFlagsAreRecognizedAndParsed() {
        XCTAssertNil(CLIArguments.unknownArgument(in: ["baaackaaab", "--set-heartbeat", "https://hc-ping.com/uuid"]))
        XCTAssertNil(CLIArguments.unknownArgument(in: ["baaackaaab", "--clear-heartbeat"]))
        XCTAssertNil(CLIArguments.unknownArgument(in: ["baaackaaab", "--add-ntfy", "https://ntfy.sh/topic"]))
        XCTAssertNil(CLIArguments.unknownArgument(in: ["baaackaaab", "--add-webhook", "https://example.com/hook"]))
        XCTAssertNil(CLIArguments.unknownArgument(in: ["baaackaaab", "--remove-notify", "https://ntfy.sh/topic"]))
        XCTAssertNil(CLIArguments.unknownArgument(in: ["baaackaaab", "--test-notify"]))
        XCTAssertEqual(CLIArguments(tokens: ["--set-heartbeat", "https://hc-ping.com/uuid"]).value("--set-heartbeat"),
                       "https://hc-ping.com/uuid")
        XCTAssertTrue(CLIArguments(tokens: ["--test-notify"]).has("--test-notify"))
    }

    // MARK: - Slice F flags (integrity check, catch-up, battery-defer)

    /// The new standalone flags must be recognized (not rejected as unknown
    /// arguments), so the dispatch reaches their handlers instead of falling
    /// through to a backup.
    func testSliceFFlagsAreRecognized() {
        for flag in ["--rotate-read-data", "--install-check-timer", "--uninstall-check-timer",
                     "--catch-up", "--defer-on-battery", "--no-defer-on-battery"] {
            XCTAssertNil(CLIArguments.unknownArgument(in: ["baaackaaab", flag]),
                         "\(flag) should be a recognized flag")
            XCTAssertTrue(CLIArguments(tokens: [flag]).has(flag))
        }
    }

    /// --rotate-read-data pairs with --verify-repo and both parse together.
    func testVerifyRepoWithRotateReadDataParses() {
        XCTAssertNil(CLIArguments.unknownArgument(in: ["baaackaaab", "--verify-repo", "--rotate-read-data"]))
        let cli = CLIArguments(tokens: ["--verify-repo", "--rotate-read-data"])
        XCTAssertTrue(cli.has("--verify-repo"))
        XCTAssertTrue(cli.has("--rotate-read-data"))
    }

    // MARK: - --export-recovery-kit / --export-recovery-kit-plain

    func testRecoveryKitFlagsAreRecognizedAndParsed() {
        XCTAssertNil(CLIArguments.unknownArgument(in: ["baaackaaab", "--export-recovery-kit", "~/Desktop/kit.md.enc"]))
        XCTAssertNil(CLIArguments.unknownArgument(in: ["baaackaaab", "--export-recovery-kit-plain", "~/Desktop/kit.md"]))
        XCTAssertEqual(CLIArguments(tokens: ["--export-recovery-kit", "/x/kit.enc"]).value("--export-recovery-kit"), "/x/kit.enc")
    }

    // MARK: - --repo-usage

    func testRepoUsageFlagIsRecognizedAndComposesWithDestination() {
        XCTAssertNil(CLIArguments.unknownArgument(in: ["baaackaaab", "--repo-usage"]))
        XCTAssertNil(CLIArguments.unknownArgument(in: ["baaackaaab", "--repo-usage", "--destination", "offsite"]))
        let cli = CLIArguments(tokens: ["--repo-usage", "--destination", "offsite"])
        XCTAssertTrue(cli.has("--repo-usage"))
        XCTAssertEqual(cli.value("--destination"), "offsite")
    }

    // MARK: - --large-file-warn-mib / --clear-large-file-warn-mib

    func testLargeFileWarnFlagsAreRecognizedAndParsed() {
        XCTAssertNil(CLIArguments.unknownArgument(in: ["baaackaaab", "--large-file-warn-mib", "8192"]))
        XCTAssertNil(CLIArguments.unknownArgument(in: ["baaackaaab", "--clear-large-file-warn-mib"]))
        XCTAssertEqual(CLIArguments(tokens: ["--large-file-warn-mib", "0"]).value("--large-file-warn-mib"), "0")
        XCTAssertTrue(CLIArguments(tokens: ["--clear-large-file-warn-mib"]).has("--clear-large-file-warn-mib"))
    }

    /// A flag value may legitimately start with '-' or look like a bare word — it
    /// is consumed by its flag, never checked. `--diff` consumes two.
    func testUnknownArgumentSkipsFlagValues() {
        XCTAssertNil(CLIArguments.unknownArgument(in: ["baaackaaab", "--find", "-x"]))
        XCTAssertNil(CLIArguments.unknownArgument(in: ["baaackaaab", "--restic-repo", "rest:https://h/r/"]))
        XCTAssertNil(CLIArguments.unknownArgument(in: ["baaackaaab", "--diff", "aaaa", "bbbb"]))
        // The value after --include can be any path word; it must not be read as a positional.
        XCTAssertNil(CLIArguments.unknownArgument(in: ["baaackaaab", "--restore", "--include", "report.pdf"]))
    }
}
