//
//  ExportSync.swift
//  Curation — post-export drift, the additions-only way (issue #191, v1 decision (a)).
//
//  After an album is exported, its picks can drift from what's in the Photos album. Detection is a pure
//  function of the persisted picks — the CURRENT pick set vs the pick set captured at the last export —
//  with **no clock** (a timestamp gives false positives on toggle-off-then-on and is flaky to test) and
//  **no count compare** (a swap keeps the count equal yet is real drift). We compare the id SETS.
//
//  v1 framing is ADDITIONS-ONLY (D-review #191(a)): export is add-only — de-selecting a pick in Poimi
//  never removes the photo from the Photos album — so the only actionable drift is "N new picks not yet
//  in Photos". A pure removal leaves nothing to add and reads as still-in-sync (the removed photo is,
//  honestly, still in the album). Fingerprint the user's PICKS, not the live-resolved subset export
//  writes, so an unresolvable pick doesn't show permanent drift.
//

import Foundation

public enum ExportSync {
    /// How many current picks a re-export would ADD — the current picks not present in the set captured
    /// at the last export. Removals are deliberately not counted (add-only export, decision (a)). `0`
    /// means in-sync (or only removals). Pure set arithmetic; no clock, so it unit-tests like a value.
    public static func pendingAdditions(picks: Set<String>, exported: Set<String>) -> Int {
        picks.subtracting(exported).count
    }
}
