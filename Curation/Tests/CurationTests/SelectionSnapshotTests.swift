//
//  SelectionSnapshotTests.swift
//  CurationTests — the durable selection envelope (issue #29, D15).
//

import Testing
import Foundation
@testable import Curation

@Suite("SelectionSnapshot envelope (#29)")
struct SelectionSnapshotTests {

    @Test("round-trips the id set and stamps the current version")
    func roundTrip() throws {
        let ids: Set<String> = ["a/1", "b/2", "c/3"]
        let snapshot = SelectionSnapshot(assetIDs: ids)
        #expect(snapshot.version == SelectionSnapshot.currentVersion)

        let decoded = SelectionSnapshot.decode(try snapshot.encoded())
        #expect(decoded.assetIDs == ids)
        #expect(decoded.version == SelectionSnapshot.currentVersion)
    }

    @Test("an empty selection round-trips to an empty set, not a miss")
    func emptyRoundTrip() throws {
        let decoded = SelectionSnapshot.decode(try SelectionSnapshot.empty.encoded())
        #expect(decoded.assetIDs.isEmpty)
    }

    @Test("nil / empty / corrupt data decodes tolerantly to empty — never throws, never wipes loudly")
    func tolerantDecode() {
        #expect(SelectionSnapshot.decode(nil) == .empty)
        #expect(SelectionSnapshot.decode(Data()) == .empty)
        #expect(SelectionSnapshot.decode(Data("not json".utf8)) == .empty)
        // Well-formed JSON of the wrong shape also degrades to empty, not a crash.
        #expect(SelectionSnapshot.decode(Data("{\"unrelated\":true}".utf8)) == .empty)
    }

    @Test("a same-shape future-version blob decodes as-is — picks are not wiped")
    func futureVersionDecodesAsIs() {
        // A newer build wrote version 2 with the same shape; an older build must keep the ids,
        // not silently drop them (the version field is the future migration hook). Pins the
        // documented behavior so the comment and code can't drift.
        let data = Data("{\"version\":2,\"assetIDs\":[\"x\",\"y\"]}".utf8)
        let decoded = SelectionSnapshot.decode(data)
        #expect(decoded.assetIDs == ["x", "y"])
        #expect(decoded.version == 2)
    }

    @Test("decoding ignores duplicate ids (it's a Set)")
    func setSemantics() throws {
        // Hand-rolled JSON array with a duplicate — the Set drops it.
        let data = Data("{\"version\":1,\"assetIDs\":[\"x\",\"x\",\"y\"]}".utf8)
        let decoded = SelectionSnapshot.decode(data)
        #expect(decoded.assetIDs == ["x", "y"])
    }
}
