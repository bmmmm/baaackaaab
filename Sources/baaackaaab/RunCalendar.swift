import Foundation

/// Pure month-grid rendering of the run history: three months side by side, one
/// cell per day, so a gap in unattended coverage is visible as a hole rather than
/// as an absence of rows in a list.
///
/// A day aggregates EVERY run recorded for it — backup, integrity check, restore
/// drill. A day whose backup succeeded but whose check failed is `partial`, not
/// `ok`: the calendar's job is to make a bad day findable, and hiding a failed
/// check behind a green backup would defeat it.
///
/// Days outside the recorded window render blank rather than as "no run", at both
/// ends. Nothing in the future has failed to happen yet, and days before the
/// history starts were never observed — in both cases a run of dots reads like a
/// coverage gap the operator should act on, which is exactly the wrong signal.
enum RunCalendar {
    enum DayStatus: Equatable { case ok, failed, partial }

    /// One rendered day (or a padding cell before the 1st / after the last).
    struct Cell: Equatable {
        let label: String        // two columns wide, right-aligned
        let status: DayStatus?   // nil for padding, headers and days with no run
    }

    static func symbol(_ status: DayStatus?) -> String {
        switch status {
        case .ok:       return "\u{2713}"
        case .failed:   return "\u{2717}"
        case .partial:  return "!"
        case .none:     return "\u{00B7}"
        }
    }

    /// Fold every record onto its calendar day. Keyed by the day's start, so the
    /// caller looks up with `calendar.startOfDay(for:)`.
    static func statusByDay(_ records: [RunRecord], calendar: Calendar) -> [Date: DayStatus] {
        var out: [Date: DayStatus] = [:]
        for rec in records {
            let day = calendar.startOfDay(for: rec.end)
            let this: DayStatus = rec.clean ? .ok : .failed
            switch out[day] {
            case nil:            out[day] = this
            case .some(let old): out[day] = (old == this) ? old : .partial
            }
        }
        return out
    }

    /// The month-start dates for the `months` months ending with the month that
    /// contains `end`, oldest first.
    static func monthStarts(months: Int, end: Date, calendar: Calendar) -> [Date] {
        guard months > 0 else { return [] }
        let comps = calendar.dateComponents([.year, .month], from: end)
        guard let thisMonth = calendar.date(from: comps) else { return [] }
        return (0..<months).reversed().compactMap {
            calendar.date(byAdding: .month, value: -$0, to: thisMonth)
        }
    }

    /// One month as 6 week-rows of 7 cells, Monday first. Cells before the 1st and
    /// after the last day of the month are blank padding, as are days outside the
    /// observed window: after `now`, or before `knownFrom` (the oldest recorded
    /// run — nil means the history reaches back past this month).
    static func monthCells(monthStart: Date, statusByDay: [Date: DayStatus],
                           now: Date, knownFrom: Date? = nil, calendar: Calendar) -> [[Cell]] {
        let blank = Cell(label: "  ", status: nil)
        guard let range = calendar.range(of: .day, in: .month, for: monthStart) else { return [] }
        // Monday-first offset, fixed rather than taken from the calendar's
        // firstWeekday: the weekday header above is a literal "Mo Tu … Su", so a
        // locale that starts its week on Sunday would shift every cell one column
        // out from its own header. Calendar's weekday is 1-based from Sunday, so
        // Mon(2) → 0 … Sun(1) → 6.
        let firstWeekday = calendar.component(.weekday, from: monthStart)
        let lead = (firstWeekday + 5) % 7
        let today = calendar.startOfDay(for: now)
        let firstKnown = knownFrom.map { calendar.startOfDay(for: $0) }

        var cells: [Cell] = Array(repeating: blank, count: lead)
        for day in range {
            guard let date = calendar.date(byAdding: .day, value: day - 1, to: monthStart) else { continue }
            let start = calendar.startOfDay(for: date)
            // Unobserved at either end — the future has not failed to run yet, and
            // days before the history begins were never recorded either way.
            if start > today || (firstKnown.map { start < $0 } ?? false) {
                cells.append(blank)
                continue
            }
            let status = statusByDay[start]
            cells.append(Cell(label: " " + symbol(status), status: status))
        }
        while cells.count < 42 { cells.append(blank) }
        return stride(from: 0, to: 42, by: 7).map { Array(cells[$0..<($0 + 7)]) }
    }

    /// The whole grid: a month-name header line, a weekday header line, and the
    /// week rows with each month's cells joined side by side. Returned as cells so
    /// the caller can colour each day; `headers` are plain text.
    static func grid(months: Int, now: Date, statusByDay: [Date: DayStatus],
                     knownFrom: Date? = nil,
                     calendar: Calendar) -> (monthHeader: String, weekdayHeader: String, rows: [[Cell]]) {
        let starts = monthStarts(months: months, end: now, calendar: calendar)
        let gap = "   "

        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "MMM yyyy"
        // Each month block is 7 two-wide cells joined by a space: 7*2 + 6 = 20.
        let blockWidth = 20
        let monthHeader = starts.map { center(fmt.string(from: $0), blockWidth) }.joined(separator: gap)
        let weekdayHeader = starts.map { _ in
            ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"].joined(separator: " ")
        }.joined(separator: gap)

        let perMonth = starts.map {
            monthCells(monthStart: $0, statusByDay: statusByDay, now: now,
                       knownFrom: knownFrom, calendar: calendar)
        }
        // Join week N of every month into one row, with a gap cell between blocks.
        var rows: [[Cell]] = []
        for week in 0..<6 {
            var row: [Cell] = []
            for (i, month) in perMonth.enumerated() {
                // One space here, not `gap`: the caller joins cells with a space,
                // so a 1-wide separator cell yields the 3 columns the header's
                // `gap` puts between month blocks. A 3-wide one would drift the
                // grid two columns right of its own header per block.
                if i > 0 { row.append(Cell(label: " ", status: nil)) }
                row += month[week]
            }
            rows.append(row)
        }
        // A 6th week row exists only for months that need it; drop trailing rows
        // that are entirely padding so the panel stays as short as the data allows.
        while let last = rows.last, last.allSatisfy({ $0.status == nil && $0.label.trimmingCharacters(in: .whitespaces).isEmpty }) {
            rows.removeLast()
        }
        return (monthHeader, weekdayHeader, rows)
    }

    private static func center(_ s: String, _ width: Int) -> String {
        guard s.count < width else { return s }
        let left = (width - s.count) / 2
        return String(repeating: " ", count: left) + s
            + String(repeating: " ", count: width - s.count - left)
    }

    /// The legend, spelled out once under the grid.
    static let legend = "\u{2713} ok   \u{2717} failed   ! mixed   \u{00B7} no run"
}
