//
//  FakePlaceNaming.swift
//  PoimiApp — the deterministic, offline reverse-geocoder for previews + tests (DEBUG only).
//
//  Mirrors `FakeThumbnailProvider`: no network, deterministic output, and DEBUG-gated so it (and the
//  launch flag that selects it) compile out of Release (D30, `check-fake-release-isolation`). It
//  synthesises a stable label per coordinate cell, supports error injection (§7/§10), and counts calls
//  so tests can assert "geocoded once, then served from cache."
//

#if DEBUG
import Foundation
import Curation

actor FakePlaceNaming: PlaceNaming {
    /// Cell key (`GeocodeCell.key`) → an explicit name, overriding the synthetic default.
    private let names: [String: String]
    /// Cell key → an error to throw for that place (transient-failure injection).
    private let errors: [String: PlaceNamingError]
    /// Cell keys the fake returns `nil` for (a valid "no usable name").
    private let unnamed: Set<String>

    /// Total invocations — a test asserts this doesn't grow on a second pass (cache hit).
    private(set) var callCount = 0
    /// Per-cell invocation counts — a test asserts each place is geocoded at most once.
    private(set) var callsByCell: [String: Int] = [:]

    init(names: [String: String] = [:],
         errors: [String: PlaceNamingError] = [:],
         unnamed: Set<String> = []) {
        self.names = names
        self.errors = errors
        self.unnamed = unnamed
    }

    func name(for coordinate: Coordinate) async throws -> String? {
        let cell = GeocodeCell.key(for: coordinate)
        callCount += 1
        callsByCell[cell, default: 0] += 1
        if let error = errors[cell] { throw error }
        if unnamed.contains(cell) { return nil }
        if let name = names[cell] { return name }
        return "Place \(cell)"   // deterministic synthetic default
    }
}
#endif
