//
//  ReleaseNotesCatalog.swift
//  PoimiApp — the in-app "What's New" content, one entry per public release (#248).
//
//  Append a `ReleaseNote` here for each release that ships user-visible changes worth
//  highlighting — authored from that release's CHANGELOG.md section (#182), in a friendlier
//  voice, en + fi. Lookup is by NUMERIC semver (so 1.0.10 > 1.0.9), never array order.
//
//  Release checklist (see docs/deploy/testflight-setup.md §5.7): when you cut a version, add its
//  entry here and translate the new keys to `fi`. Forgetting degrades gracefully — the sheet shows
//  a generic "updated" message rather than stale copy.
//

import Foundation

enum ReleaseNotesCatalog {
    /// All release notes. Order is irrelevant (lookup sorts by semver). Each `version` must equal
    /// a real shipped `CFBundleShortVersionString`.
    static let all: [ReleaseNote] = [
        // PLACEHOLDER debut entry (#248): replace these highlights with the real ones authored from
        // the CHANGELOG for the ACTUAL release version, and set `WhatsNewState.debutVersion` to that
        // same version. Keep it ≤3 highlights, each detail ≤2 sentences, and add the `fi` copy.
        ReleaseNote(
            version: WhatsNewState.debutVersion,
            highlights: [
                .init(symbol: "mappin.and.ellipse",
                      headline: "Trips, grouped for you",
                      detail: "Days away from home now gather into a single trip, named for where you were — like “Week in Åland” — so a holiday reads as one story, not scattered dates."),
                .init(symbol: "calendar",
                      headline: "Curate any stretch",
                      detail: "Pick a whole year, a single weekend, or anything in between. Choosing the dates is smoother now, right up to today."),
                .init(symbol: "square.grid.2x2",
                      headline: "Smoother to review",
                      detail: "The grid runs edge-to-edge and flows from one day to the next with a swipe, with clearer VoiceOver along the way."),
            ]),
    ]

    /// Numeric semver compare of two `MAJOR.MINOR.PATCH` strings — `1.0.10` > `1.0.9`, not a lexical
    /// compare (`check-version.sh` guarantees the bundle version is well-formed; catalog versions
    /// must match that shape).
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        a.compare(b, options: .numeric)
    }

    /// The notes to show on an upgrade from `lastSeen` to `current`: every catalogued version in the
    /// half-open interval `(lastSeen, current]`, oldest first. A fresh install (`lastSeen == nil`)
    /// returns `[]` (the debut path is handled in `WhatsNewState`, not here).
    static func notesForUpgrade(lastSeen: String?, current: String, catalog: [ReleaseNote] = all) -> [ReleaseNote] {
        guard let lastSeen else { return [] }
        return catalog
            .filter { compare($0.version, lastSeen) == .orderedDescending      // > lastSeen
                   && compare($0.version, current) != .orderedDescending }     // <= current
            .sorted { compare($0.version, $1.version) == .orderedAscending }
    }
}
