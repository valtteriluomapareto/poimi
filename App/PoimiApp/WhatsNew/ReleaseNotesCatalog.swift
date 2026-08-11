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
        // 1.0.2 — the two fixes shipped in this patch, authored from CHANGELOG.md's section (#182).
        // Per release: add a new entry (keyed off WhatsNewState.debutVersion), ≤3 highlights, each detail
        // ≤2 sentences, and add the `fi` copy (§5.7 checklist).
        ReleaseNote(
            version: WhatsNewState.debutVersion,   // 1.0.2 — the version this What's New debuts in
            highlights: [
                .init(symbol: "calendar",
                      headline: "Pick any date range",
                      detail: "Setting an album's dates no longer gets stuck — you can choose a start date later than the default without the calendar greying out."),
                .init(symbol: "ipad",
                      headline: "Smoother on iPad",
                      detail: "App settings no longer opens a new screen each time you tap the button.")
            ])
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
