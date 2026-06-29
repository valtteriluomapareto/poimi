//
//  DayGroupHeader.swift
//  PoimiApp — the day-group section title (issue #35).
//
//  Curation keeps titles out of the pure domain ("a UI concern formatted from `days`"), so the
//  label is built here from a `DayGroup`'s `days`. Pure + injectable (calendar + locale) so it's
//  deterministically testable: a single day reads "Sat, Jul 5"; a merged quiet run reads a span
//  "Jul 16 – Jul 18"; the undated bucket reads "Undated".
//

import Foundation
import Curation

enum DayGroupHeader {
    /// The section title for `group`. `calendar`/`locale` are injected so tests pin a timezone and
    /// month-name language; the app passes the user's `.current`.
    static func title(for group: DayGroup, calendar: Calendar = .current, locale: Locale = .current) -> String {
        if group.isUndated { return String(localized: "Undated") }
        guard let firstKey = group.days.first, let firstDate = firstKey.anchorDate(in: calendar) else {
            return ""
        }
        // Single day → weekday + month + day ("Sat, Jul 5"). `timeZone` is a settable property of
        // the style (the `.timeZone(_:)` builder configures a *display symbol*, not the zone used).
        var singleDay = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day().locale(locale)
        singleDay.timeZone = calendar.timeZone
        guard group.days.count > 1, let lastKey = group.days.last,
              let lastDate = lastKey.anchorDate(in: calendar) else {
            return firstDate.formatted(singleDay)
        }

        // Merged quiet run → "Jul 16 – Jul 18" (weekday dropped to keep the span scannable).
        var monthDay = Date.FormatStyle.dateTime.month(.abbreviated).day().locale(locale)
        monthDay.timeZone = calendar.timeZone
        return "\(firstDate.formatted(monthDay)) – \(lastDate.formatted(monthDay))"
    }

    /// The per-photo day label for the viewer (#36): one calendar day, "Sat, Jul 5", or "Undated".
    /// Identical style to a single-day section title, so the viewer's label and the grid's day
    /// section agree. The viewer shows the photo's *own* day — not its group's span — since a merged
    /// quiet run spans several days but each photo sits on exactly one.
    static func dayLabel(for key: DayKey, calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard let date = key.anchorDate(in: calendar) else { return String(localized: "Undated") }
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day().locale(locale)
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }
}
