//
//  ControlMailbox.swift
//  PoimiApp — the control plane's transport: a file mailbox in `Documents/control/` (#298,
//  docs/plans/control-plane.md §4 C). DEBUG-only (D30).
//
//  The CLI writes `req-<n>.json` (to a temporary name, then renamed, so the app never reads half a
//  request); the app handles requests in ascending `n`, ONE at a time, writes `res-<n>.json` atomically
//  (`Data.write(.atomic)`: a temporary file renamed over the target) and deletes the request. No socket:
//  no Local Network prompt, no port, no token — the simulator's container is reachable only by the Mac's
//  user. A `DispatchSource` on the directory wakes the app on every change; a cheap poll backs it up
//  (a directory source can coalesce or miss events).
//
#if DEBUG

import Foundation

@MainActor
final class ControlMailbox {
    private let directory: URL
    private let host: ControlHost
    private let pollInterval: Duration
    private var source: (any DispatchSourceFileSystemObject)?
    private var poller: Task<Void, Never>?
    private var draining = false
    private var drainAgain = false
    /// The drain in progress (tests await it; never a fixed sleep).
    private var drainTask: Task<Void, Never>?

    init(directory: URL, host: ControlHost, pollInterval: Duration = .milliseconds(250)) {
        self.directory = directory
        self.host = host
        self.pollInterval = pollInterval
    }

    /// Start watching. Requests already waiting are handled on the first pass.
    func start() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.path, O_EVTONLY)
        if descriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .extend, .rename, .link], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.poke() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            self.source = source
        } else {
            Log.app.error("control: can't watch the mailbox; polling only")
        }
        let interval = pollInterval
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)   // the fallback poll, not a timing assumption
                self?.poke()
            }
        }
        poke()
    }

    func stop() {
        source?.cancel()
        source = nil
        poller?.cancel()
        poller = nil
    }

    /// Something may have arrived: drain, or ask the running drain to look again when it's done.
    func poke() {
        guard !draining else {
            drainAgain = true
            return
        }
        draining = true
        drainTask = Task { [weak self] in
            await self?.drain()
        }
    }

    /// Await the drain in progress, if any.
    func awaitDrain() async {
        while let task = drainTask {
            await task.value
            if drainTask == task { drainTask = nil }
        }
    }

    private func drain() async {
        repeat {
            drainAgain = false
            for (number, url) in pendingRequests() {
                await handle(number, url)
            }
        } while drainAgain
        draining = false
    }

    /// `req-<n>.json` files, in ascending `n`.
    func pendingRequests() -> [(Int, URL)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name -> (Int, URL)? in
            guard name.hasPrefix("req-"), name.hasSuffix(".json"),
                  let number = Int(name.dropFirst(4).dropLast(5)), number >= 0 else { return nil }
            return (number, directory.appendingPathComponent(name))
        }
        .sorted { $0.0 < $1.0 }
    }

    private func handle(_ number: Int, _ url: URL) async {
        guard let data = try? Data(contentsOf: url) else { return }   // renamed away meanwhile
        try? FileManager.default.removeItem(at: url)                    // taken: never handled twice
        let response = await host.handle(data: data, fileID: number)
        let reply = response.json(run: host.currentRun, rev: host.currentRev)
        do {
            try reply.serialized().write(to: directory.appendingPathComponent("res-\(number).json"), options: .atomic)
        } catch {
            Log.app.error("control: reply \(number) not written: \(String(describing: error), privacy: .public)")
        }
    }
}

#endif
