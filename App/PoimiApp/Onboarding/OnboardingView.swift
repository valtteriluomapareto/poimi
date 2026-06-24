//
//  OnboardingView.swift
//  PoimiApp — first-run intro + permission rationale (issue #31, D6; architecture §10).
//
//  Shown while authorization is `.notDetermined` (root phase `.onboarding`). A two-step local
//  flow: an intro that orients (the name is opaque, so this carries weight) → a rationale that
//  earns the full-access grant *before* the system prompt. "Allow access" calls the coordinator,
//  which drives the real `PHPhotoLibrary` prompt; the resolved status flips `rootPhase`
//  reactively (→ albums, or → recovery if limited/denied).
//

import SwiftUI

struct OnboardingView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var step: Step = .intro

    private enum Step { case intro, rationale }

    var body: some View {
        switch step {
        case .intro:
            OnboardingScaffold(
                symbol: "hand.tap",
                title: "Poimi",
                headline: "Hand-pick your year.",
                message: "Go through a whole year of photos and choose the best into one album — "
                    + "toward a count you set. You pick every photo, not an algorithm.",
                primaryTitle: "Get started",
                primaryAction: { step = .rationale })
        case .rationale:
            OnboardingScaffold(
                symbol: "photo.stack",
                title: "Full library access",
                headline: "Poimi works across your whole library.",
                message: "It needs full access to browse a date range, show your photos, and save the album "
                    + "you build. Your photos never leave your device — Poimi stores only references, "
                    + "nothing in the cloud, nothing shared.",
                primaryTitle: "Allow access",
                primaryAction: { Task { await coordinator.requestAuthorization() } },
                footnote: "We'll ask iOS for permission next.")
        }
    }
}

/// A calm, centered onboarding/recovery layout: symbol · title · headline · supporting copy, with
/// a thumb-reachable prominent action at the bottom (design-language: Notes-calm, one clear
/// primary action, ≥44pt targets, system components).
struct OnboardingScaffold: View {
    let symbol: String
    let title: String
    let headline: String
    let message: String
    let primaryTitle: String
    let primaryAction: () -> Void
    var footnote: String?

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(title)
                .font(.largeTitle.bold())
            Text(headline)
                .font(.title3)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            if let footnote {
                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button(primaryTitle, action: primaryAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
