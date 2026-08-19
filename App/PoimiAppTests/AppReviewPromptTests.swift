//
//  AppReviewPromptTests.swift
//  PoimiAppTests — the App Store review-prompt gating (#269).
//
//  Gate policy: ask at most ONCE per app version. Apple's own throttle is out of scope here (we can't
//  and don't test the system sheet); these cover only OUR decision + persistence.
//

import Testing
import Foundation
@testable import PoimiApp

@MainActor
@Suite("AppReviewPrompt (#269)")
struct AppReviewPromptTests {

    /// A fresh, isolated UserDefaults per test (no cross-test bleed).
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "appreview.test.\(UUID().uuidString)")!
    }

    private func prompt(current: String, stored: String? = nil) -> (AppReviewPrompt, UserDefaults) {
        let d = defaults()
        if let stored { d.set(stored, forKey: AppReviewPrompt.lastPromptedVersionKey) }
        return (AppReviewPrompt(userDefaults: d, currentVersion: current), d)
    }

    @Test("a version we've never asked on is eligible")
    func freshIsEligible() {
        let (sut, _) = prompt(current: "1.0.2")
        #expect(sut.shouldRequest == true)
        #expect(sut.lastPromptedVersion == nil)
    }

    @Test("marking requested records the version and suppresses a repeat on the same version")
    func markSuppressesRepeat() {
        let (sut, d) = prompt(current: "1.0.2")
        sut.markRequested()
        #expect(sut.shouldRequest == false)
        #expect(sut.lastPromptedVersion == "1.0.2")
        #expect(d.string(forKey: AppReviewPrompt.lastPromptedVersionKey) == "1.0.2")
    }

    @Test("already asked on this version → not eligible")
    func sameVersionNotEligible() {
        let (sut, _) = prompt(current: "1.0.2", stored: "1.0.2")
        #expect(sut.shouldRequest == false)
    }

    @Test("an update re-arms the prompt (asked on an older version)")
    func updateReArms() {
        let (sut, _) = prompt(current: "1.0.3", stored: "1.0.2")
        #expect(sut.shouldRequest == true)
    }

    @Test("persists across reconstruction on the same store (once per version holds after relaunch)")
    func persistsAcrossReconstruction() {
        let (sut, d) = prompt(current: "1.0.2")
        sut.markRequested()
        let reopened = AppReviewPrompt(userDefaults: d, currentVersion: "1.0.2")
        #expect(reopened.shouldRequest == false)
        // …and a later update still re-arms it.
        let afterUpdate = AppReviewPrompt(userDefaults: d, currentVersion: "1.1.0")
        #expect(afterUpdate.shouldRequest == true)
    }

    @Test("markRequested is idempotent")
    func markIdempotent() {
        let (sut, _) = prompt(current: "1.0.2")
        sut.markRequested()
        sut.markRequested()
        #expect(sut.lastPromptedVersion == "1.0.2")
        #expect(sut.shouldRequest == false)
    }

    // MARK: - Downgrade / corrupt-store edges (equality, not ordering — deliberate divergence from WhatsNewState)

    @Test("a downgrade re-asks (we gate on the exact version string, so this is intended + harmless)")
    func downgradeReAsks() {
        // stored NEWER than current (dev/TestFlight only; the App Store serves forward) → still != → eligible.
        let (sut, _) = prompt(current: "1.1.0", stored: "1.2.0")
        #expect(sut.shouldRequest == true)
    }

    @Test("a corrupt stored version (empty / garbage) is treated as never-asked — the safe re-ask direction")
    func corruptStoredReArms() {
        let (empty, _) = prompt(current: "1.0.2", stored: "")
        #expect(empty.shouldRequest == true)
        let (garbage, _) = prompt(current: "1.0.2", stored: "not-a-version")
        #expect(garbage.shouldRequest == true)
    }

    // MARK: - The view-level gate (extracted pure decision — the feature's actual once-per-version promise)

    @Test("shouldRequestReview: a real export on an eligible version asks")
    func viewGateEligibleAsks() {
        let (sut, _) = prompt(current: "1.0.2")
        #expect(shouldRequestReview(isInjectedStore: false, prompt: sut) == true)
    }

    @Test("shouldRequestReview: the screenshot harness (injected store) never asks, even when eligible")
    func viewGateInjectedSuppressed() {
        let (sut, _) = prompt(current: "1.0.2")   // eligible on its own…
        #expect(sut.shouldRequest == true)
        #expect(shouldRequestReview(isInjectedStore: true, prompt: sut) == false)   // …but the harness is excluded
    }

    @Test("shouldRequestReview: a real export that already asked this version does not re-ask")
    func viewGateAlreadyAskedSuppressed() {
        let (sut, _) = prompt(current: "1.0.2", stored: "1.0.2")
        #expect(shouldRequestReview(isInjectedStore: false, prompt: sut) == false)
    }

    // MARK: - Production Bundle path (the silent dead-prompt failure mode)

    @Test("the production init reads a real host-app version — not the test runner, not the 0.0.0 fallback")
    func productionBundleVersion() throws {
        // Prove we read the HOST app, not the xctest runner (mirrors WhatsNewStateTests' M2 guard) — else a
        // wrong CFBundleShortVersionString would pin currentVersion to "0.0.0" and the prompt would fire
        // once then suppress forever across every future release.
        #expect(Bundle.main.bundleIdentifier == "com.valtteriluoma.poimi")
        let sut = AppReviewPrompt(userDefaults: defaults())   // convenience init → bundle: .main
        #expect(sut.currentVersion != "0.0.0")
        #expect(sut.currentVersion.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil)
    }
}
