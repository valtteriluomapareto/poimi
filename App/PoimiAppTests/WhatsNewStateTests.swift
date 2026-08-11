//
//  WhatsNewStateTests.swift
//  PoimiAppTests — the What's New version-jump matrix (#248).
//
//  Ported from photo-export's WhatsNewStateTests and adapted to Poimi's decisions: fresh install
//  shows NOTHING (photo-export showed a welcome) but SILENTLY PERSISTS a baseline; a self-expiring
//  DEBUT carve-out shows once on the feature-introducing version; markAsSeen covers Continue AND
//  swipe-dismiss.
//

import Testing
import Foundation
@testable import PoimiApp

@MainActor
@Suite("WhatsNewState (#248)")
struct WhatsNewStateTests {

    /// A fresh, isolated UserDefaults per test (no cross-test bleed).
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "whatsnew.test.\(UUID().uuidString)")!
    }

    private func note(_ version: String) -> ReleaseNote {
        ReleaseNote(version: version, highlights: [.init(symbol: "star", headline: "H", detail: "D")])
    }

    private func state(current: String, stored: String? = nil,
                       catalog: [ReleaseNote] = []) -> (WhatsNewState, UserDefaults) {
        let d = defaults()
        if let stored { d.set(stored, forKey: WhatsNewState.lastSeenVersionKey) }
        return (WhatsNewState(userDefaults: d, currentVersion: current, catalog: catalog), d)
    }

    // MARK: - Fresh install (FLIPPED from photo-export: silent, and persists a baseline)

    @Test("fresh install at a non-debut version shows nothing AND persists the baseline (#248 H1)")
    func freshInstallSilentAndPersists() {
        let (sut, d) = state(current: "2.5.0", catalog: [note("2.5.0")])   // not the debut version
        #expect(sut.shouldShow == false)
        #expect(sut.notes.isEmpty)
        // The load-bearing hook: the baseline is written in init, not on a (never-shown) dismissal.
        #expect(d.string(forKey: WhatsNewState.lastSeenVersionKey) == "2.5.0")
        #expect(sut.lastSeenVersion == "2.5.0")
    }

    @Test("a fresh install that silently banks its version DOES show on the next upgrade (#248 H1 two-step)")
    func freshThenUpgradeShows() {
        let d = defaults()
        // First launch, fresh, non-debut → silent + persisted.
        _ = WhatsNewState(userDefaults: d, currentVersion: "2.5.0", catalog: [note("2.5.0")])
        #expect(d.string(forKey: WhatsNewState.lastSeenVersionKey) == "2.5.0")
        // Next launch after an update → upgrade, so it shows (this is what a missing init-persist would break).
        let next = WhatsNewState(userDefaults: d, currentVersion: "2.6.0", catalog: [note("2.6.0")])
        #expect(next.shouldShow == true)
        #expect(next.notes.map(\.version) == ["2.6.0"])
    }

    // MARK: - Debut carve-out (reaches existing users once, then self-expires)

    @Test("debut version: fresh install shows the debut notes once, then persists on dismiss (#248)")
    func debutShowsOnceThenSilent() {
        let debut = WhatsNewState.debutVersion
        let (sut, d) = state(current: debut, catalog: [note(debut)])
        #expect(sut.shouldShow == true)                              // existing user (no stored) reached on debut
        #expect(sut.notes.map(\.version) == [debut])
        #expect(d.string(forKey: WhatsNewState.lastSeenVersionKey) == nil)   // NOT marked before shown
        sut.markAsSeen()
        #expect(sut.shouldShow == false)
        #expect(d.string(forKey: WhatsNewState.lastSeenVersionKey) == debut) // persisted on dismiss
    }

    // MARK: - Upgrade / same / downgrade

    @Test("same version after seen does not show again")
    func sameVersionSilent() {
        let (sut, _) = state(current: "1.2.0", stored: "1.2.0", catalog: [note("1.2.0")])
        #expect(sut.shouldShow == false)
    }

    @Test("an upgrade shows, with the matching catalog entry exposed")
    func upgradeShowsWithNotes() {
        let (sut, _) = state(current: "1.1.0", stored: "1.0.0", catalog: [note("1.1.0")])
        #expect(sut.shouldShow == true)
        #expect(sut.notes.map(\.version) == ["1.1.0"])
        #expect(sut.isUnknownUpgrade == false)
    }

    @Test("an upgrade with no catalog entry for the jump flags an unknown upgrade (generic fallback)")
    func unknownUpgradeFallback() {
        let (sut, _) = state(current: "2.0.0", stored: "1.0.0", catalog: [note("1.0.0")])
        #expect(sut.shouldShow == true)
        #expect(sut.notes.isEmpty)
        #expect(sut.isUnknownUpgrade == true)
    }

    @Test("a multi-version jump returns every intervening note, oldest first")
    func multiVersionJump() {
        let catalog = [note("1.3.0"), note("1.1.0"), note("1.2.0")]   // unordered on purpose
        let (sut, _) = state(current: "1.3.0", stored: "1.0.0", catalog: catalog)
        #expect(sut.notes.map(\.version) == ["1.1.0", "1.2.0", "1.3.0"])
    }

    @Test("upgrade bounds exclude last-seen and include current")
    func upgradeBounds() {
        let catalog = [note("1.1.0"), note("1.2.0"), note("1.3.0")]
        let (sut, _) = state(current: "1.3.0", stored: "1.1.0", catalog: catalog)
        #expect(sut.notes.map(\.version) == ["1.2.0", "1.3.0"])   // 1.1.0 excluded, 1.3.0 included
    }

    @Test("downgrade never triggers the sheet")
    func downgradeSilent() {
        let (sut, _) = state(current: "1.0.0", stored: "2.0.0", catalog: [note("1.0.0")])
        #expect(sut.shouldShow == false)
    }

    // MARK: - Numeric semver (not lexical) — minor AND patch above nine

    @Test("numeric compare: 1.9.0 → 1.10.0 is an upgrade (minor above nine)")
    func numericMinorAboveNine() {
        #expect(ReleaseNotesCatalog.compare("1.10.0", "1.9.0") == .orderedDescending)
        let (sut, _) = state(current: "1.10.0", stored: "1.9.0", catalog: [note("1.10.0")])
        #expect(sut.shouldShow == true)
    }

    @Test("numeric compare: 1.0.9 → 1.0.10 is an upgrade (patch above nine — the boundary Poimi hits first)")
    func numericPatchAboveNine() {
        #expect(ReleaseNotesCatalog.compare("1.0.10", "1.0.9") == .orderedDescending)
        let (sut, _) = state(current: "1.0.10", stored: "1.0.9", catalog: [note("1.0.10")])
        #expect(sut.shouldShow == true)
        #expect(sut.notes.map(\.version) == ["1.0.10"])
    }

    // MARK: - markAsSeen

    @Test("markAsSeen flips shouldShow synchronously + persists; keeps notes for the dismiss animation")
    func markAsSeenFlipsSynchronously() {
        let (sut, d) = state(current: "1.1.0", stored: "1.0.0", catalog: [note("1.1.0")])
        #expect(sut.shouldShow == true)                    // an upgrade genuinely starts true
        #expect(sut.notes.map(\.version) == ["1.1.0"])
        sut.markAsSeen()
        #expect(sut.shouldShow == false)                   // flipped in the same run loop, no stale flash
        #expect(sut.lastSeenVersion == "1.1.0")
        #expect(sut.notes.map(\.version) == ["1.1.0"])     // NOT cleared — the sheet reads them as it dismisses
        #expect(d.string(forKey: WhatsNewState.lastSeenVersionKey) == "1.1.0")
    }

    @Test("markAsSeen persists so a fresh state on the same store no longer shows (swipe-dismiss path)")
    func markAsSeenPersistsAcrossReconstruction() {
        let (sut, d) = state(current: "1.1.0", stored: "1.0.0", catalog: [note("1.1.0")])
        sut.markAsSeen()   // Continue OR swipe-down both route here
        let reopened = WhatsNewState(userDefaults: d, currentVersion: "1.1.0", catalog: [note("1.1.0")])
        #expect(reopened.shouldShow == false)
    }

    // MARK: - Manual open + catalog invariant

    @Test("manual open (Settings → About) has content even when the sheet stayed silent")
    func manualNotesIndependentOfSeenState() {
        // Fresh install at a non-debut, catalogued version → silent (shouldShow false), but the manual
        // open still resolves the current version's notes.
        let (sut, _) = state(current: "1.0.5", catalog: [note("1.0.5")])
        #expect(sut.shouldShow == false)
        #expect(sut.manualNotes.map(\.version) == ["1.0.5"])
    }

    @Test("manualNotes is empty when every catalogued entry is newer than the current version")
    func manualNotesEmptyWhenCatalogAhead() {
        // The actual shipped-1.0.1 behavior: the catalog's only entry is the 1.0.2 debut, so on 1.0.1 the
        // manual Settings → About open resolves to nothing → WhatsNewView shows the generic message.
        let (sut, _) = state(current: "1.0.1", catalog: [note("1.0.2")])
        #expect(sut.manualNotes.isEmpty)
    }

    @Test("manualNotes returns the NEWEST entry at or below current, not all of them")
    func manualNotesNewestNotAll() {
        let catalog = [note("1.0.0"), note("1.0.5"), note("1.1.0")]
        let (sut, _) = state(current: "1.0.5", catalog: catalog)
        #expect(sut.manualNotes.map(\.version) == ["1.0.5"])   // 1.0.0 excluded (older), 1.1.0 excluded (newer)
    }

    @Test("the production catalog is not behind the shipped version AND has the debut entry")
    func productionCatalogInvariants() throws {
        // Prove we read the HOST APP's bundle, not the xctest runner (M2) — else this guard is vacuous.
        #expect(Bundle.main.bundleIdentifier == "com.valtteriluoma.poimi")
        let version = try #require(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
        #expect(version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil)

        let newest = try #require(ReleaseNotesCatalog.all
            .max { ReleaseNotesCatalog.compare($0.version, $1.version) == .orderedAscending })
        // Catalog must be current OR ahead of the shipped version — never behind (a bump without notes).
        #expect(ReleaseNotesCatalog.compare(newest.version, version) != .orderedAscending)
        // The debut carve-out is keyed off debutVersion — its catalog entry MUST exist, or the sheet ships
        // invisible for existing users on the debut release (#248).
        #expect(ReleaseNotesCatalog.all.contains { $0.version == WhatsNewState.debutVersion })
    }
}
