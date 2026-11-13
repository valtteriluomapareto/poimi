//
//  ControlMailbox.swift
//  PoimiApp — the control plane's transport: a file mailbox in `Documents/control/` (#298,
//  docs/plans/control-plane.md §4 C). DEBUG-only (D30).
//
//  The CLI writes `req-<n>.json` (to a temporary name, then renamed, so the app never reads half a
//  request). The app takes each request (removing the file, so it's handled once), handles them in
//  ascending `n` ONE AT A TIME — except `wait`s, which run alongside, so an action never queues behind a
//  wait — and writes `res-<n>.json` atomically (`Data.write(.atomic)`: a temporary file renamed over the
//  target), after bringing `state.json` up to date. A `req-*.json` without a number gets a `badRequest`
//  reply (`res-<rest>.json`, id null) rather than lying there forever. No socket: no Local Network
//  prompt, no port, no token — the simulator's container is reachable only by the Mac's user. A
//  `DispatchSource` on the directory wakes the app on every change; a cheap poll backs it up (a directory
//  source can coalesce or miss events).
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
    /// The drain in progress, and the waits running alongside it (tests await them; never a fixed sleep).
    private var drainTask: Task<Void, Never>?
    private var waits: [Int: Task<Void, Never>] = [:]
    private var nextWait = 0

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

    /// Await the drain in progress and every wait it started.
    func awaitDrain() async {
        while true {
            if let task = drainTask {
                await task.value
                if drainTask == task { drainTask = nil }
            } else if let wait = waits.values.first {
                await wait.value
            } else {
                return
            }
        }
    }

    private func drain() async {
        repeat {
            drainAgain = false
            for (number, url) in pendingRequests() {
                await take(number, url)
            }
        } while drainAgain
        draining = false
    }

    /// `req-*.json` files, numbered ones in ascending `n`, unnumbered (malformed) ones first with `nil`.
    func pendingRequests() -> [(Int?, URL)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name -> (Int?, URL)? in
            guard name.hasPrefix("req-"), name.hasSuffix(".json") else { return nil }
            let number = Int(name.dropFirst(4).dropLast(5)).flatMap { $0 >= 0 ? $0 : nil }
            return (number, directory.appendingPathComponent(name))
        }
        .sorted { ($0.0 ?? -1) < ($1.0 ?? -1) }
    }

    /// Take one request: a wait runs on its own task; everything else is handled before the next request.
    private func take(_ number: Int?, _ url: URL) async {
        guard let data = try? Data(contentsOf: url) else { return }   // renamed away meanwhile (withdrawn)
        try? FileManager.default.removeItem(at: url)                    // taken: never handled twice
        let replyName = "res-" + url.lastPathComponent.dropFirst(4)
        switch host.request(from: data, fileID: number) {
        case .reply(let response):
            await write(response, to: replyName)
        case .request(let request):
            if case .wait = request.command {
                let key = nextWait
                nextWait += 1
                waits[key] = Task { [weak self, host] in
                    let response = await host.handle(request)
                    await self?.write(response, to: replyName)
                    self?.waits[key] = nil
                }
            } else {
                await write(await host.handle(request), to: replyName)
            }
        }
    }

    private func write(_ response: ControlResponse, to name: String) async {
        let reply = await host.reply(response)
        do {
            try reply.serialized().write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch {
            let reason = String(describing: error)
            Log.app.error("control: reply \(name, privacy: .public) not written: \(reason, privacy: .public)")
        }
    }
}

#endif
