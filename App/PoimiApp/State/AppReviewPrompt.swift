//
//  AppReviewPrompt.swift
//  PoimiApp — decides whether to ask StoreKit for an App Store review this launch (#269).
//
//  Mirrors `WhatsNewState`'s shape: `@Observable`, backed by `UserDefaults` keyed on the app version. We
//  ask at most ONCE per app version, at the moment of accomplishment — a successful album export (the
//  completion screen, `ExportView`). Apple's system throttle does the rest: it shows the sheet at most
//  3×/year, skips a version the user already reviewed, and MAY decline to show it at all. We never control
//  display — only whether we *ask* — so we gate on "did we ask on this version," not on "was it shown."
//
//  The gating decision lives HERE (unit-testable, no StoreKit); the actual `requestReview()` call stays at
//  the view edge (`ExportView`), so StoreKit never leaks into the pure `Curation` domain (D14/D21).
//
//  Behavior by build type (so a wrong test conclusion isn't drawn): Debug/simulator shows the sheet on
//  EVERY `requestReview()` call — no system throttle — but our per-version gate still limits it to once
//  per install (reset with `defaults delete com.valtteriluoma.poimi AppReview.lastPromptedVersion`).
//  TestFlight is a NO-OP: the sheet never appears — don't read that as broken. The App Store applies the
//  ≤3×/yr, skip-already-reviewed throttle and may decline entirely. Validate in Debug; trust production.
//

import Foundation
import Observation

@MainActor
@Observable
final class AppReviewPrompt {
    /// `UserDefaults` key for the last app version we asked for a review on. Reset it to re-arm the prompt
    /// for testing: `defaults delete com.valtteriluoma.poimi AppReview.lastPromptedVersion`.
    static let lastPromptedVersionKey = "AppReview.lastPromptedVersion"

    let currentVersion: String
    private let userDefaults: UserDefaults

    convenience init(userDefaults: UserDefaults = .standard, bundle: Bundle = .main) {
        let version = (bundle.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        self.init(userDefaults: userDefaults, currentVersion: version)
    }

    /// Designated init. Tests pass `currentVersion` directly (no `Bundle.main` faking).
    init(userDefaults: UserDefaults, currentVersion: String) {
        self.userDefaults = userDefaults
        self.currentVersion = currentVersion
    }

    /// The app version we most recently asked for a review on, if any.
    var lastPromptedVersion: String? { userDefaults.string(forKey: Self.lastPromptedVersionKey) }

    /// Whether to ask StoreKit for a review now. Eligible when we haven't asked on THIS exact app-version
    /// string yet — a fresh install or an update re-arms it; a repeat within the same version does not.
    /// String equality, NOT semantic ordering (unlike `WhatsNewState`): we track "asked on this version,"
    /// so a dev/TestFlight downgrade harmlessly re-asks and a corrupt stored value falls to the safe
    /// re-ask direction. Apple's own throttle applies on top.
    var shouldRequest: Bool { lastPromptedVersion != currentVersion }

    /// Record that we asked on this version. Call it whether or not the system actually shows the sheet —
    /// the *ask* is what we gate on, since display is Apple's call. Idempotent.
    func markRequested() {
        userDefaults.set(currentVersion, forKey: Self.lastPromptedVersionKey)
    }
}
