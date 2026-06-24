//
//  Log.swift
//  PoimiApp — unified logging (issue #48).
//
//  A thin façade over `os.Logger`, one category per impure subsystem. Logging lives in the
//  app target, not in `Curation` (the pure domain stays side-effect-free).
//
//  Retrieve a run's `.notice`+ logs from a booted simulator with:
//
//      xcrun simctl spawn booted log show \
//        --predicate 'subsystem == "com.valtteriluoma.poimi"' \
//        --last 2m --style compact
//
//  `.info`/`.debug` aren't persisted to the store, so `log show` won't surface them after the
//  fact — use live `log stream --level debug` with the same predicate. See README "Debugging".
//
//  Privacy: the unified log redacts interpolated values by default. We log only ids, counts,
//  and states (never photo content), so those interpolations are marked `privacy: .public`
//  at the call site to stay readable.
//

import OSLog

enum Log {
    static let subsystem = "com.valtteriluoma.poimi"

    /// PhotoKit access / fetch / export (the `PhotoLibrary` actor + seam).
    static let photoLibrary = Logger(subsystem: subsystem, category: "PhotoLibrary")
    /// SwiftData persistence — `ProjectStore` CRUD + saves.
    static let persistence = Logger(subsystem: subsystem, category: "Persistence")
    /// Selection + snapshot debounce/flush (`SelectionStore`).
    static let selection = Logger(subsystem: subsystem, category: "Selection")
    /// App-level / composition root / catch-all.
    static let app = Logger(subsystem: subsystem, category: "App")

    // Further categories (Navigation, …) are added alongside the first code that logs to them
    // — not pre-declared, so every category here has a live caller.
}
