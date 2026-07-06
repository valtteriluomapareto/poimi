//
//  AppSchema.swift
//  PoimiApp — the SwiftData schema + container (issue #29; architecture §9, data model).
//
//  A `VersionedSchema` from v1. **v2 (issue #130) adds `GeocodedPlaceName`** — the D18 geocoded-name
//  cache, a NEW entity — which is the first NON-lightweight-*expressible* change and so activates the
//  migration plan (v2 + a declared stage + passing the plan to `make`).
//
//  Migration policy (deliberate): an ADDITIVE OPTIONAL attribute on the existing `CurationProject`
//  (e.g. `reviewedIDsByDay: Data?`, #89) is handled by SwiftData's AUTOMATIC lightweight migration —
//  it adds the nil column to an existing store with no stage. Because a shared model class (not a
//  per-version snapshot) can't express an explicit `MigrationStage` for such an add, one isn't used for
//  it. A NEW entity is different: it needs a declared v2 + stage + the plan wired into `make`. The
//  stage is still `.lightweight` (a new empty table, no data transform), but it MUST be declared — an
//  empty-`stages` plan traps, and the plan is only passed once a real stage exists.
//  NB: integration tests are all `inMemory` (fresh stores), so a fresh store opens directly at the
//  latest version; the lightweight UPGRADE of an existing on-disk v1 store (adding the empty table) is
//  verified by installing OVER a prior build on device, not by a unit test.
//

import Foundation
import SwiftData

/// v1 schema — the original entity set.
enum AppSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [CurationProject.self] }
}

/// v2 schema (issue #130) — adds `GeocodedPlaceName`, the D18 geocoded-name cache. Additive only.
enum AppSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] { [CurationProject.self, GeocodedPlaceName.self] }
}

/// The migration plan. v1 → v2 is `.lightweight` (a new empty table, no data transform), but declared
/// (an empty-`stages` plan traps if passed to `ModelContainer`). Append the next schema + stage here as
/// entities/fields land (e.g. `NamedLocation`, Phase 3).
enum AppMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [AppSchemaV1.self, AppSchemaV2.self] }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: AppSchemaV1.self, toVersion: AppSchemaV2.self)]
    }
}

enum AppModelContainer {
    /// The active schema (the latest `VersionedSchema`).
    static let schema = Schema(versionedSchema: AppSchemaV2.self)

    /// Build the app's `ModelContainer`. `inMemory` backs the integration tests (a fresh,
    /// disposable store per test) and is never used in the running app.
    static func make(inMemory: Bool = false) throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        // The plan now carries a real stage (v1 → v2), so it's passed to the container: an existing v1
        // on-disk store upgrades lightweight; a fresh store opens directly at v2.
        return try ModelContainer(for: schema, migrationPlan: AppMigrationPlan.self, configurations: configuration)
    }
}
