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
}
