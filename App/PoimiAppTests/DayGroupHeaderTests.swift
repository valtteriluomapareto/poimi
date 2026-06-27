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
}
