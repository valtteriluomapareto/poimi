//
//  ControlAliases.swift
//  PoimiApp — the control plane's aliases (#296, docs/plans/control-plane.md §5). DEBUG-only (D30).
//
//  The snapshot never carries a `localIdentifier`, a project UUID or a title. It speaks in aliases:
//
//  - **Assets** (`a-0001`): assigned ONCE per fixture over the whole seeded library — ordered by
//    capture date (D32), then seed index, undated last — so they stay stable across lens, exclusion
//    and range edits (an alias is a property of the library, not of a scan).
//  - **Albums** (`album-1`): monotonic and never reused, persisted next to the isolated store, so a
//    deleted album's alias is never handed to a later one.
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
        let width = max(4, String(ordered.count).count)
        var aliasByID: [String: String] = [:]
        var idByAlias: [String: String] = [:]
        var rankByID: [String: Int] = [:]
        for (index, id) in ordered.enumerated() where aliasByID[id] == nil {
            let number = String(index + 1)
            let alias = "a-" + String(repeating: "0", count: max(0, width - number.count)) + number
            aliasByID[id] = alias
            idByAlias[alias] = id
            rankByID[id] = index
        }
        self.aliasByID = aliasByID
        self.idByAlias = idByAlias
        self.rankByID = rankByID
    }

    var count: Int { aliasByID.count }

    func alias(for assetID: String) -> String? { aliasByID[assetID] }

    func assetID(for alias: String) -> String? { idByAlias[alias] }

    /// `ids` as aliases in alias order. An id outside the seeded library (none should exist — the
    /// fake vends only seeded assets) is dropped rather than leaked.
    func aliases(for ids: some Sequence<String>) -> [String] {
        ids.compactMap { id in rankByID[id].map { (rank: $0, id: id) } }
            .sorted { $0.rank < $1.rank }
            .compactMap { aliasByID[$0.id] }
    }

    /// Whether `text` has the asset-alias shape (`a-` + digits).
    static func isAlias(_ text: String) -> Bool {
        text.hasPrefix("a-") && text.count > 2 && text.dropFirst(2).allSatisfy(\.isASCIIDigit)
    }
}

/// Album aliases: `album-<n>`, monotonic, never reused. Persisted as JSON beside the isolated store
/// (`Application Support/control/album-aliases.json`); `fileURL == nil` keeps it in memory (tests).
@MainActor
final class ControlAlbumAliases {
    private var aliasByID: [UUID: String] = [:]
    private var next = 1
    private let fileURL: URL?

    private struct Stored: Codable {
        var next: Int
        var aliases: [String: String]   // project UUID string → alias
    }

    init(fileURL: URL?) {
        self.fileURL = fileURL
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        next = stored.next
        for (key, alias) in stored.aliases {
            if let id = UUID(uuidString: key) { aliasByID[id] = alias }
        }
    }

    /// The alias for `id`, assigning the next number on first sight.
    @discardableResult
    func alias(for id: UUID) -> String {
        if let existing = aliasByID[id] { return existing }
        let alias = "album-\(next)"
        next += 1
        aliasByID[id] = alias
        persist()
        return alias
    }

    /// The project id behind `alias`, if one was ever assigned (deleted projects keep their alias).
    func projectID(for alias: String) -> UUID? {
        aliasByID.first { $0.value == alias }?.key
    }

    /// Assign aliases to any of `projects` not yet aliased — oldest first (`createdAt`, then id) so
    /// albums created through the UI get numbers in the order they were made.
    func registerNew(_ projects: [CurationProject]) {
        let unseen = projects.filter { aliasByID[$0.id] == nil }
        guard !unseen.isEmpty else { return }
        for project in unseen.sorted(by: { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }) {
            alias(for: project.id)
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

    private func persist() {
        guard let fileURL else { return }
        let stored = Stored(next: next, aliases: Dictionary(uniqueKeysWithValues: aliasByID.map {
            ($0.key.uuidString, $0.value)
        }))
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(stored).write(to: fileURL, options: .atomic)
        } catch {
            Log.app.error("control: album-alias write failed: \(String(describing: error), privacy: .public)")
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

#endif
