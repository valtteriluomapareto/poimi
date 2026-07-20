//
//  ExportSyncTests.swift
//  CurationTests — the additions-only post-export drift signal (#191, decision a).
//

import Testing
@testable import Curation

@Suite("Export sync — additions-only drift")
struct ExportSyncTests {
    @Test("unchanged picks → nothing to add (in sync)")
    func unchanged() {
        #expect(ExportSync.pendingAdditions(picks: ["a", "b"], exported: ["a", "b"]) == 0)
    }

    @Test("added picks → counted")
    func added() {
        #expect(ExportSync.pendingAdditions(picks: ["a", "b", "c"], exported: ["a"]) == 2)
    }

    @Test("removals alone don't count (add-only export never removes from Photos)")
    func removalsIgnored() {
        #expect(ExportSync.pendingAdditions(picks: ["a"], exported: ["a", "b", "c"]) == 0)
    }

    @Test("a swap counts only the newly-added id (equal count, still drift)")
    func swap() {
        // dropped "b", added "c": count is unchanged (2), but "c" is new → 1 to add
        #expect(ExportSync.pendingAdditions(picks: ["a", "c"], exported: ["a", "b"]) == 1)
    }

    @Test("nothing exported yet vs empty picks → 0")
    func empties() {
        #expect(ExportSync.pendingAdditions(picks: [], exported: []) == 0)
        #expect(ExportSync.pendingAdditions(picks: ["a"], exported: []) == 1)
    }
}
