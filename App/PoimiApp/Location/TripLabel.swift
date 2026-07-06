//
//  TripLabel.swift
//  PoimiApp — the app-tier location sentence for a trip cluster (issue #130, Phase 3).
//
//  The text layer over the pure, string-free `TripShape` (D14/D21: the domain classifies the *shape*;
//  the sentence is composed here and flows through the String Catalog, #95). Phrasing follows the
//  signed-off designs (Paper `3ZP-0` / `43P-0`): a duration-driven sentence around the resolved place
//  name — "Visit to X" · "Weekend in Y" · "Short trip to Z" · "Week in A" · "N days in B".
//

import Foundation
import Curation

enum TripLabel {
    /// The localized location sentence for a trip of `shape` at `name` (the resolved place name).
    static func sentence(for shape: TripShape, place name: String) -> String {
        switch shape {
        case .visit:
            return String(localized: "Visit to \(name)",
                          comment: "Trip label for a single away day at a place")
        case .weekend:
            return String(localized: "Weekend in \(name)",
                          comment: "Trip label for a 2–3 day trip over a weekend")
        case .shortTrip:
            return String(localized: "Short trip to \(name)",
                          comment: "Trip label for a short (few-day) trip")
        case .week:
            return String(localized: "Week in \(name)",
                          comment: "Trip label for a roughly week-long trip")
        case let .longer(days):
            return String(localized: "\(days) days in \(name)",
                          comment: "Trip label for a long trip of N days")
        }
    }
}
