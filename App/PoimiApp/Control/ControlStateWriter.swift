//
//  ControlStateWriter.swift
//  PoimiApp — keeps `state.json` + `state-detail.json` current (#296, docs/plans/control-plane.md §5).
//  DEBUG-only (D30).
//
//  The observe → coalesce → revise → write loop, independent of where the files go (`ControlStateSink`)
//  so the integration tests drive it with an in-memory sink.
//
//  Observation: `withObservationTracking`'s `onChange` fires BEFORE the change lands, and only once.
//  So `onChange` only *schedules* a flush; the flush runs ~100 ms later (coalescing the burst), and
//  in ONE pass re-arms the tracking and computes the snapshot from the now-settled values.
//
#if DEBUG

import Foundation
import Observation

/// Which snapshot file a write is for.
enum ControlStateFile: Sendable, Equatable {
    case state
    case detail
}

/// Where snapshots go. Called on the main actor, in order: per revision, detail first, then state —
/// so once a reader sees a new `rev` in `state.json`, the matching detail is already there.
@MainActor
protocol ControlStateSink: AnyObject {
    func write(_ json: ControlJSON, to file: ControlStateFile)
}

@MainActor
final class ControlStateWriter {
    let run: String
    private let inputs: () -> ControlSnapshotInputs
    private let sink: any ControlStateSink
    private let delay: Duration
    private let detailCache = ControlDetailCache()
    private var revision = ControlRevision()
    private var flushTask: Task<Void, Never>?

    /// The revision last written (0 before the first write).
    var rev: Int { revision.rev }

    init(run: String, delay: Duration = .milliseconds(100), sink: any ControlStateSink,
         inputs: @escaping () -> ControlSnapshotInputs) {
        self.run = run
        self.delay = delay
        self.sink = sink
        self.inputs = inputs
    }

    /// Write the first snapshot now and start observing.
    func start() { flush() }

    /// Await the scheduled flush, if any (tests; never a fixed sleep).
    func awaitScheduledFlush() async { await flushTask?.value }

    var isFlushScheduled: Bool { flushTask != nil }

    private func scheduleFlush() {
        guard flushTask == nil else { return }   // one flush per burst
        let delay = delay
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            flushTask = nil   // a change during the flush below schedules the next one
            flush()
        }
    }

    /// Re-arm observation and compute content + detail in one tracked pass; bump `rev` and write both
    /// files iff either changed (a picks swap that only `state-detail.json` shows still bumps `rev`).
    func flush() {
        let inputs = inputs()
        // Assign aliases to albums created since the last pass — outside the tracked projection, so
        // building the snapshot itself stays free of side effects.
        inputs.albumAliases.assignNew(inputs.projects.projects)
        let cache = detailCache
        let (content, detail) = withObservationTracking {
            (ControlSnapshot.content(inputs), ControlSnapshot.detail(inputs, cache: cache))
        } onChange: { [weak self] in
            Task { @MainActor in self?.scheduleFlush() }
        }
        guard revision.record(.array([content, detail])) else { return }
        sink.write(ControlSnapshot.stamped(detail, run: run, rev: revision.rev), to: .detail)
        sink.write(ControlSnapshot.stamped(content, run: run, rev: revision.rev), to: .state)
    }
}

/// Writes snapshots to `Documents/control/`. Serialization and the `.atomic` write (a temporary file
/// renamed over the target, so a reader never sees a half-written file) run on ONE background task
/// consuming an ordered stream — off the main actor, and never out of order.
@MainActor
final class ControlFileSink: ControlStateSink {
    private struct Write: Sendable {
        let json: ControlJSON
        let url: URL
    }

    private let paths: ControlPaths
    private let writes: AsyncStream<Write>.Continuation

    init(paths: ControlPaths) {
        self.paths = paths
        let (stream, continuation) = AsyncStream.makeStream(of: Write.self)
        writes = continuation
        Task.detached(priority: .utility) {
            for await write in stream {
                do {
                    try write.json.serialized().write(to: write.url, options: .atomic)
                } catch {
                    Log.app.error("control: state write failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    func write(_ json: ControlJSON, to file: ControlStateFile) {
        writes.yield(Write(json: json, url: file == .state ? paths.state : paths.detail))
    }
}

#endif
