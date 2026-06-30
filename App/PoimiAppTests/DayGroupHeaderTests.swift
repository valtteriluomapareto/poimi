//
//  DayGroupHeaderTests.swift
//  PoimiAppTests — the day-group section title (#35).
//
//  Built from real `DayGrouping` output (not hand-rolled DayGroups) with a fixed UTC calendar +
//  en_US locale, so the single-day / merged-run / undated branches are pinned deterministically.
//  Asserts the salient tokens (month/day/weekday, span separator) rather than exact FormatStyle
//  punctuation, which can shift across SDK/locale data.
//

import Testing
import Foundation
import Curation
@testable import PoimiApp

@Suite("DayGroupHeader (#35)")
struct DayGroupHeaderTests {

    private static let enUS = Locale(identifier: "en_US")

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        utcCalendar().date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    private func title(_ assets: [AssetRef]) -> String {
        let groups = DayGrouping.groups(for: assets, calendar: utcCalendar())
        return DayGroupHeader.title(for: groups[0], calendar: utcCalendar(), locale: Self.enUS)
    }

    @Test("a single-day group reads weekday, month, day")
    func singleDay() {
        // 2025-07-05 is a Saturday; a handful of photos on one day stays a single-day group.
        let assets = (0..<3).map { AssetRef(id: "a\($0)", captureDate: date(2025, 7, 5)) }
        let header = title(assets)
        #expect(header.contains("Jul"))
        #expect(header.contains("5"))
        #expect(header.contains("Sat"))
    }

    @Test("a merged quiet run reads a month–day span")
    func multiDayRun() {
        // One photo each on 2025-03-16/17/18 → a merged quiet run of 3 days.
        let assets = (16...18).map { AssetRef(id: "q\($0)", captureDate: date(2025, 3, $0)) }
        let header = title(assets)
        #expect(header.contains("Mar"))
        #expect(header.contains("16"))
        #expect(header.contains("18"))
        #expect(header.contains("–"))      // an en-dash span, not a single day
    }

    @Test("the undated group reads \"Undated\"")
    func undated() {
        let header = title([AssetRef(id: "u", captureDate: nil)])
        #expect(header == "Undated")
    }

    @Test("dayLabel formats one calendar day (weekday, month, day) for the viewer (#36)")
    func dayLabelSingleDay() {
        // The viewer labels each photo with its *own* day — same style as a single-day section.
        let label = DayGroupHeader.dayLabel(for: .day(year: 2025, month: 7, day: 5),
                                            calendar: utcCalendar(), locale: Self.enUS)
        #expect(label.contains("Jul"))
        #expect(label.contains("5"))
        #expect(label.contains("Sat"))   // 2025-07-05 is a Saturday
    }

    @Test("dayLabel reads \"Undated\" for the undated key (#36)")
    func dayLabelUndated() {
        #expect(DayGroupHeader.dayLabel(for: .undated, calendar: utcCalendar(), locale: Self.enUS)
            == "Undated")
    }
}

/// Locks the collapsed-peek "foreground the keeps" ordering (#89 product blocker) so it can't
/// regress to raw chronology.
@Suite("Collapsed peek ordering (#89)")
struct KeptFirstOrderingTests {

    @Test("picked ids move to the front, each side keeps source order")
    func keepsFirst() {
        let ordered = keptFirstOrdering(ids: ["a", "b", "c", "d"], picked: ["b", "d"])
        #expect(ordered == ["b", "d", "a", "c"])
    }

    @Test("zero picks leaves the order untouched")
    func nonePicked() {
        #expect(keptFirstOrdering(ids: ["a", "b", "c"], picked: []) == ["a", "b", "c"])
    }

    @Test("a partition: every id appears exactly once regardless of the picked set")
    func partition() {
        let ids = ["a", "b", "c", "d", "e"]
        let ordered = keptFirstOrdering(ids: ids, picked: ["c", "e", "zzz"])  // "zzz" not in ids
        #expect(Set(ordered) == Set(ids))
        #expect(ordered.count == ids.count)
        #expect(Array(ordered.prefix(2)) == ["c", "e"])   // the in-range picks lead, in source order
    }
}
