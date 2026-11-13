//
//  ControlMachineryTests.swift
//  PoimiAppTests — the control plane's machinery (#298): strict decoding, every refusal reason, value
//  typing in predicates, `timeoutMs` bounds, `staleRun`, schema ↔ snapshot path parity, every action
//  exercised at least once, the seq / settledSeq / idle bookkeeping, and the file mailbox (ordering,
//  atomic replies, waits never holding sends). In-process; every wait awaits real work — never a fixed sleep.
//

import Testing
import Foundation
import Curation
@testable import PoimiApp

/// A request envelope as an agent writes it.
private func envelope(_ body: String, id: Int = 1, run: String = "r-test", v: String = "1") -> Data {
    Data(#"{"v":\#(v),"id":\#(id),"run":"\#(run)",\#(body)}"#.utf8)
}

private func decodeError(_ data: Data) -> ControlRequestError? {
    do throws(ControlRequestError) {
        _ = try ControlRequest.decode(data)
        return nil
    } catch {
        return error
    }
}

@MainActor
@Suite("Control plane: decoding (#298)")
struct ControlDecodingTests {

    @Test("a well-formed request of every command decodes")
    func decodesEveryCommand() throws {
        let send = try ControlRequest.decode(envelope(#""cmd":"send","action":{"type":"nav.openAlbum","album":"album-1"}"#))
        #expect(send.command == .send(.navOpenAlbum(album: "album-1")))
        #expect(try ControlRequest.decode(envelope(#""cmd":"snapshot""#)).command == .snapshot)
        #expect(try ControlRequest.decode(envelope(#""cmd":"schema""#)).command == .schema)
        let wait = try ControlRequest.decode(envelope(
            #""cmd":"wait","predicates":[{"path":".idle","op":"eq","value":true}],"timeoutMs":0"#))
        #expect(wait.command == .wait([ControlPredicate(path: "idle", op: .eq, value: .bool(true))], timeoutMs: 0))
        let fixture = try ControlRequest.decode(envelope(#""cmd":"fixture","fixture":{"op":"flush"}"#))
        #expect(fixture.command == .fixture(.flush))
    }

    @Test("strict: unknown keys, commands, actions, ops, wrong types and versions are refused", arguments: [
        (#""cmd":"snapshot","extra":1"#, "unknown key"),
        (#""cmd":"nope""#, "unknown cmd"),
        (#""cmd":"send","action":{"type":"nav.fly"}"#, "unknown action"),
        (#""cmd":"send","action":{"type":"nav.openAlbum","album":"album-1","day":"2025-01-06"}"#, "unknown key"),
        (#""cmd":"send","action":{"type":"nav.openAlbum"}"#, "missing"),
        (#""cmd":"send","action":{"type":"nav.openAlbum","album":1}"#, "must be a string"),
        (#""cmd":"send","action":{"type":"nav.openAlbum","album":"Best of 2025"}"#, "album alias"),
        (#""cmd":"send","action":{"type":"viewer.open","photo":"ctl/1"}"#, "photo alias"),
        (#""cmd":"send","action":{"type":"done.toggle","day":"2025-1-6"}"#, "yyyy-mm-dd"),
        (#""cmd":"send","action":{"type":"albums.create","start":"2025-01-01","end":"2025-12-31","target":"80"}"#,
         "must be an integer"),
        (#""cmd":"send","action":{"type":"albums.create","start":"2025-01-01","end":"2025-12-31","target":0}"#,
         "target"),
        (#""cmd":"send","action":{"type":"albums.update","album":"album-1"}"#, "at least one field"),
        (#""cmd":"send","action":{"type":"albums.update","album":"album-1","media":"all"}"#, "media"),
        (#""cmd":"send","action":{"type":"selection.select","photos":["a-0001"]}"#, "unknown action"),
        (#""cmd":"send","action":{"type":"selection.toggleCluster"}"#, "missing 'day'"),
        (#""cmd":"send","action":{"type":"export.retry","newAlbum":"yes"}"#, "true or false"),
        (#""cmd":"fixture","fixture":{"op":"selection.select","photos":[]}"#, "empty"),
        (#""cmd":"fixture","fixture":{"op":"selection.select","photos":["ctl/1"]}"#, "photo alias"),
        (#""cmd":"fixture","fixture":{"op":"explode"}"#, "unknown fixture op"),
        (#""cmd":"fixture","fixture":{"op":"library.failFetch","kind":"timeout"}"#, "kind"),
        (#""cmd":"fixture","fixture":{"op":"library.authorization","status":"maybe"}"#, "unknown status"),
        (#""cmd":"wait","predicates":[]"#, "at least one predicate"),
        (#""cmd":"wait","predicates":[{"path":"idle","op":"is","value":true}]"#, "unknown op"),
        (#""cmd":"wait","predicates":[{"path":"idle","op":"eq"}]"#, "needs a value"),
        (#""cmd":"wait","predicates":[{"path":"idle","op":"eq","value":true,"x":1}]"#, "unknown key"),
        (#""cmd":"wait","predicates":[{"path":"rev","op":"gte","value":"10"}]"#, "integer value"),
        (#""cmd":"wait","predicates":[{"path":"rev","op":"eq","value":1.5}]"#, "integers"),
        (#""cmd":"wait","predicates":[{"path":"idle","op":"exists","value":1}]"#, "true/false")
    ])
    func strict(_ body: String, _ fragment: String) throws {
        let error = try #require(decodeError(envelope(body)))
        #expect(error.code == .badRequest)
        #expect(error.message.localizedCaseInsensitiveContains(fragment), "\(error.message)")
    }

    @Test("the protocol version: only v1; a missing or mistyped v is a bad request")
    func version() throws {
        #expect(decodeError(envelope(#""cmd":"snapshot""#, v: "2"))?.code == .unsupportedVersion)
        #expect(decodeError(envelope(#""cmd":"snapshot""#, v: "\"1\""))?.code == .badRequest)
        #expect(decodeError(Data(#"{"id":1,"run":"r","cmd":"snapshot"}"#.utf8))?.code == .badRequest)
        #expect(decodeError(Data("not json".utf8))?.code == .badRequest)
    }

    @Test("timeoutMs bounds: 0 and 30000 accepted, -1 and 30001 refused, absent → the default")
    func timeoutBounds() throws {
        func wait(_ timeout: String) -> String {
            #""cmd":"wait","predicates":[{"path":"idle","op":"eq","value":true}]"# + timeout
        }
        #expect(try ControlRequest.decode(envelope(wait(#","timeoutMs":0"#))).command
            == .wait([ControlPredicate(path: "idle", op: .eq, value: .bool(true))], timeoutMs: 0))
        #expect(decodeError(envelope(wait(#","timeoutMs":30000"#))) == nil)
        #expect(decodeError(envelope(wait(#","timeoutMs":30001"#)))?.message.contains("timeoutMs") == true)
        #expect(decodeError(envelope(wait(#","timeoutMs":-1"#)))?.code == .badRequest)
        guard case .wait(_, let timeout) = try ControlRequest.decode(envelope(wait(""))).command else {
            Issue.record("not a wait")
            return
        }
        #expect(timeout == ControlRequest.defaultTimeoutMs)
    }

    @Test("predicate values keep their JSON type: 10, \"10\", null, true; exists defaults to true")
    func predicateValueTyping() throws {
        func predicate(_ json: String) throws -> ControlPredicate {
            try JSONDecoder().decode(ControlPredicate.self, from: Data(json.utf8))
        }
        #expect(try predicate(#"{"path":"rev","op":"eq","value":10}"#).value == .int(10))
        #expect(try predicate(#"{"path":"rev","op":"eq","value":"10"}"#).value == .string("10"))
        #expect(try predicate(#"{"path":"rev","op":"eq","value":null}"#).value == .null)
        #expect(try predicate(#"{"path":"idle","op":"eq","value":true}"#).value == .bool(true))
        #expect(try predicate(#"{"path":"idle","op":"eq","value":1}"#).value == .int(1))   // not a bool
        #expect(try predicate(#"{"path":"albums.album-2","op":"exists"}"#).value == .bool(true))
    }
}

@MainActor
@Suite("Control plane: predicates (#298)")
struct ControlPredicateTests {
    private let state: ControlJSON = .object(("count", .int(10)), ("text", .string("10")), ("none", .null),
                                             ("nested", .object(("flag", .bool(false)))))

    private func holds(_ path: String, _ op: ControlPredicate.Op, _ value: ControlJSON) -> Bool {
        ControlWait.unmet([ControlPredicate(path: path, op: op, value: value)], in: state).isEmpty
    }

    /// One row of the operator table: does `path op value` hold against `state`?
    struct Case: Sendable, CustomTestStringConvertible {
        let path: String
        let op: ControlPredicate.Op
        let value: ControlJSON
        let holds: Bool
        init(_ path: String, _ op: ControlPredicate.Op, _ value: ControlJSON, _ holds: Bool) {
            (self.path, self.op, self.value, self.holds) = (path, op, value, holds)
        }
        var testDescription: String { "\(path) \(op.rawValue) \(value) → \(holds)" }
    }

    @Test("operators: eq / ne compare type and value; gte / lte need integers; exists = present and not null",
          arguments: [
        // eq / ne: 10 ≠ "10" ≠ null; a missing path equals nothing.
        Case("count", .eq, .int(10), true), Case("count", .eq, .string("10"), false),
        Case("text", .eq, .string("10"), true), Case("text", .eq, .int(10), false),
        Case("none", .eq, .null, true), Case("missing", .eq, .null, false), Case("missing", .ne, .null, true),
        Case("count", .ne, .string("10"), true), Case("nested.flag", .eq, .bool(false), true),
        // gte / lte: integers on both sides, anything else is unmet.
        Case("count", .gte, .int(10), true), Case("count", .lte, .int(10), true),
        Case("count", .gte, .int(11), false), Case("text", .gte, .int(1), false),
        Case("none", .lte, .int(1), false), Case("missing", .gte, .int(0), false),
        // exists: present AND not null; value false inverts.
        Case("count", .exists, .bool(true), true), Case("none", .exists, .bool(true), false),
        Case("missing", .exists, .bool(true), false), Case("none", .exists, .bool(false), true),
        Case("missing", .exists, .bool(false), true)
    ])
    func operators(_ row: Case) {
        #expect(holds(row.path, row.op, row.value) == row.holds)
    }

    @Test("an unmet predicate reports path, op, expected, observed and presence")
    func unmetReport() {
        let unmet = ControlWait.unmet([ControlPredicate(path: "count", op: .eq, value: .int(3)),
                                       ControlPredicate(path: "missing", op: .exists, value: .bool(true))], in: state)
        #expect(unmet.map(\.json) == [
            .object(("path", .string("count")), ("op", .string("eq")), ("expected", .int(3)),
                    ("observed", .int(10)), ("present", .bool(true))),
            .object(("path", .string("missing")), ("op", .string("exists")), ("expected", .bool(true)),
                    ("observed", .null), ("present", .bool(false)))
        ])
    }

    @Test("declared paths: leaves, containers and one album alias match; typos and depth don't")
    func declared() {
        #expect(ControlSchema.declaredPattern(for: "active.scan.phase") == "active.scan.phase")
        #expect(ControlSchema.declaredPattern(for: "albums.album-12.picked") == "albums.*.picked")
        #expect(ControlSchema.declaredPattern(for: "albums.album-3") == "albums.*")
        #expect(ControlSchema.declaredPattern(for: "active.scan.phaze") == nil)
        #expect(ControlSchema.declaredPattern(for: "albums.album-1.picked.x") == nil)
        #expect(ControlSchema.declaredPattern(for: "idle.") == nil)
    }
}

@MainActor
@Suite("Control plane: host machinery (#298)")
struct ControlHostMachineryTests {

    /// One request through the whole decode → handle path, as the mailbox does.
    private func request(_ harness: ControlHarness, _ body: String, run: String = "r-test") async -> ControlResponse {
        await harness.host.handle(data: envelope(body, id: 7, run: run), fileID: 7)
    }

    @Test("staleRun: a request for another launch's run is refused before anything runs")
    func staleRun() async {
        let harness = await ControlHarness.booted(.oneAlbum)
        let response = await request(harness, #""cmd":"send","action":{"type":"nav.openAlbum","album":"album-1"}"#,
                                     run: "r-old")
        #expect(response.error?.code == .staleRun)
        #expect(harness.coordinator.path.isEmpty)   // nothing ran
        #expect(harness.runtime.progress.lastSeq == 0)
    }

    @Test("the reply envelope: v, id, run, rev, ok + data | error; an id that isn't the file's is refused")
    func replyEnvelope() async throws {
        let harness = await ControlHarness.booted(.oneAlbum)
        let ok = await request(harness, #""cmd":"snapshot""#)
        let json = ok.json(run: "r-test", rev: 3)
        #expect(json["v"] == .int(1) && json["id"] == .int(7) && json["run"] == .string("r-test"))
        #expect(json["rev"] == .int(3) && json["ok"] == .bool(true))
        #expect(json["data"]?["app"]?["fixture"] == .string("one-album"))
        let mismatched = await harness.host.handle(data: envelope(#""cmd":"snapshot""#, id: 8), fileID: 9)
        #expect(mismatched.id == 9 && mismatched.error?.code == .badRequest)
        let bad = await harness.host.handle(data: Data("{".utf8), fileID: 4)
        let badJSON = bad.json(run: "r-test", rev: 1)
        #expect(badJSON["ok"] == .bool(false) && badJSON["error"]?["code"] == .string("badRequest"))
    }

    @Test("wait: an undeclared path fails at once; timeoutMs 0 asserts now; unmet names every predicate")
    func waitErrors() async throws {
        let harness = await ControlHarness.booted(.oneAlbum)
        let started = ContinuousClock.now
        let undeclared = await harness.wait([("active.scan.phaze", .eq, .string("ready"))], timeoutMs: 30_000)
        #expect(ContinuousClock.now - started < .seconds(5))   // immediate, not after the timeout
        guard case .failure(let error) = undeclared else { Issue.record("no error"); return }
        #expect(error.code == .undeclaredPath)

        let now = await harness.wait([("idle", .eq, .bool(true)), ("nav.screen", .eq, .string("review"))], timeoutMs: 0)
        guard case .failure(let unmet) = now else { Issue.record("met?"); return }
        #expect(unmet.code == .unmet)
        #expect(unmet.detail == .array([.object(("path", .string("nav.screen")), ("op", .string("eq")),
                                                ("expected", .string("review")), ("observed", .string("albums")),
                                                ("present", .bool(true)))]))
        let met = await harness.wait([("idle", .eq, .bool(true))], timeoutMs: 0)
        #expect(met.map { $0["met"] } == .success(.bool(true)))
    }

    @Test("wait is Observation-driven: it wakes when the scan an action started lands, before its timeout")
    func waitWakesOnChange() async throws {
        let harness = await ControlHarness.booted(.oneAlbum)
        async let waited = harness.wait([("active.scan.phase", .eq, .string("ready")), ("idle", .eq, .bool(true))],
                                        timeoutMs: 30_000)
        try await harness.send(#"{"type":"nav.openAlbum","album":"album-1"}"#)
        let result = await waited
        #expect(result.map { $0["met"] } == .success(.bool(true)), "\(result)")
    }

    @Test("seq / settledSeq / idle: accepted carries a seq; settled once its async work is done")
    func seqBookkeeping() async throws {
        let harness = await ControlHarness.booted(.oneAlbum)
        #expect(harness.value("lastSeq") == .value(.int(0)))
        let first = try #require(try await harness.send(#"{"type":"nav.openAlbum","album":"album-1"}"#).seq)
        let second = try #require(try await harness.send(#"{"type":"nav.openSettings","album":"album-1"}"#).seq)
        #expect(second == first + 1)
        #expect(harness.value("lastSeq") == .value(.int(second)))
        #expect(harness.value("idle") == .value(.bool(false)))   // the scan hasn't settled
        await harness.settled()
        #expect(harness.value("settledSeq") == .value(.int(second)))
        #expect(harness.value("idle") == .value(.bool(true)))
        // A noop or refusal starts nothing: no seq.
        #expect(try await harness.send(#"{"type":"nav.openSettings","album":"album-1"}"#).seq == nil)
        #expect(harness.value("lastSeq") == .value(.int(second)))
    }

    @Test("idle waits for fake thumbnail loads in flight (pending.thumbnails)")
    func thumbnailsHoldIdle() async throws {
        let harness = await ControlHarness.booted(.oneAlbum)
        harness.thumbnailLoads.begin()
        #expect(harness.value("pending.thumbnails") == .value(.int(1)))
        #expect(harness.value("idle") == .value(.bool(false)))
        harness.thumbnailLoads.end()
        #expect(harness.value("idle") == .value(.bool(true)))
        // The provider counts a real load and is back to zero when it returns.
        let provider = FakeThumbnailProvider(loads: harness.thumbnailLoads)
        _ = await provider.thumbnail(for: "ctl/1", targetSize: CGSize(width: 10, height: 10))
        #expect(harness.thumbnailLoads.inFlight == 0)
    }

    @Test("every refusal reason is reachable, each observed for real")
    func everyRefusal() async throws {
        var seen: Set<ControlRefusal> = []
        func note(_ outcome: ControlOutcome, _ expected: ControlRefusal) {
            #expect(outcome.refusal == expected, "\(outcome)")
            if let reason = outcome.refusal { seen.insert(reason) }
        }
        let gated = GatedLibrary(ControlFixture.midReview.makeLibrary())
        let harness = await ControlHarness.booted(.midReview, library: gated, iPad: true)
        // invalidState: nothing is hydrated yet — never a silent `accepted`.
        note(try await harness.fixtureOp(#"{"op":"selection.clear"}"#), .invalidState)
        // unknownAlias
        note(try await harness.send(#"{"type":"nav.openAlbum","album":"album-9"}"#), .unknownAlias)
        // notShown: the viewer opens only on the grid.
        try await harness.send(#"{"type":"nav.openAlbum","album":"album-1"}"#)
        await harness.settled()
        note(try await harness.send(#"{"type":"viewer.open","photo":"a-0001"}"#), .notShown)
        // unavailable: a reset is a relaunch.
        note(try await harness.fixtureOp(#"{"op":"reset","fixture":"one-album"}"#), .unavailable)
        // busy: an export held in flight.
        await gated.hold(exports: true)
        #expect(try await harness.send(#"{"type":"nav.openExport"}"#).isAccepted)
        await gated.waitUntilHeld()
        note(try await harness.send(#"{"type":"albums.delete","album":"album-1"}"#), .busy)
        await gated.release()
        await harness.settled()
        #expect(seen == Set(ControlRefusal.allCases))
    }

    /// Every action, at least once, through the host — enumerated from `ControlActionKind` and classified
    /// by the DECODED action, so a new action without a test here fails.
    @Test("every action is exercised at least once, and accepted")
    func everyAction() async throws {
        var exercised: Set<ControlActionKind> = []
        func send(_ harness: ControlHarness, _ json: String) async throws {
            let action = try JSONDecoder().decode(ControlAction.self, from: Data(json.utf8))
            exercised.insert(action.kind)
            let outcome = harness.host.perform(action)
            #expect(outcome.isAccepted, "\(json) → \(outcome)")
        }
        // Onboarding: the fake answers the prompt with what it's told to.
        let fresh = await ControlHarness.booted(.fresh)
        try await fresh.fixtureOp(#"{"op":"library.authorization","status":"authorized"}"#)
        try await send(fresh, #"{"type":"auth.request"}"#)
        await fresh.settled()
        #expect(fresh.value("app.rootPhase") == .value(.string("albums")))

        let harness = await ControlHarness.booted(.oneAlbum)
        try await send(harness, #"{"type":"ui.present","modal":"newAlbum"}"#)
        try await send(harness,
            #"{"type":"albums.create","title":"Summer","start":"2025-06-01","end":"2025-08-31","target":40}"#)
        await harness.settled()
        #expect(harness.value("nav.screen") == .value(.string("overview")))
        #expect(harness.value("albums.album-2.target") == .value(.int(40)))
        try await send(harness, #"{"type":"nav.root"}"#)
        try await send(harness, #"{"type":"ui.present","modal":"newAlbum"}"#)
        try await send(harness, #"{"type":"ui.dismiss"}"#)
        try await send(harness, #"{"type":"albums.duplicate","album":"album-2"}"#)
        #expect(harness.value("albums.album-3") != .missing)
        try await send(harness, #"{"type":"albums.delete","album":"album-3"}"#)
        try await send(harness, #"{"type":"albums.reset","album":"album-2"}"#)
        try await send(harness, #"{"type":"nav.openAppSettings"}"#)
        try await send(harness, #"{"type":"nav.back"}"#)

        try await send(harness, #"{"type":"nav.openAlbum","album":"album-1"}"#)
        await harness.settled()
        try await send(harness, #"{"type":"review.setFilter","filter":"toReview"}"#)
        try await send(harness, #"{"type":"nav.openSettings","album":"album-1"}"#)
        try await send(harness,
            #"{"type":"albums.update","album":"album-1","title":"Year","target":60,"locationEnabled":false}"#)
        #expect(harness.value("albums.album-1.target") == .value(.int(60)))
        try await send(harness, #"{"type":"albums.markAllUnreviewed","album":"album-1"}"#)
        try await send(harness, #"{"type":"ui.present","modal":"confirmReset","album":"album-1"}"#)
        try await send(harness, #"{"type":"ui.confirm"}"#)
        try await send(harness, #"{"type":"nav.back"}"#)
        let day = "2025-07-05"
        try await send(harness, #"{"type":"nav.openReview","album":"album-1","day":"\#(day)"}"#)
        await harness.settled()
        let photos = harness.graph.session.reviewOrderedIDs
            .filter { harness.graph.session.reviewDayByID[$0]?.description == day }
            .compactMap(harness.runtime.assetAliases.alias(for:))
        try #require(photos.count >= 4)
        try await send(harness, #"{"type":"selection.toggle","photo":"\#(photos[0])"}"#)
        try await send(harness, #"{"type":"selection.toggleCluster","day":"\#(day)"}"#)
        #expect(harness.value("active.selection.count") == .value(.int(photos.count)))
        try await send(harness, #"{"type":"viewer.open","photo":"\#(photos[3])"}"#)
        #expect(harness.value("nav.viewerPhoto") == .value(.string(photos[3])))
        try await send(harness, #"{"type":"viewer.page","direction":"next"}"#)
        try await send(harness, #"{"type":"viewer.page","photo":"\#(photos[0])"}"#)
        try await send(harness, #"{"type":"viewer.pick"}"#)   // un-picks photos[0] and stays
        try await send(harness, #"{"type":"viewer.dismiss"}"#)
        try await send(harness, #"{"type":"viewer.open","photo":"\#(try #require(photos.last))"}"#)
        try await send(harness, #"{"type":"viewer.page","direction":"next"}"#)   // across the day's end
        try await send(harness, #"{"type":"viewer.undoAutoDone"}"#)
        try await send(harness, #"{"type":"viewer.dismiss"}"#)
        let lastPhoto = try #require(harness.graph.session.reviewOrderedIDs.last
            .flatMap(harness.runtime.assetAliases.alias(for:)))
        try await send(harness, #"{"type":"viewer.open","photo":"\#(lastPhoto)"}"#)
        try await send(harness, #"{"type":"viewer.page","direction":"next"}"#)   // → the end-of-set card
        try await send(harness, #"{"type":"viewer.keepReviewing"}"#)
        try await send(harness, #"{"type":"viewer.dismiss"}"#)
        try await send(harness, #"{"type":"review.goTo","day":"\#(day)"}"#)
        try await send(harness, #"{"type":"done.toggle","day":"\#(day)"}"#)
        try await send(harness, #"{"type":"review.markDoneAndAdvance"}"#)   // reopens it (it was done)
        try await send(harness, #"{"type":"nav.back"}"#)
        // A failing export, then Try again once the library recovers.
        await harness.settled()
        let library = try #require(harness.graph.photoLibrary as? FakePhotoLibrary)
        await library.setAuthorization(.limited)   // creating an album needs full access → the run fails
        try await send(harness, #"{"type":"nav.openExport"}"#)
        await harness.settled()
        #expect(harness.value("active.export.phase") == .value(.string("failed")))
        await library.setAuthorization(.authorized)
        try await send(harness, #"{"type":"export.retry"}"#)
        await harness.settled()
        #expect(harness.value("active.export.phase") == .value(.string("done")))

        #expect(exercised == Set(ControlActionKind.allCases),
                "not exercised: \(Set(ControlActionKind.allCases).subtracting(exercised).map(\.rawValue))")
    }

    @Test("headless launch flag: parsed with -PoimiControl, refused without it")
    func headlessFlag() {
        let parsed = ControlLaunch.parse(["-PoimiControl", "-PoimiFixture", "one-album", "-PoimiHeadless"])
        #expect(parsed.launch?.headless == true)
        #expect(ControlLaunch.parse(["-PoimiControl", "-PoimiFixture", "one-album"]).launch?.headless == false)
        guard case .invalid = ControlLaunch.parse(["-PoimiHeadless"]) else {
            Issue.record("-PoimiHeadless alone must be refused")
            return
        }
    }

    @Test("a predicate value of the wrong type for its path is an error, not silently met")
    func predicateTypeMismatch() async {
        let harness = await ControlHarness.booted(.oneAlbum)
        let mismatched = await harness.wait([("idle", .ne, .string("true"))], timeoutMs: 0)
        guard case .failure(let error) = mismatched else { Issue.record("met?"); return }
        #expect(error.code == .badRequest)
        #expect(error.message.contains("bool"))
        let ordering = await harness.wait([("nav.screen", .gte, .int(1))], timeoutMs: 0)
        guard case .failure(let orderingError) = ordering else { Issue.record("met?"); return }
        #expect(orderingError.code == .badRequest)
        // null is fine where the path may be null; a matching type is fine.
        #expect((try? await harness.wait([("app.launchError", .eq, .null)], timeoutMs: 0).get()) != nil)
        #expect((try? await harness.wait([("idle", .eq, .bool(true))], timeoutMs: 0).get()) != nil)
    }

    @Test("a reply brings state up to date first: the state written is at least the reply's rev")
    func replyFlushesState() async throws {
        let harness = await ControlHarness.booted(.oneAlbum)
        let response = await harness.host.handle(
            ControlRequest(id: 1, run: "r-test", command: .send(.navOpenAppSettings)))
        let reply = await harness.host.reply(response)
        guard case .int(let rev)? = reply["rev"], case .int(let written)? = harness.sink.lastState?["rev"] else {
            Issue.record("no rev")
            return
        }
        #expect(written >= rev)
        #expect(harness.sink.lastState?["nav"]?["screen"] == .string("appSettings"))   // not 100 ms later
    }
}

@MainActor
@Suite("Control plane: schema (#298)")
struct ControlSchemaTests {

    /// Flatten a snapshot into (declared-pattern path, JSON type) pairs — objects descend, arrays don't.
    private func paths(_ json: ControlJSON, prefix: String = "") -> [(String, String)] {
        guard case .object(let members) = json else { return [] }
        return members.flatMap { member -> [(String, String)] in
            let key = prefix == "albums" ? "*" : member.key
            let path = prefix.isEmpty ? key : "\(prefix).\(key)"
            let type: String = switch member.value {
            case .null: "null"
            case .bool: "bool"
            case .int: "int"
            case .string: "string"
            case .array: "array"
            case .object: "object"
            }
            let pattern = prefix == "albums" ? "albums.*" : path
            return [(pattern, type)] + paths(member.value, prefix: pattern)
        }
    }

    @Test("schema ↔ snapshot parity: every snapshot path is declared with its type; every declared path occurs")
    func parity() async throws {
        var observed: [String: Set<String>] = [:]
        func record(_ harness: ControlHarness) {
            for (path, type) in paths(harness.runtime.stateJSON()) { observed[path, default: []].insert(type) }
        }
        for fixture in ControlFixture.allCases {
            let harness = await ControlHarness.booted(fixture)
            record(harness)
            if fixture.authorization == .authorized, !harness.created.isEmpty {
                try await harness.send(#"{"type":"nav.openAlbum","album":"album-1"}"#)
                await harness.settled()
                record(harness)
            }
        }
        // States the fixtures alone don't reach: the viewer, a finished export, a refused launch.
        let viewer = await ControlHarness.booted(.midReview, route: .review(album: "album-1", day: nil), viewer: "a-0002")
        record(viewer)
        // …and its auto-done toast: from the open cluster's last photo, across its end.
        try await viewer.send(#"{"type":"viewer.dismiss"}"#)
        let open = try #require(viewer.clusters.first { !viewer.graph.doneStore.isDone($0) })
        try await viewer.send(#"{"type":"viewer.open","photo":"\#(viewer.alias(try #require(open.assetIDs.last)))"}"#)
        try await viewer.send(#"{"type":"viewer.page","direction":"next"}"#)
        record(viewer)
        let exported = await ControlHarness.booted(.exported)
        try await exported.send(#"{"type":"nav.openAlbum","album":"album-1"}"#)
        await exported.settled()
        try await exported.send(#"{"type":"nav.openExport"}"#)
        await exported.settled()
        record(exported)
        let refused = ControlHarness(.fresh, parsed: .invalid("refused"))
        await refused.runtime.bootstrap()
        record(refused)

        let declared = Dictionary(uniqueKeysWithValues: ControlSchema.statePaths.map {
            ($0.path, Set($0.type.split(separator: "|").map(String.init)))
        })
        for (path, types) in observed {
            let allowed = try #require(declared[path], "snapshot path '\(path)' isn't declared")
            #expect(types.isSubset(of: allowed), "\(path): observed \(types), declared \(allowed)")
        }
        #expect(Set(declared.keys).subtracting(observed.keys).isEmpty,
                "declared but never observed: \(Set(declared.keys).subtracting(observed.keys).sorted())")
    }

    @Test("schema lists every action, fixture op, refusal, error code, fixture and declared path")
    func schemaIsComplete() {
        let schema = ControlSchema.json()
        guard case .array(let actions)? = schema["actions"] else { Issue.record("no actions"); return }
        #expect(actions.compactMap { $0["type"] } == ControlActionKind.allCases.map { .string($0.rawValue) })
        #expect(actions.first?["args"]?["album"] == .string(ControlArgType.albumAlias.text))
        guard case .object(let refusals)? = schema["refusals"] else { Issue.record("no refusals"); return }
        #expect(refusals.map(\.key) == ControlRefusal.allCases.map(\.rawValue))
        guard case .object(let paths)? = schema["statePaths"] else { Issue.record("no paths"); return }
        #expect(paths.map(\.key) == ControlSchema.statePaths.map(\.path))
        guard case .array(let fixtures)? = schema["fixtures"] else { Issue.record("no fixtures"); return }
        #expect(fixtures.count == ControlFixture.allCases.count)
        guard case .array(let ops)? = schema["fixtureOps"] else { Issue.record("no ops"); return }
        #expect(ops.compactMap { $0["op"] } == ControlFixtureOpKind.allCases.map { .string($0.rawValue) })
    }

    @Test("every fixture op the schema lists decodes with its declared arguments (one declaration)")
    func fixtureOpParity() throws {
        let sample: [ControlArgType: String] = [
            .fetchFailure: #""fetchFailed""#, .authorization: #""denied""#, .assetAliases: #"["a-0001"]"#,
            .fixture: #""one-album""#, .day: #""2025-07-05""#, .int: "3", .exportFailure: #""writeFailed""#
        ]
        for kind in ControlFixtureOpKind.allCases {
            let args = kind.args.filter(\.required).map { #""\#($0.name)":\#(sample[$0.type] ?? "null")"# }
            let json = (["\"op\":\"\(kind.rawValue)\""] + args).joined(separator: ",")
            let op = try JSONDecoder().decode(ControlFixtureOp.self, from: Data("{\(json)}".utf8))
            #expect(String(describing: op).isEmpty == false, "\(kind.rawValue)")
            // And an undeclared argument is refused.
            let extra = "{\(json),\"bogus\":1}"
            #expect(throws: ControlRequestError.self) {
                try JSONDecoder().decode(ControlFixtureOp.self, from: Data(extra.utf8))
            }
        }
    }
}

@MainActor
@Suite("Control plane: file mailbox (#298)")
struct ControlMailboxTests {

    /// A fresh mailbox directory; `create: false` leaves making it to `ControlMailbox.start()`.
    private func directory(create: Bool = true) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mailbox-\(UUID().uuidString)")
        if create { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        return url
    }

    /// As the CLI does: a temporary name, then a rename into place.
    private func write(_ data: Data, name: String, to directory: URL) throws {
        let temporary = directory.appendingPathComponent(".\(name).tmp")
        try data.write(to: temporary)
        try FileManager.default.moveItem(at: temporary, to: directory.appendingPathComponent(name))
    }

    private func write(_ raw: String, name: String, to directory: URL) throws {
        try write(Data(raw.utf8), name: name, to: directory)
    }

    private func write(_ body: String, id: Int, to directory: URL) throws {
        try write(envelope(body, id: id), name: "req-\(id).json", to: directory)
    }

    private func reply(_ name: String, in directory: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent(name))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func reply(_ id: Int, in directory: URL) throws -> [String: Any] {
        try reply("res-\(id).json", in: directory)
    }

    @Test("requests are handled in ascending n, replied atomically, and removed; a bad one gets an error reply")
    func ordering() async throws {
        let harness = await ControlHarness.booted(.oneAlbum)
        let directory = try directory()
        // Written out of order; each accepted op takes the next seq, so the replies show the order handled.
        try write(#""cmd":"fixture","fixture":{"op":"flush"}"#, id: 12, to: directory)
        try write(#""cmd":"fixture","fixture":{"op":"flush"}"#, id: 3, to: directory)
        try Data("{ nope".utf8).write(to: directory.appendingPathComponent("req-5.json"))
        try write(#""cmd":"snapshot""#, id: 7, to: directory)

        let mailbox = ControlMailbox(directory: directory, host: harness.host)
        mailbox.start()
        defer { mailbox.stop() }
        await mailbox.awaitDrain()

        let first = try reply(3, in: directory)
        let last = try reply(12, in: directory)
        #expect((first["data"] as? [String: Any])?["seq"] as? Int == 1)
        #expect((last["data"] as? [String: Any])?["seq"] as? Int == 2)
        #expect(first["run"] as? String == "r-test")
        let bad = try reply(5, in: directory)
        #expect(bad["ok"] as? Bool == false)
        #expect((bad["error"] as? [String: Any])?["code"] as? String == "badRequest")
        #expect(try reply(7, in: directory)["ok"] as? Bool == true)
        // Only the replies remain: every request taken, no temporary files left behind.
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(names == ["res-12.json", "res-3.json", "res-5.json", "res-7.json"])
        #expect(mailbox.pendingRequests().isEmpty)
    }

    @Test("start() makes its directory; a request that arrives after start is picked up")
    func picksUpLaterRequests() async throws {
        let harness = await ControlHarness.booted(.oneAlbum)
        let directory = try directory(create: false)
        let mailbox = ControlMailbox(directory: directory, host: harness.host, pollInterval: .milliseconds(20))
        mailbox.start()
        defer { mailbox.stop() }
        #expect(FileManager.default.fileExists(atPath: directory.path))   // start() makes its directory
        await mailbox.awaitDrain()
        try write(#""cmd":"schema""#, id: 1, to: directory)
        let reply = directory.appendingPathComponent("res-1.json")
        let deadline = ContinuousClock.now + .seconds(10)
        while !FileManager.default.fileExists(atPath: reply.path), ContinuousClock.now < deadline {
            await mailbox.awaitDrain()
            await Task.yield()
        }
        #expect(try self.reply(1, in: directory)["ok"] as? Bool == true)
    }

    @Test("a send queued behind a wait isn't held by it: actions never queue behind waits")
    func waitDoesNotBlockSends() async throws {
        let harness = await ControlHarness.booted(.oneAlbum)
        let directory = try directory()
        // A wait that can only be met by the send behind it.
        try write(#"{"v":1,"id":1,"run":"r-test","cmd":"wait","timeoutMs":20000,"#
                  + #""predicates":[{"path":"nav.screen","op":"eq","value":"appSettings"}]}"#,
                  name: "req-1.json", to: directory)
        try write(#"{"v":1,"id":2,"run":"r-test","cmd":"send","action":{"type":"nav.openAppSettings"}}"#,
                  name: "req-2.json", to: directory)
        let mailbox = ControlMailbox(directory: directory, host: harness.host)
        mailbox.start()
        defer { mailbox.stop() }
        await mailbox.awaitDrain()
        #expect(try reply(1, in: directory)["ok"] as? Bool == true)
        #expect((try reply(2, in: directory)["data"] as? [String: Any])?["outcome"] as? String == "accepted")
    }

    @Test("a request file without a number gets a badRequest reply and is removed, not ignored forever")
    func malformedRequestName() async throws {
        let harness = await ControlHarness.booted(.oneAlbum)
        let directory = try directory()
        try write(#"{"v":1,"id":3,"run":"r-test","cmd":"schema"}"#, name: "req--3.json", to: directory)
        let mailbox = ControlMailbox(directory: directory, host: harness.host)
        mailbox.start()
        defer { mailbox.stop() }
        await mailbox.awaitDrain()
        let reply = try self.reply("res--3.json", in: directory)
        #expect(reply["ok"] as? Bool == false)
        #expect(reply["id"] is NSNull)
        #expect((reply["error"] as? [String: Any])?["code"] as? String == "badRequest")
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("req--3.json").path))
    }
}
