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
        // Full weekday + date, on a single day AND on each end of a range: "Friday, Feb 14" /
        // "Perjantai 14.2." · "Saturday, Feb 15 – Wednesday, Feb 20" / "Lauantai 15.2. – Keskiviikko 20.2.".
        // The locale decides the weekday/date wording + separator; `timeZone` is a settable property of the
        // style (the `.timeZone(_:)` builder configures a *display symbol*, not the zone used).
        var style = Date.FormatStyle.dateTime.weekday(.wide).month(.abbreviated).day().locale(locale)
        style.timeZone = calendar.timeZone
        let first = capitalizingFirstLetter(firstDate.formatted(style))
        guard days.count > 1, let lastKey = days.last,
              let lastDate = lastKey.anchorDate(in: calendar) else {
            return first
        }
        let last = capitalizingFirstLetter(lastDate.formatted(style))
        return "\(first) – \(last)"
    }

    /// Capitalize just the first character. Locales like Finnish lower-case weekday names ("perjantai");
    /// a standalone title wants the leading weekday capitalized ("Perjantai"). A no-op where the locale
    /// already capitalizes (English "Friday"). The rest of the string (the numeric date) is untouched.
    private static func capitalizingFirstLetter(_ string: String) -> String {
        guard let first = string.first else { return string }
        return first.uppercased() + string.dropFirst()
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
/// the domain distils the facts, this phrases + localizes them (String Catalog, #95). It surfaces notable
/// **media highlights** ("2 videos · 3 favorites") with a **leading SF Symbol** (video / heart) so it reads
/// as character rather than a second grey status line, plus a punctuation-free **`spoken`** variant for
/// VoiceOver. Returns `nil` when there's nothing worth saying, so the row stays a clean bare date.
///
/// (A meaningful everyday-cluster descriptor — a locality "shape" like "Mostly at home" — is #201. An
/// earlier time-of-day span "Morning – Evening" was dropped as low-signal.)
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

    /// - Parameter character: the cluster's distilled facts.
    static func content(for character: ClusterCharacter) -> Content? {
        var display: [String] = []
        var spoken: [String] = []
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
        // Media-led glyph — there's always a video or a favorite when the caption is non-empty.
        return Content(symbol: character.videoCount > 0 ? "video.fill" : "heart.fill",
                       text: display.joined(separator: " · "),
                       spoken: spoken.joined(separator: ", "))
    }
}
