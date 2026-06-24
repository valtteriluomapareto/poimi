//
//  AccessRecoveryView.swift
//  PoimiApp — the parameterized access-recovery screen (issue #31, D6; architecture §10).
//
//  Shown when authorization is `.limited` / `.denied` / `.restricted` (root phase `.recovery`).
//  One screen, parameterized by the status (the design inventory's "don't design two
//  near-identical screens"). We cannot re-prompt for Full once Limited is chosen, so the only
//  forward path is the Settings deep-link; on return, the app's scenePhase re-refresh re-reads
//  authorization and routes onward if it's now `.authorized`.
//

import SwiftUI
import UIKit          // for `UIApplication.openSettingsURLString` (the constant only — no UIKit UI)
import Curation

/// Pure, testable copy for the recovery screen, keyed by authorization. Kept out of the view so
/// the status→message mapping is unit-tested without rendering.
struct RecoveryGuidance: Equatable {
    let title: String
    let message: String

    static func forAuthorization(_ status: LibraryAuthorization) -> RecoveryGuidance {
        switch status {
        case .limited:
            RecoveryGuidance(
                title: "Full access needed",
                message: "Limited access hides most of your year and can't save albums. "
                    + "Poimi needs all your photos to curate a full year.")
        case .denied, .restricted:
            RecoveryGuidance(
                title: "Photo access is off",
                message: "Poimi can't see your library. Turn on photo access to browse and curate your year.")
        case .authorized, .notDetermined:
            // Not a recovery state — the coordinator never routes here; a neutral fallback only.
            RecoveryGuidance(
                title: "Photo access",
                message: "Poimi needs access to your photo library.")
        }
    }
}

struct AccessRecoveryView: View {
    let authorization: LibraryAuthorization
    @Environment(\.openURL) private var openURL

    private var guidance: RecoveryGuidance { .forAuthorization(authorization) }

    var body: some View {
        OnboardingScaffold(
            symbol: "lock.open",
            title: guidance.title,
            headline: guidance.message,
            message: "Set Poimi's Photos access to full access in Settings, then come back.",
            primaryTitle: "Open Settings",
            primaryAction: openSettings)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}
