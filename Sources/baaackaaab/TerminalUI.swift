import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum Key: Equatable {
    case up, down, left, right
    case enter, space, backspace, tab, esc, ctrlC, eof, other, resize
    case char(Character)
}

// Signal-safe terminal restore. A killed TUI (closing the terminal window sends
// SIGHUP, `kill` sends SIGTERM) must not leave the terminal in raw mode with the
// cursor hidden and the alternate screen still up — the next shell prompt would
// be unusable. The normal-exit path restores via `defer`, but a signal bypasses
// it, so we stash the cooked termios when raw mode is entered and install
// async-signal-safe handlers (tcsetattr / write / signal / raise are all
// async-signal-safe) that restore it and then re-raise with the default
// disposition so the exit status still reflects the signal.
// nonisolated(unsafe): these are reachable only from the async-signal-safe
// restore handler (and written once in RawTerminal.init before any handler can
// fire). A C signal handler can touch nothing but globals, so global mutable
// state is inherent here; the safety is the single-write-then-read-only ordering,
// which the compiler can't see — hence the explicit unsafe opt-out.
nonisolated(unsafe) var cookedTermForSignal = termios()
nonisolated(unsafe) var cookedTermValid = false
let ttyRestoreBytes: [UInt8] = Array("\u{1B}[?25h\u{1B}[?1049l".utf8)   // show cursor + leave alt screen

func ttyRestoreSignalHandler(_ signo: Int32) {
    if cookedTermValid {
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &cookedTermForSignal)
    }
    ttyRestoreBytes.withUnsafeBytes { raw in
        _ = write(STDOUT_FILENO, raw.baseAddress, raw.count)
    }
    signal(signo, SIG_DFL)
    raise(signo)
}

// SIGWINCH (terminal resize) sets this flag from the async handler; the run loop
// consumes it to re-render at the new size. sig_atomic_t is the only type the
// handler may safely touch.
// nonisolated(unsafe): sig_atomic_t is the one type a signal handler may set;
// the handler writes it and the run loop reads/clears it. The atomicity is the
// safety guarantee (that is what sig_atomic_t is for), so the unsafe opt-out is
// accurate — there is no data race to fix, only a proof the compiler can't make.
nonisolated(unsafe) var winchPending: sig_atomic_t = 0
func winchSignalHandler(_ signo: Int32) { winchPending = 1 }

/// RAII wrapper around the terminal's raw mode. cfmakeraw() turns off echo,
/// canonical line buffering, signal generation (so Ctrl-C arrives as a byte we
/// handle) and output post-processing — we position the cursor absolutely, so
/// we never depend on newline translation.
final class RawTerminal {
    var original = termios()
    var raw = termios()

    init?() {
        guard isatty(STDIN_FILENO) != 0 else { return nil }
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return nil }
        raw = original
        cfmakeraw(&raw)
        // Make the cooked state reachable from the async signal handlers.
        cookedTermForSignal = original
        cookedTermValid = true
        enable()
    }

    func enable() { var r = raw; tcsetattr(STDIN_FILENO, TCSAFLUSH, &r) }
    func restore() { var o = original; tcsetattr(STDIN_FILENO, TCSAFLUSH, &o) }
}

extension ConfigTUI {
    // MARK: - Terminal primitives

    func draw(_ lines: [String]) {
        var o = "\u{1B}[H"
        for (i, line) in lines.enumerated() {
            o += "\u{1B}[\(i + 1);1H\u{1B}[2K" + line
        }
        o += "\u{1B}[0m\u{1B}[J"
        emit(o)
    }

    func drawPrompt(_ msg: String) {
        let (rows, cols) = terminalSize()
        emit("\u{1B}[\(rows);1H\u{1B}[2K" + rev(fit(msg, cols)))
    }

    /// A full-width horizontal rule with a leading label, padded to exactly
    /// `cols` so it reads as a section break (no fit() ellipsis at the end).
    func divider(_ label: String, _ cols: Int) -> String {
        let head = "\u{2500}\u{2500} " + label
        let hw = displayWidth(head)
        if hw >= cols { return dim(fit(head, cols)) }
        return dim(head + String(repeating: "\u{2500}", count: cols - hw))
    }

    func nextByte() -> UInt8? {
        if inpos >= inbuf.count {
            var tmp = [UInt8](repeating: 0, count: 32)
            let n = read(STDIN_FILENO, &tmp, 32)
            if n <= 0 { return nil }
            inbuf = Array(tmp[0..<n]); inpos = 0
        }
        defer { inpos += 1 }
        return inbuf[inpos]
    }

    func peekByte() -> UInt8? { inpos < inbuf.count ? inbuf[inpos] : nil }

    /// Block up to `ms` for at least one more input byte, used to tell a lone ESC
    /// apart from the start of a split arrow sequence. Returns true if bytes are
    /// now buffered; on timeout/error it returns false so a genuine ESC falls
    /// through after only the short grace.
    func waitForMoreInput(_ ms: Int32) -> Bool {
        if inpos < inbuf.count { return true }
        var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, ms) > 0 else { return false }
        var tmp = [UInt8](repeating: 0, count: 32)
        let n = read(STDIN_FILENO, &tmp, 32)
        guard n > 0 else { return false }
        inbuf = Array(tmp[0..<n]); inpos = 0
        return true
    }

    func readKey() -> Key {
        guard let b0 = nextByte() else {
            // A SIGWINCH interrupts the blocking read (EINTR → nextByte returns
            // nil) and sets winchPending; surface it as a redraw, not EOF, so the
            // layout tracks the new size now instead of on the next keypress — and
            // a resize never reads as quit.
            if winchPending != 0 { winchPending = 0; return .resize }
            return .eof
        }
        if b0 == 0x1B {
            // An arrow arrives as ESC [ A/B/C/D. If the buffer is exhausted right
            // after ESC, the "[..." may simply not have arrived yet (a split read
            // on a slow/loaded PTY) — wait briefly before deciding this was a lone
            // ESC (back/quit). Once "[" is buffered, decode the arrow as before.
            if peekByte() == nil { _ = waitForMoreInput(escSequenceGraceMs) }
            if peekByte() == 0x5B {
                _ = nextByte()
                switch nextByte() {
                case 0x41?: return .up
                case 0x42?: return .down
                case 0x43?: return .right
                case 0x44?: return .left
                default: return .other
                }
            }
            return .esc
        }
        switch b0 {
        case 0x0D, 0x0A: return .enter
        case 0x20: return .space
        case 0x7F, 0x08: return .backspace
        case 0x09: return .tab
        case 0x03: return .ctrlC
        default: return .char(Character(UnicodeScalar(b0)))
        }
    }

    func terminalSize() -> (rows: Int, cols: Int) {
        var w = winsize()
        if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &w) == 0, w.ws_row > 0, w.ws_col > 0 {
            return (Int(w.ws_row), Int(w.ws_col))
        }
        return (24, 80)
    }

    func emit(_ s: String) {
        FileHandle.standardOutput.write(Data(s.utf8))
    }

    /// Reclaim the tty's foreground process group; a spawned child can leave us in
    /// the background, where the next read would raise SIGTTIN and stop us. SIGTTOU
    /// is ignored because tcsetpgrp from the background would itself stop us.
    func reclaimForeground() {
        guard isatty(STDIN_FILENO) != 0 else { return }
        signal(SIGTTOU, SIG_IGN)
        _ = tcsetpgrp(STDIN_FILENO, getpgrp())
    }

    // MARK: - Small helpers

    func formatBytes(_ bytes: Int?) -> String {
        guard let b = bytes, b > 0 else { return "" }
        if b < 1024 { return "\(b) B" }
        if b < 1_048_576 { return String(format: "%.1f KB", Double(b) / 1024) }
        if b < 1_073_741_824 { return String(format: "%.1f MB", Double(b) / 1_048_576) }
        return String(format: "%.1f GB", Double(b) / 1_073_741_824)
    }

    // Terminal-cell width, not grapheme count. Folder + album names are
    // user-controlled and may hold CJK/emoji (2 cells per glyph) or combining
    // marks (0 cells); counting them as 1 each overflows the fixed-width layout
    // and smears the reverse-video highlight bar. fit/padToWidth/divider all go
    // through this. A pragmatic subset of wcwidth — enough for real names without
    // dragging in a full Unicode width table.
    func scalarWidth(_ u: Unicode.Scalar) -> Int {
        let v = u.value
        if v == 0 { return 0 }
        // Combining / zero-width.
        if (0x0300...0x036F).contains(v)        // combining diacritical marks
            || (0x1AB0...0x1AFF).contains(v)
            || (0x1DC0...0x1DFF).contains(v)
            || (0x20D0...0x20FF).contains(v)    // combining marks for symbols
            || (0xFE20...0xFE2F).contains(v)    // combining half marks
            || v == 0x200B || v == 0x200C || v == 0x200D   // ZW space / non-joiner / joiner
            || v == 0xFEFF {                    // ZW no-break space
            return 0
        }
        // East-Asian Wide / Fullwidth + emoji blocks.
        if (0x1100...0x115F).contains(v)        // Hangul Jamo
            || (0x2E80...0x303E).contains(v)    // CJK radicals, Kangxi, punctuation
            || (0x3041...0x33FF).contains(v)    // Hiragana .. CJK compat
            || (0x3400...0x4DBF).contains(v)    // CJK Ext A
            || (0x4E00...0x9FFF).contains(v)    // CJK Unified
            || (0xA000...0xA4CF).contains(v)    // Yi
            || (0xAC00...0xD7A3).contains(v)    // Hangul syllables
            || (0xF900...0xFAFF).contains(v)    // CJK compat ideographs
            || (0xFE30...0xFE4F).contains(v)    // CJK compat forms
            || (0xFF00...0xFF60).contains(v)    // Fullwidth forms
            || (0xFFE0...0xFFE6).contains(v)    // Fullwidth signs
            || (0x1F300...0x1FAFF).contains(v)  // emoji & symbols
            || (0x20000...0x3FFFD).contains(v) {// CJK Ext B+
            return 2
        }
        return 1
    }

    /// Cell width of one grapheme cluster: 2 if it contains any wide scalar (an
    /// emoji ZWJ sequence or flag collapses to 2, not the sum of its parts), 1 for
    /// a normal cluster, 0 for a pure combining/zero-width cluster.
    func charWidth(_ ch: Character) -> Int {
        var width = 0
        for u in ch.unicodeScalars {
            let sw = scalarWidth(u)
            if sw == 2 { return 2 }
            if sw == 1 { width = 1 }
        }
        return width
    }

    func displayWidth(_ s: String) -> Int {
        var w = 0
        for ch in s { w += charWidth(ch) }
        return w
    }

    /// Pad `s` with trailing spaces to exactly `width` terminal cells. Unlike
    /// String.padding(toLength:), which counts graphemes, this counts cells, so a
    /// CJK/emoji name lands on the right column instead of overshooting.
    func padToWidth(_ s: String, _ width: Int) -> String {
        let w = displayWidth(s)
        return w >= width ? s : s + String(repeating: " ", count: width - w)
    }

    func fit(_ s: String, _ width: Int) -> String {
        if width <= 0 { return "" }
        if displayWidth(s) <= width { return s }
        if width == 1 { return "\u{2026}" }   // the ellipsis itself is one cell
        // Keep clusters until the next one would leave no room for the ellipsis.
        var out = "", used = 0
        for ch in s {
            let cw = charWidth(ch)
            if used + cw > width - 1 { break }
            out.append(ch); used += cw
        }
        return out + "\u{2026}"
    }

    func clamp(_ v: inout Int, _ count: Int) {
        v = count == 0 ? 0 : min(max(0, v), count - 1)
    }

    func adjustTop(_ top: inout Int, cursor: Int, height: Int, count: Int) {
        if cursor < top { top = cursor }
        else if cursor >= top + height { top = cursor - height + 1 }
        top = max(0, min(top, max(0, count - height)))
    }

    func bold(_ s: String) -> String { "\u{1B}[1m" + s + "\u{1B}[0m" }
    func dim(_ s: String) -> String { "\u{1B}[2m" + s + "\u{1B}[0m" }
    func cyan(_ s: String) -> String { "\u{1B}[36m" + s + "\u{1B}[0m" }
    func green(_ s: String) -> String { "\u{1B}[32m" + s + "\u{1B}[0m" }
    func yellow(_ s: String) -> String { "\u{1B}[33m" + s + "\u{1B}[0m" }
    func red(_ s: String) -> String { "\u{1B}[31m" + s + "\u{1B}[0m" }
    func rev(_ s: String) -> String { "\u{1B}[7m" + s + "\u{1B}[0m" }
}
