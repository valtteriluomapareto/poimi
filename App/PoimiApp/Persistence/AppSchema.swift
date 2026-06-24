//
//  AppSchema.swift
//  PoimiApp — the SwiftData schema + container (issue #29; architecture §9, data model).
//
//  A `VersionedSchema` from v1 (the project entity will gain fields, and other entities —
//  `NamedLocation` v1.1, the `ResourceSizeCacheEntry` D18 cache — join later versions). Wiring
//  the migration plan now means a future field add is a declared stage, not an ad-hoc reset.
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
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: CurationProject.self, configurations: configuration)
    }
}
