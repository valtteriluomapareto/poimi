//
//  ControlAliases.swift
//  PoimiApp — the control plane's aliases (#296, docs/plans/control-plane.md §5). DEBUG-only (D30).
//
//  The snapshot never carries a `localIdentifier`, a project UUID or a title. It speaks in aliases:
//
//  - **Assets** (`a-0001`): assigned ONCE per fixture over the whole seeded library — ordered by
//    capture date (D32), then seed index, undated last — so they stay stable across lens, exclusion
//    and range edits (an alias is a property of the library, not of a scan).
//  - **Assets added mid-run** (`library.addPhotos`, #300) get the next numbers, in the order added — an
//    existing alias never moves.
//  - **Albums** (`album-1`): monotonic and never reused within a run, so a deleted album's alias is
//    never handed to a later one. A fixture launch starts over; a relaunch keeps them (#300).
//  - **Clusters/days** are keyed by their `DayKey` (`2025-07-05`), not an ordinal.
//
#if DEBUG

import Foundation
import Curation

/// Asset aliases for one fixture's library. Pure + `Sendable`: the same assets always yield the
/// same table.
struct ControlAssetAliases: Equatable, Sendable {
    private let aliasByID: [String: String]
    private let idByAlias: [String: String]
    /// Alias order (the alias's number), so lists of aliases sort the way the aliases read.
    private let rankByID: [String: Int]

    init(assets: [AssetRef]) {
        // Capture date first (D32), the seed index breaks ties, undated last.
        let ordered = assets.enumerated().sorted { lhs, rhs in
            switch (lhs.element.captureDate, rhs.element.captureDate) {
            case let (left?, right?) where left != right: left < right
            case (.some, nil): true
            case (nil, .some): false
            default: lhs.offset < rhs.offset
            }
        }.map(\.element.id)
        self.init(width: max(4, String(ordered.count).count), aliasByID: [:], idByAlias: [:], rankByID: [:],
                  adding: ordered)
    }

    private let width: Int

    private init(width: Int, aliasByID: [String: String], idByAlias: [String: String], rankByID: [String: Int],
                 adding ids: [String]) {
        var aliasByID = aliasByID
        var idByAlias = idByAlias
        var rankByID = rankByID
        for id in ids where aliasByID[id] == nil {
            let index = rankByID.count
            let number = String(index + 1)
            let alias = "a-" + String(repeating: "0", count: max(0, width - number.count)) + number
            aliasByID[id] = alias
            idByAlias[alias] = id
            rankByID[id] = index
        }
        self.width = width
        self.aliasByID = aliasByID
        self.idByAlias = idByAlias
        self.rankByID = rankByID
    }

    /// This table plus `assets` (added to the library mid-run), numbered after every existing alias in the
    /// order given — so no alias already handed out changes.
    func appending(_ assets: [AssetRef]) -> ControlAssetAliases {
        ControlAssetAliases(width: width, aliasByID: aliasByID, idByAlias: idByAlias, rankByID: rankByID,
                            adding: assets.map(\.id))
    }

    func alias(for assetID: String) -> String? { aliasByID[assetID] }

    func assetID(for alias: String) -> String? { idByAlias[alias] }

    /// `ids` restricted to the seeded library, in alias order. An id outside the library (none
    /// should exist — the fake vends only seeded assets) is dropped rather than leaked.
    func ordered(_ ids: some Sequence<String>) -> [String] {
        ids.compactMap { id in rankByID[id].map { (rank: $0, id: id) } }
            .sorted { $0.rank < $1.rank }
            .map(\.id)
    }

    /// `ids` as aliases, in alias order.
    func aliases(for ids: some Sequence<String>) -> [String] {
        ordered(ids).compactMap { aliasByID[$0] }
    }

    /// Whether `text` has the asset-alias shape (`a-` + digits).
    static func isAlias(_ text: String) -> Bool {
        text.hasPrefix("a-") && text.count > 2 && text.dropFirst(2).allSatisfy(\.isASCIIDigit)
    }
}

/// Album aliases: `album-<n>`, monotonic and never reused within a run. A fixture launch starts them
/// over; a relaunch (#300) restores them from the run record, which `didAssign` keeps current.
@MainActor
final class ControlAlbumAliases {
    private var aliasByID: [UUID: String] = [:]
    private var next = 1
    /// Called after a new alias is assigned (the runtime saves the run record).
    var didAssign: (() -> Void)?

    init() {}

    /// The aliases a run record carries (a relaunch).
    init(restoring record: ControlRunRecord) {
        for (id, alias) in record.albums {
            guard let uuid = UUID(uuidString: id), Self.isAlias(alias) else { continue }
            aliasByID[uuid] = alias
        }
        next = max(record.nextAlbum, (aliasByID.values.map(Self.number).max() ?? 0) + 1)
    }

    /// The table as a run record carries it.
    func record(fixture: ControlFixture) -> ControlRunRecord {
        ControlRunRecord(fixture: fixture.rawValue,
                         albums: Dictionary(uniqueKeysWithValues: aliasByID.map { ($0.key.uuidString, $0.value) }),
                         nextAlbum: next)
    }

    /// The alias already assigned to `id`, or `nil`. A pure lookup — the snapshot projection uses
    /// this, so building a snapshot never mutates the table.
    func alias(for id: UUID) -> String? { aliasByID[id] }

    /// Assign the next number to `id` (idempotent: an already-aliased id keeps its alias).
    @discardableResult
    func assign(_ id: UUID) -> String {
        if let existing = aliasByID[id] { return existing }
        let alias = "album-\(next)"
        next += 1
        aliasByID[id] = alias
        didAssign?()
        return alias
    }

    /// The project id behind `alias`, if one was ever assigned (deleted projects keep their alias).
    func projectID(for alias: String) -> UUID? {
        aliasByID.first { $0.value == alias }?.key
    }

    /// Assign aliases to any of `projects` not yet aliased — oldest first (`createdAt`, then id) so
    /// albums created through the UI get numbers in the order they were made.
    func assignNew(_ projects: [CurationProject]) {
        let unseen = projects.filter { aliasByID[$0.id] == nil }
        guard !unseen.isEmpty else { return }
        for project in unseen.sorted(by: { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }) {
            assign(project.id)
        }
    }

    /// The numeric part of an alias, for ordering (`album-10` after `album-9`).
    nonisolated static func number(of alias: String) -> Int {
        Int(alias.dropFirst("album-".count)) ?? .max
    }

    /// Whether `text` has the album-alias shape (`album-` + a positive number).
    nonisolated static func isAlias(_ text: String) -> Bool {
        guard text.hasPrefix("album-") else { return false }
        let digits = text.dropFirst("album-".count)
        return !digits.isEmpty && digits.allSatisfy(\.isASCIIDigit) && (Int(digits) ?? 0) > 0
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

#endif
