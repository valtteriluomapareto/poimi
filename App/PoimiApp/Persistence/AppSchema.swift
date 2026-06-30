//
//  AppSchema.swift
//  PoimiApp — the SwiftData schema + container (issue #29; architecture §9, data model).
//
//  A `VersionedSchema` from v1 (the project entity will gain fields, and other entities —
//  `NamedLocation` v1.1, the `ResourceSizeCacheEntry` D18 cache — join later versions). Wiring
//  the migration plan now means a future field add is a declared stage, not an ad-hoc reset.
//
//  Migration policy (deliberate): an ADDITIVE OPTIONAL attribute on the existing `CurationProject`
//  (e.g. `reviewedIDsByDay: Data?`, #89) is handled by SwiftData's AUTOMATIC lightweight migration —
//  it adds the nil column to an existing store with no stage. Because v1 is a single shared model
//  class (not a per-version snapshot), an explicit `MigrationStage` for such an add isn't even
//  expressible without freezing an old model copy, and isn't needed. The version stamp therefore
//  stays `1.0.0` and the plan stays empty until a NON-lightweight change (a rename, a type change, a
//  new entity) lands — that's when v2 + a declared stage + passing the plan to `make` are required.
//  NB: integration tests are all `inMemory` (fresh stores), so the lightweight upgrade of an existing
//  on-disk store is verified by installing OVER a prior build on device, not by a unit test.
//

import Foundation
import SwiftData

/// v1 schema — the entities persisted today.
enum AppSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [CurationProject.self] }
}

/// The migration plan. A single version today (so no stages — nothing to migrate yet); when
/// v2 lands it appends its schema + a stage here, and `make` starts passing it to the container.
/// Note: a plan with an empty `stages` array is *not* passed to `ModelContainer` — SwiftData
/// traps trying to compute a migration path it doesn't have.
enum AppMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [AppSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

enum AppModelContainer {
    /// The active schema (the latest `VersionedSchema`).
    static let schema = Schema(versionedSchema: AppSchemaV1.self)

    /// Build the app's `ModelContainer`. `inMemory` backs the integration tests (a fresh,
    /// disposable store per test) and is never used in the running app.
    static func make(inMemory: Bool = false) throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        // Route through the versioned schema so the v1 version stamp is bound (the whole point
        // of VersionedSchema). The migration plan is NOT passed yet — an empty-`stages` plan
        // traps; add `migrationPlan: AppMigrationPlan.self` here once v2's first stage lands.
        return try ModelContainer(for: schema, configurations: configuration)
    }
}
