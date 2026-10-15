//
//  AppSchema.swift
//  PoimiApp — the SwiftData schema + container (issue #29; architecture §9, data model).
//
//  Every schema change so far is ADDITIVE: new optional/defaulted attributes on `CurationProject`
//  (`reviewedIDsByDay` #89, `locationEnabled` #130) and a new entity (`GeocodedPlaceName`, the D18
//  geocoded-name cache #130). SwiftData's AUTOMATIC lightweight migration handles all of these in place
//  (adds the columns/tables to an existing store) when NO migration plan is passed.
//
//  Why NOT a staged `SchemaMigrationPlan`: the app uses ONE shared model class per entity (not a frozen
//  per-version copy). A staged plan pins each on-disk store to a known version *hash*, and mutating the
//  shared class changes that hash — so staged migration then rejects any pre-existing store with
//  "Cannot use staged migration with an unknown model version" (learned the hard way wiring #130). The
//  version identifier still advances (v2) so the store is stamped, but the upgrade path is automatic,
//  not staged. The FIRST non-additive change (a rename / type change / data transform) is what will
//  finally require a real versioned plan — and only then must the models be frozen per version.
//
//  MigrationFixtureTests opens copies of real historical stores from PoimiAppTests/Fixtures using
//  this schema, then checks preservation, activation, media switches, reconciliation and disk durability.
//  Other store tests use fresh in-memory containers. Fixture provenance/generation and the remaining
//  install-over-prior-build release check are documented in docs/deploy/migration-testing.md (#290).
//

import Foundation
import SwiftData

/// The current schema — every persisted model. Versioned so the store carries a stamp; additive changes
/// ride automatic lightweight migration (see the file note on why a staged plan can't be used here).
enum AppSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] { [CurationProject.self, GeocodedPlaceName.self] }
}

enum AppModelContainer {
    /// The active schema (the latest `VersionedSchema`).
    static let schema = Schema(versionedSchema: AppSchemaV2.self)

    /// Build the app's `ModelContainer`. `inMemory` backs fresh-store tests and the DEBUG screenshot
    /// harness. Historical-fixture tests configure their own temporary URL. No migration plan — additive changes ride
    /// SwiftData automatic lightweight migration (file note).
    static func make(inMemory: Bool = false) throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: schema, configurations: configuration)
    }
}
