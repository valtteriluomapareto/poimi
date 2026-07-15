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
        title(forDays: group.days, isUndated: group.isUndated, calendar: calendar, locale: locale)
    }

    /// The date-range title for any review cluster's days — a plain date cluster's section title, and
    /// (for a trip) its date subline / the fallback title shown until its place name resolves. The trip
    /// *sentence* itself is composed app-side by `TripLabel` from the resolved name.
    static func title(for cluster: ReviewCluster, calendar: Calendar = .current, locale: Locale = .current) -> String {
        title(forDays: cluster.days, isUndated: cluster.isUndated, calendar: calendar, locale: locale)
    }

    private static func title(forDays days: [DayKey], isUndated: Bool,
                              calendar: Calendar, locale: Locale) -> String {
        if isUndated { return String(localized: "Undated") }
        guard let firstKey = days.first, let firstDate = firstKey.anchorDate(in: calendar) else {
            return ""
        }
        // Single day → weekday + month + day ("Sat, Jul 5"). `timeZone` is a settable property of
        // the style (the `.timeZone(_:)` builder configures a *display symbol*, not the zone used).
        var singleDay = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day().locale(locale)
        singleDay.timeZone = calendar.timeZone
        guard days.count > 1, let lastKey = days.last,
              let lastDate = lastKey.anchorDate(in: calendar) else {
            return firstDate.formatted(singleDay)
        }

        // Merged quiet run / multi-day trip → "Jul 16 – Jul 18" (weekday dropped to keep it scannable).
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

/// The characterful, one-line subtitle that gives a plain date cluster some personality (issue:
/// "day clusters feel soulless"). The text layer over the string-free `ClusterCharacter` (D14/D21):
/// the domain distils the facts, this phrases + localizes them (String Catalog, #95). A single day
/// leads with its time-of-day "shape" ("Morning – Evening"); it then appends notable media highlights
/// ("· 2 videos" / "· 3 favorites"). A multi-day run has NO length lead — its title is already a date
/// RANGE ("Jul 16 – Jul 18"), so "3 days" would only echo it — it relies on media highlights alone.
/// Returns `nil` when there's nothing worth saying, so the row stays clean rather than padded.
///
/// The caption carries a **leading SF Symbol** (a clock for a time span, else the media type) so it
/// reads as character rather than a second grey status line, plus a punctuation-free **`spoken`**
/// variant for VoiceOver (the display en-dash / middot read literally otherwise).
///
/// Trips carry their location sentence instead ("Week in Salo"), so callers build this only for the
/// non-trip date clusters — the everyday ones that read as a bare date otherwise.
enum ClusterCaption {
    /// The rendered caption: a leading SF Symbol + display text, plus a spoken (punctuation-free) form.
    struct Content: Equatable {
        let symbol: String
        let text: String
        let spoken: String
    }

    /// - Parameters:
    ///   - character: the cluster's distilled facts.
    ///   - dayCount: distinct DATED days the cluster covers (single day → time-of-day span lead; more →
    ///     media-only, since the range title already conveys the span).
    static func content(for character: ClusterCharacter, dayCount: Int) -> Content? {
        var display: [String] = []
        var spoken: [String] = []
        // Lead: a single day's time-of-day shape only (multi-day runs skip it — see the type doc).
        let hasSpan: Bool
        if dayCount <= 1, let span = spanText(character) {
            display.append(span.display)
            spoken.append(span.spoken)
            hasSpan = true
        } else {
            hasSpan = false
        }
        // Media highlights — automatic grammar agreement ("1 video" / "2 videos").
        if character.videoCount > 0 {
            let text = String(localized: "^[\(character.videoCount) video](inflect: true)",
                              comment: "Cluster caption: number of videos in the cluster")
            display.append(text)
            spoken.append(text)
        }
        if character.favoriteCount > 0 {
            let text = String(localized: "^[\(character.favoriteCount) favorite](inflect: true)",
                              comment: "Cluster caption: number of favorite photos in the cluster")
            display.append(text)
            spoken.append(text)
        }
        guard !display.isEmpty else { return nil }
        return Content(symbol: symbol(hasSpan: hasSpan, character: character),
                       text: display.joined(separator: " · "),
                       spoken: spoken.joined(separator: ", "))
    }

    /// A single day's time-of-day span: "Morning" (one part) or "Morning – Evening" (a range, the spaced
    /// en-dash the app already uses for date ranges). The spoken form swaps the en-dash for "to". `nil`
    /// when no asset carries a capture date.
    private static func spanText(_ character: ClusterCharacter) -> (display: String, spoken: String)? {
        guard let earliest = character.earliest, let latest = character.latest else { return nil }
        if earliest == latest { return (name(earliest), name(earliest)) }
        return ("\(name(earliest)) – \(name(latest))",
                String(localized: "\(name(earliest)) to \(name(latest))",
                       comment: "Cluster caption (spoken): a day's time-of-day span, earliest to latest"))
    }

    /// The leading glyph: a clock for a time-of-day span, else the media type that leads the caption.
    /// Only called when the caption is non-empty, so the `heart.fill` fallback always has a favorite.
    private static func symbol(hasSpan: Bool, character: ClusterCharacter) -> String {
        if hasSpan { return "clock" }
        if character.videoCount > 0 { return "video.fill" }
        return "heart.fill"
    }

    private static func name(_ part: ClusterCharacter.PartOfDay) -> String {
        switch part {
        case .morning: return String(localized: "Morning", comment: "Part of day")
        case .midday: return String(localized: "Midday", comment: "Part of day")
        case .afternoon: return String(localized: "Afternoon", comment: "Part of day")
        case .evening: return String(localized: "Evening", comment: "Part of day")
        case .night: return String(localized: "Night", comment: "Part of day")
        }
    }
}
