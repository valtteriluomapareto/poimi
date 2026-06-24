//
//  Log.swift
//  PoimiApp — unified logging (issue #48).
//
//  A thin façade over `os.Logger`, one category per impure subsystem. Logging lives in the
//  app target, not in `Curation` (the pure domain stays side-effect-free).
//
//  Retrieve a run's logs from a booted simulator with:
//
//      xcrun simctl spawn booted log show \
//        --predicate 'subsystem == "fi.paretosoftware.poimi"' \
//        --last 2m --info --debug --style compact
//
//  …or stream live with `log stream` and the same predicate. See README "Debugging".
//
//  Privacy: the unified log redacts interpolated values by default. We log only ids, counts,
//  and states (never photo content), so those interpolations are marked `privacy: .public`
//  at the call site to stay readable.
//

import OSLog

enum Log {
    static let subsystem = "fi.paretosoftware.poimi"

    /// PhotoKit access / fetch / export (the `PhotoLibrary` actor + seam).
    static let photoLibrary = Logger(subsystem: subsystem, category: "PhotoLibrary")
    /// Selection + target/running-total state.
    static let selection = Logger(subsystem: subsystem, category: "Selection")
    /// Navigation coordinator + lifecycle.
    static let navigation = Logger(subsystem: subsystem, category: "Navigation")
    /// App-level / composition root / catch-all.
    static let app = Logger(subsystem: subsystem, category: "App")
}
