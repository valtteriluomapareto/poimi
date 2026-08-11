//
//  ReleaseNote.swift
//  PoimiApp — one version's "What's New" content (#248).
//
//  The model behind the What's New sheet. New releases append a `ReleaseNote` to
//  `ReleaseNotesCatalog.all`; forgetting doesn't crash — the sheet degrades to a generic
//  "Poimi has been updated" fallback keyed on the current version.
//
//  Localized copy (`headline` / `detail`) is `LocalizedStringResource` so it resolves at render
//  time in the viewer's locale and supports inline markdown; the SF Symbol `symbol` is a plain
//  dev-facing `String` and must NOT flow into the String Catalog (#95). App-tier only (D14/D21).
//

import Foundation

struct ReleaseNote: Identifiable, Equatable, Sendable {
    /// Semver of the release this note describes — must equal `CFBundleShortVersionString`
    /// exactly (e.g. "1.1.0", not "v1.1.0"). Matched numerically by `ReleaseNotesCatalog`.
    let version: String
    /// The highlight rows, in display order. ≤3 per release by convention (#248).
    let highlights: [Highlight]

    var id: String { version }

    /// One tinted-symbol row: an SF Symbol, a bold headline, and a one-to-two-sentence detail
    /// (deliberately a touch more verbose than the App Store's terse notes, #248).
    struct Highlight: Equatable, Sendable {
        /// SF Symbol name — dev-facing, NOT localized (kept out of the String Catalog).
        let symbol: String
        let headline: LocalizedStringResource
        let detail: LocalizedStringResource
    }
}
