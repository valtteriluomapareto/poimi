//
//  ControlLaunch.swift
//  PoimiApp — the control-plane launch flags (#296, docs/plans/control-plane.md §4 slice A).
//
//  ALL control flag parsing lives here, gated as a whole file, so the release guard
//  (Scripts/check-fake-release-isolation.sh) checks this file — not just "a `#if DEBUG` somewhere"
//  (D30). The composition root only calls `ControlLaunch.bootGraph()`.
//
//      -PoimiControl -PoimiFixture <name> [-PoimiRoute <route>] [-PoimiViewer <asset alias>] [-PoimiHeadless]
//      -PoimiControl -PoimiRelaunch [-PoimiRoute …] [-PoimiViewer …] [-PoimiHeadless]   (continue the last run)
//
//  The route grammar is `ControlRoute.parse` (its error text is the usage); fixtures are
//  `ControlFixture`. Albums and assets are the snapshot's aliases, never real ids. User-facing docs:
//  the `poimi-control` skill.
//
#if DEBUG

import Foundation
import Curation

/// A parsed, valid control launch.
struct ControlLaunch: Equatable {
    static let controlFlag = "-PoimiControl"
    static let fixtureFlag = "-PoimiFixture"
    static let routeFlag = "-PoimiRoute"
    static let viewerFlag = "-PoimiViewer"
    /// Run the graph, album session and control host behind a static view instead of `AppRootView`
    /// (#298) — no screen is mounted, so everything the run does goes through the stores.
    static let headlessFlag = "-PoimiHeadless"
    /// Continue the last control run (#300): its store, fake library and aliases as it left them — no
    /// wipe, no seed. Takes no `-PoimiFixture` (the run's own is kept). `Scripts/poimi.sh relaunch`.
    static let relaunchFlag = "-PoimiRelaunch"
    /// The screenshot harness flag — refused alongside `-PoimiControl` (two hosts in one launch would
    /// make it ambiguous which state you're looking at).
    static let screenFlag = "-PoimiScreen"

    let fixture: ControlFixture
    let route: ControlRoute?
    /// An asset alias (`a-0012`) to open in the photo viewer once the review scan is ready.
    let viewer: String?
    /// No UI: a static `ControlHeadlessView` instead of `AppRootView` (#298).
    var headless = false
    /// A relaunch of the last control run (#300): nothing is wiped or seeded.
    var relaunch = false

    /// The outcome of reading the launch arguments.
    enum Parsed: Equatable {
        /// No control flag at all — a normal launch.
        case off
        /// A valid control launch.
        case on(ControlLaunch)
        /// A control flag was passed but the launch is malformed. The app still runs isolated (never
        /// against the real library or store) and shows this message instead of the UI.
        case invalid(String)

        /// The valid launch, if this is one.
        var launch: ControlLaunch? {
            if case .on(let launch) = self { return launch }
            return nil
        }
    }

    /// Parse `arguments` (pure, so tests drive it directly). `recorded` is the last control run on record —
    /// what `-PoimiRelaunch` continues: its fixture, why its record can't be read, or `nil` (nothing to
    /// relaunch).
    static func parse(_ arguments: [String],
                      recorded: Result<ControlFixture, ControlLaunchError>? = nil) -> Parsed {
        let controlFlags = [controlFlag, fixtureFlag, routeFlag, viewerFlag, headlessFlag, relaunchFlag]
        guard arguments.contains(where: controlFlags.contains) else { return .off }
        guard arguments.contains(controlFlag) else {
            return .invalid("\(fixtureFlag), \(routeFlag), \(viewerFlag), \(headlessFlag) and \(relaunchFlag) "
                + "need \(controlFlag)")
        }
        if arguments.contains(screenFlag) {
            return .invalid("\(controlFlag) refuses \(screenFlag) in the same launch")
        }
        let relaunch = arguments.contains(relaunchFlag)
        do throws(ControlLaunchError) {
            let fixture = try self.fixture(in: arguments, relaunch: relaunch, recorded: recorded)
            let route: ControlRoute? = if let raw = try value(of: routeFlag, in: arguments) {
                try ControlRoute.parse(raw)
            } else {
                nil
            }
            let viewer = try value(of: viewerFlag, in: arguments)
            if let viewer {
                guard ControlAssetAliases.isAlias(viewer) else {
                    return .invalid("\(viewerFlag) takes an asset alias like a-0001, got '\(viewer)'")
                }
                guard case .review = route else {
                    return .invalid("\(viewerFlag) needs a review route (\(routeFlag) review:<album>[:<day>])")
                }
            }
            return .on(ControlLaunch(fixture: fixture, route: route, viewer: viewer,
                                     headless: arguments.contains(headlessFlag), relaunch: relaunch))
        } catch {
            return .invalid(error.message)
        }
    }

    /// The launch's fixture: `-PoimiFixture`'s, or — for a relaunch, which takes none — the one on record.
    private static func fixture(in arguments: [String], relaunch: Bool,
                                recorded: Result<ControlFixture, ControlLaunchError>?)
                                throws(ControlLaunchError) -> ControlFixture {
        let name = try value(of: fixtureFlag, in: arguments)
        if relaunch {
            guard name == nil else {
                throw ControlLaunchError("\(relaunchFlag) continues the last run's fixture; it takes no \(fixtureFlag)")
            }
            switch recorded {
            case .success(let fixture)?:
                return fixture
            case .failure(let error)?:
                throw ControlLaunchError("\(relaunchFlag): the run on record can't be read — \(error.message)")
            case nil:
                throw ControlLaunchError(
                    "\(relaunchFlag): no control run on record to continue — launch a fixture first")
            }
        }
        guard let name else {
            throw ControlLaunchError("\(controlFlag) needs \(fixtureFlag) <name>; known: \(ControlFixture.names)")
        }
        guard let fixture = ControlFixture(rawValue: name) else {
            throw ControlLaunchError("unknown fixture '\(name)'; known: \(ControlFixture.names)")
        }
        return fixture
    }

    /// The value following `flag`, `nil` if the flag is absent. A flag with no value (end of the list,
    /// or another `-Poimi…` flag next) is an error rather than a silent default.
    private static func value(of flag: String, in arguments: [String]) throws(ControlLaunchError) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let next = arguments.index(after: index)
        guard next < arguments.endIndex, !arguments[next].hasPrefix("-Poimi") else {
            throw ControlLaunchError("\(flag) needs a value")
        }
        return arguments[next]
    }
}

/// A launch-flag problem, carried as a human-readable message into `state.json` (`app.launchError`).
struct ControlLaunchError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// A launch-time route, in alias terms. Applied through the coordinator's existing methods
/// (`ControlRuntime.apply`), so it reaches exactly the screens a user can.
enum ControlRoute: Equatable {
    case overview(album: String)
    case review(album: String, day: DayKey?)
    case export(album: String)
    case settings(album: String)
    case appSettings

    /// The album alias this route opens, if any.
    var album: String? {
        switch self {
        case .overview(let album), .review(let album, _), .export(let album), .settings(let album): album
        case .appSettings: nil
        }
    }

    /// The route grammar (the usage text and `schema` print it).
    static let grammar = ["overview:<album>", "review:<album>[:<yyyy-mm-dd>]", "export:<album>",
                          "settings:<album>", "appsettings"]

    static func parse(_ raw: String) throws(ControlLaunchError) -> ControlRoute {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let usage = "routes: " + grammar.joined(separator: " | ")
        guard let kind = parts.first else { throw ControlLaunchError("empty route; \(usage)") }
        if kind == "appsettings" {
            guard parts.count == 1 else { throw ControlLaunchError("appsettings takes no album; \(usage)") }
            return .appSettings
        }
        let maxParts = kind == "review" ? 3 : 2
        guard ["overview", "review", "export", "settings"].contains(kind) else {
            throw ControlLaunchError("unknown route '\(kind)'; \(usage)")
        }
        guard parts.count >= 2, parts.count <= maxParts else {
            throw ControlLaunchError("malformed route '\(raw)'; \(usage)")
        }
        let album = parts[1]
        guard ControlAlbumAliases.isAlias(album) else {
            throw ControlLaunchError("route album must be an alias like album-1, got '\(album)'")
        }
        switch kind {
        case "overview": return .overview(album: album)
        case "export": return .export(album: album)
        case "settings": return .settings(album: album)
        default:
            guard parts.count == 3 else { return .review(album: album, day: nil) }
            // Round-trip through `description` so only the canonical form is accepted ("2025-6-1" isn't).
            guard let day = DayKey(parts[2]), day.description == parts[2] else {
                throw ControlLaunchError("route day must be yyyy-mm-dd or 'undated', got '\(parts[2])'")
            }
            return .review(album: album, day: day)
        }
    }
}

extension ControlLaunch {
    /// The composition-root hook: `nil` for a normal launch; otherwise the isolated, fixture-seeded
    /// graph (also for a malformed control launch, which must never fall through to the real library
    /// and store — it runs isolated and shows the refusal instead).
    @MainActor
    static func bootGraph(arguments: [String] = ProcessInfo.processInfo.arguments) -> AppGraph? {
        let parsed = parse(arguments, recorded: ControlRunRecord.recordedRun(at: ControlPaths.standard().record))
        guard parsed != .off else {
            ControlEnvironment.clearForNormalLaunch()   // a normal launch ends any control run
            return nil
        }
        return ControlEnvironment.boot(parsed, relaunchRequested: arguments.contains(relaunchFlag)).graph
    }

    /// Why a control launch was refused (shown in place of the UI), or `nil`.
    @MainActor
    static var refusal: String? { ControlEnvironment.current?.refusal }

    /// Whether this process is a control launch (valid or refused).
    @MainActor
    static var isActive: Bool { ControlEnvironment.current != nil }

    /// The run id of a headless control launch (shown by `ControlHeadlessView`), or `nil` for any other.
    @MainActor
    static var headlessRun: String? {
        guard let runtime = ControlEnvironment.current, runtime.isHeadless else { return nil }
        return runtime.run
    }
}

#endif
