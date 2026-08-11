//
//  WhatsNewState.swift
//  PoimiApp — decides whether to present the "What's New" sheet for the current version (#248).
//
//  `@Observable` (Observation, not Combine). Stores the last-seen `CFBundleShortVersionString` in
//  `UserDefaults`. The sheet presents on an UPGRADE (stored < current) or, once, on the DEBUT
//  version — the self-expiring carve-out that reaches existing users on the release that first
//  ships this feature. A fresh install at any *later* version marks the current version seen
//  SILENTLY (onboarding #31 owns first-run).
//
//  Two load-bearing details from the plan review:
//   • The silent mark is **persisted in `init`** (independent of presentation), so a silent fresh
//     install can't re-read `nil` forever and leave the feature never firing.
//   • `markAsSeen()` is driven by the sheet's DISMISSAL (Continue AND swipe-down), so an
//     interactive dismiss still persists.
//
//  `UserDefaults` / version / catalog are injected via the designated init for tests.
//

import Foundation
import Observation

@MainActor
@Observable
final class WhatsNewState {
    /// The version that first ships What's New. The debut carve-out shows the notes once to existing
    /// users (no stored version) on THIS version, then reverts to silent on every later release.
    /// **Set this to the actual release version when you cut it** — and give it a `ReleaseNotesCatalog`
    /// entry — or the debut won't fire. (#248)
    ///
    /// `nonisolated` so the (nonisolated) `ReleaseNotesCatalog.all` can reference it — an immutable
    /// `String`, so it's safe to read from any isolation.
    nonisolated static let debutVersion = "1.1.0"

    /// `UserDefaults` key for the most recently dismissed version. Reset it to re-trigger the sheet
    /// for testing: `defaults delete com.valtteriluoma.poimi WhatsNew.lastSeenVersion`.
    static let lastSeenVersionKey = "WhatsNew.lastSeenVersion"

    /// True while the sheet should present. Bound to `.sheet(isPresented:)`; flips false synchronously
    /// on `markAsSeen()`.
    private(set) var shouldShow: Bool

    let currentVersion: String
    private(set) var lastSeenVersion: String?
    /// The notes to render when the sheet presents; empty on the fresh/unknown path (the view shows
    /// a generic message). Refreshed by `markAsSeen()`.
    private(set) var notes: [ReleaseNote]

    private let catalog: [ReleaseNote]
    private let userDefaults: UserDefaults

    convenience init(userDefaults: UserDefaults = .standard,
                     bundle: Bundle = .main,
                     catalog: [ReleaseNote] = ReleaseNotesCatalog.all) {
        let version = (bundle.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        self.init(userDefaults: userDefaults, currentVersion: version, catalog: catalog)
    }

    /// Designated init. Tests pass `currentVersion` directly to exercise multi-version jumps and the
    /// debut/unknown paths without faking `Bundle.main`.
    init(userDefaults: UserDefaults, currentVersion: String, catalog: [ReleaseNote]) {
        self.userDefaults = userDefaults
        self.currentVersion = currentVersion
        self.catalog = catalog
        let stored = userDefaults.string(forKey: Self.lastSeenVersionKey)
        self.lastSeenVersion = stored

        if let stored {
            // Upgrade → show if current is strictly newer; same / downgrade → silent.
            self.shouldShow = ReleaseNotesCatalog.compare(stored, currentVersion) == .orderedAscending
            self.notes = ReleaseNotesCatalog.notesForUpgrade(lastSeen: stored, current: currentVersion, catalog: catalog)
        } else {
            // No stored version. Standard: fresh install = silent. Debut carve-out: on the
            // feature-introducing version, show ONCE (reaches existing users) with that version's notes.
            let isDebut = ReleaseNotesCatalog.compare(currentVersion, Self.debutVersion) == .orderedSame
            self.shouldShow = isDebut
            self.notes = isDebut
                ? catalog.filter { ReleaseNotesCatalog.compare($0.version, currentVersion) == .orderedSame }
                : []
            if !isDebut {
                // Silent fresh install: bank the baseline NOW so it can't re-read nil forever (the
                // debut path persists on dismiss instead, so it isn't marked before it's shown).
                userDefaults.set(currentVersion, forKey: Self.lastSeenVersionKey)
                self.lastSeenVersion = currentVersion
            }
        }
    }

    /// Content for the manual "What's New" open (App settings → About), independent of seen-state:
    /// the newest catalogued entry at or below the current version, else empty.
    var manualNotes: [ReleaseNote] {
        catalog
            .filter { ReleaseNotesCatalog.compare($0.version, currentVersion) != .orderedDescending }
            .max { ReleaseNotesCatalog.compare($0.version, $1.version) == .orderedAscending }
            .map { [$0] } ?? []
    }

    /// True when the sheet fires but there are no catalogued notes for the jump — the view shows a
    /// generic "Poimi has been updated" message rather than stale copy.
    var isUnknownUpgrade: Bool { shouldShow && notes.isEmpty }

    /// Persist the current version as seen + refresh derived state. Driven by the sheet's dismissal
    /// (Continue AND swipe-down). Idempotent.
    func markAsSeen() {
        userDefaults.set(currentVersion, forKey: Self.lastSeenVersionKey)
        lastSeenVersion = currentVersion
        notes = ReleaseNotesCatalog.notesForUpgrade(lastSeen: currentVersion, current: currentVersion, catalog: catalog)
        if shouldShow { shouldShow = false }
    }
}
