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
