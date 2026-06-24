//
//  SelectionSnapshot.swift
//  Curation — the durable shape of a project's selection (issue #29, D15).
//
//  Selection is an in-memory `Set<String>` (the source of truth, mutated on every tap); this
//  is its **debounced durable copy** — encoded to `Data` and stored on the `CurationProject`
//  (§9/§12). It is a *versioned envelope* on purpose: when the persisted shape needs to grow
//  (e.g. per-asset metadata, ordering), bumping `version` lets a reader migrate old blobs
//  instead of silently decoding to an empty set and wiping a user's picks.
//
//  Pure Foundation — no SwiftData/PhotoKit — so the encode/decode contract is tested headlessly.
//

import Foundation

/// A versioned, `Codable` envelope around the selected asset ids.
public struct SelectionSnapshot: Codable, Sendable, Equatable {
    /// The current on-disk envelope version. Bump when the stored shape changes.
    public static let currentVersion = 1

    /// The envelope version this value was created with / decoded from.
    public let version: Int

    /// The selected asset ids (`PHAsset.localIdentifier`s).
    public let assetIDs: Set<String>

    public init(assetIDs: Set<String>) {
        self.version = Self.currentVersion
        self.assetIDs = assetIDs
    }

    /// An empty selection (also the safe fallback for an unreadable blob).
    public static let empty = SelectionSnapshot(assetIDs: [])
}

extension SelectionSnapshot {
    /// Encode for storage on the project.
    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// Decode a stored blob **tolerantly**: a nil/empty/corrupt/wrong-shape blob yields `.empty`
    /// rather than throwing. The whole point of the envelope (D15) is that a decode miss degrades
    /// to "no picks yet", never a hard failure on the load path; the caller logs the miss.
    ///
    /// A *same-shape* future-version blob (`{"version": 2, "assetIDs": [...]}`) decodes as-is —
    /// `version` is preserved, the ids are kept — so a newer build's picks are never wiped by an
    /// older one. The `version` field is the hook a future build branches on to migrate; until
    /// then there is intentionally no `version > currentVersion → .empty` quarantine.
    public static func decode(_ data: Data?) -> SelectionSnapshot {
        guard let data, !data.isEmpty else { return .empty }
        guard let decoded = try? JSONDecoder().decode(SelectionSnapshot.self, from: data) else {
            return .empty
        }
        return decoded
    }
}
