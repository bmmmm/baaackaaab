import Foundation

// Centralized console output for baaackaaab.
//
// Every line the tool prints goes through here so the look stays consistent
// and the color/glyph policy lives in exactly one place:
//   - ANSI color and Unicode glyphs are emitted ONLY when the target stream is
//     a TTY and NO_COLOR is unset. Redirected to a file or a launchd log, the
//     output degrades to clean ASCII with no escape codes.
//   - stdout for normal output, stderr for errors (styled red on a TTY).
//
// Pure Foundation, no dependencies. Nothing here buffers — main.swift sets
// stdout to line-buffered so our lines interleave with restic's child output.
enum Console {

    // MARK: - Capability detection

    /// Whether the given file descriptor is an interactive terminal and the
    /// user has not opted out of color via NO_COLOR (https://no-color.org).
    private static func styled(_ fd: Int32) -> Bool {
        if ProcessInfo.processInfo.environment["NO_COLOR"] != nil { return false }
        return isatty(fd) != 0
    }

    private static let stdoutStyled = styled(STDOUT_FILENO)
    private static let stderrStyled = styled(STDERR_FILENO)

    // MARK: - ANSI palette (restrained: bold, dim, three states, one accent)

    private enum SGR: String {
        case reset  = "\u{1B}[0m"
        case bold   = "\u{1B}[1m"
        case dim    = "\u{1B}[2m"
        case red    = "\u{1B}[31m"
        case green  = "\u{1B}[32m"
        case yellow = "\u{1B}[33m"
        case cyan   = "\u{1B}[36m"   // the single accent color
    }

    /// Wrap `text` in the given SGR codes, but only when `styled` is true.
    private static func paint(_ text: String, _ codes: [SGR], styled: Bool) -> String {
        guard styled, !codes.isEmpty else { return text }
        return codes.map(\.rawValue).joined() + text + SGR.reset.rawValue
    }

    // MARK: - Glyphs (degrade to ASCII words off a TTY)

    private static func glyph(_ unicode: String, plain: String, styled: Bool) -> String {
        styled ? unicode : plain
    }

    // MARK: - Low-level emit

    private static func out(_ line: String) {
        print(line)
    }

    private static func err(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    // MARK: - Header / banner

    /// Minimal bold banner: app name plus a one-line tagline. No ASCII art.
    static func banner(_ name: String, tagline: String) {
        out(paint(name, [.bold, .cyan], styled: stdoutStyled)
            + "  " + paint(tagline, [.dim], styled: stdoutStyled))
    }

    // MARK: - Sections

    /// Clean section header: an accent rule plus a bold title. Replaces the old
    /// `--- ... ---` markers. The optional `detail` is dimmed.
    static func section(_ title: String, detail: String? = nil) {
        let bar = glyph("\u{2502}", plain: "*", styled: stdoutStyled)   // │
        var line = "\n" + paint(bar, [.cyan], styled: stdoutStyled) + " "
            + paint(title, [.bold], styled: stdoutStyled)
        if let detail {
            line += "  " + paint(detail, [.dim], styled: stdoutStyled)
        }
        out(line)
    }

    /// A dimmed, indented note — used for "skipping" lines and asides.
    static func note(_ text: String) {
        out("  " + paint(text, [.dim], styled: stdoutStyled))
    }

    // MARK: - Steps (in-progress actions)

    /// In-progress action line: an accent arrow plus the message, indented.
    static func step(_ text: String) {
        let arrow = glyph("\u{2192}", plain: "->", styled: stdoutStyled)   // →
        out("  " + paint(arrow, [.cyan], styled: stdoutStyled) + " " + text)
    }

    /// A deeper-indented detail under a step (e.g. per-resource lines).
    static func detail(_ text: String) {
        let dot = glyph("\u{2022}", plain: "-", styled: stdoutStyled)   // •
        out("    " + paint(dot, [.dim], styled: stdoutStyled) + " " + text)
    }

    // MARK: - Status results

    static func success(_ text: String) {
        let mark = glyph("\u{2713}", plain: "[ok]", styled: stdoutStyled)   // ✓
        out("  " + paint(mark, [.green, .bold], styled: stdoutStyled) + " " + text)
    }

    static func warn(_ text: String) {
        let mark = glyph("\u{26A0}", plain: "[warn]", styled: stdoutStyled)   // ⚠
        out("  " + paint(mark, [.yellow, .bold], styled: stdoutStyled) + " "
            + paint(text, [.yellow], styled: stdoutStyled))
    }

    /// Failure on stdout (a non-fatal result within the normal flow).
    static func failure(_ text: String) {
        let mark = glyph("\u{2717}", plain: "[fail]", styled: stdoutStyled)   // ✗
        out("  " + paint(mark, [.red, .bold], styled: stdoutStyled) + " "
            + paint(text, [.red], styled: stdoutStyled))
    }

    /// Fatal error on stderr, styled red when stderr is a TTY.
    static func error(_ text: String) {
        let mark = glyph("\u{2717}", plain: "[err]", styled: stderrStyled)   // ✗
        err(paint(mark + " " + text, [.red, .bold], styled: stderrStyled))
    }

    // MARK: - Key / value info

    /// Aligned key/value lines: keys are padded to a common width and dimmed,
    /// values printed plain. Pass the whole set at once so widths line up.
    static func info(_ pairs: [(String, String)]) {
        let width = pairs.map(\.0.count).max() ?? 0
        for (key, value) in pairs {
            let padded = key.padding(toLength: width, withPad: " ", startingAt: 0)
            out("  " + paint(padded, [.dim], styled: stdoutStyled) + "  " + value)
        }
    }

    // MARK: - Summary block

    /// Tasteful final summary: a section rule, the headline status, then aligned
    /// key/value details. Minimal — no box art.
    static func summary(headline: String, state: SummaryState, details: [(String, String)]) {
        section("Summary")
        switch state {
        case .ok:   success(headline)
        case .warn: warn(headline)
        case .fail: failure(headline)
        }
        info(details)
    }

    enum SummaryState { case ok, warn, fail }
}
