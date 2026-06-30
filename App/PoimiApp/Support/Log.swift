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
    /// UI interaction timing (#36 device tuning) — durations of the viewer/grid hot paths so hangs
    /// surface as raw numbers, not guesswork. Written via `Perf`, which no-ops in Release.
    static let perf = Logger(subsystem: subsystem, category: "Perf")

    // Further categories (Navigation, …) are added alongside the first code that logs to them
    // — not pre-declared, so every category here has a live caller.
}

/// Lightweight timing for UI interactions. Every entry point is `#if DEBUG`-gated to a no-op in
/// Release, so instrumenting the hot paths costs nothing shipped (D30 spirit). Levels escalate with
/// duration, so on device you can stream just the trouble:
///
///     xcrun simctl spawn booted log stream --level debug \
///       --predicate 'subsystem == "com.valtteriluoma.poimi" AND category == "Perf"'
///
/// or read the Xcode console directly. `⏱` lines are synchronous (main-thread, frame-budget scale:
/// ≥16ms `jank`, ≥100ms `HANG`); `⥥` lines are awaited I/O (looser: ≥250ms `slow`); `•` lines are
/// timestamped markers — read the gap between them to see transition/render time no block can wrap.
enum Perf {
    /// A timestamped marker (e.g. "tap → openPhoto", "pop"). The gap to the next line is the
    /// transition/render cost the `measure` blocks can't enclose.
    static func event(_ label: @autoclosure () -> String) {
        #if DEBUG
        let text = label()   // evaluate before the logger's escaping interpolation captures it
        Log.perf.notice("• \(text, privacy: .public)")
        #endif
    }

    /// Time a synchronous (usually main-thread) block; judged on the 60fps frame budget.
    @discardableResult
    static func measure<T>(_ label: @autoclosure () -> String, _ body: () -> T) -> T {
        #if DEBUG
        let start = DispatchTime.now()
        let result = body()
        emitFrame(label(), since: start)
        return result
        #else
        return body()
        #endif
    }

    /// Monotonic start token for an awaited span (paired with `endIO`). Timing awaited work via a
    /// token, not a closure, keeps Swift 6 happy — no non-Sendable closure crosses the actor hop.
    static func begin() -> DispatchTime { DispatchTime.now() }

    /// Log an awaited-I/O span that began at `start` (image load, actor hop) — off-main, looser scale.
    static func endIO(_ label: @autoclosure () -> String, since start: DispatchTime) {
        #if DEBUG
        emitIO(label(), since: start)
        #endif
    }

    #if DEBUG
    private static func ms(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
    }

    private static func emitFrame(_ label: String, since start: DispatchTime) {
        let elapsed = ms(since: start)
        let suffix = elapsed >= 100 ? " ⚠️ HANG" : (elapsed >= 16 ? " · jank" : "")
        let line = "⏱ \(label) \(String(format: "%.1f", elapsed))ms\(suffix)"
        if elapsed >= 100 {
            Log.perf.error("\(line, privacy: .public)")
        } else if elapsed >= 16 {
            Log.perf.notice("\(line, privacy: .public)")
        } else {
            Log.perf.debug("\(line, privacy: .public)")
        }
    }

    private static func emitIO(_ label: String, since start: DispatchTime) {
        let elapsed = ms(since: start)
        let line = "⥥ \(label) \(String(format: "%.1f", elapsed))ms\(elapsed >= 250 ? " · slow" : "")"
        if elapsed >= 250 {
            Log.perf.notice("\(line, privacy: .public)")
        } else {
            Log.perf.debug("\(line, privacy: .public)")
        }
    }
    #endif
}
