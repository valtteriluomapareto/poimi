//
//  AlbumOverviewView.swift
//  PoimiApp — the album entry point into the review flow (issue #34).
//
//  A MINIMAL launcher: opening an album lands here, and "Review photos" pushes the scanning →
//  review path so #34's fetch+filter pipeline is reachable end-to-end in the running app. The
//  real zoom-out overview — per-day-group progress, the resume affordance, mark-as-done — is
//  #37, which replaces this view.
//

import SwiftUI
import Curation

struct AlbumOverviewView: View {
    let project: CurationProject
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text(project.title)
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text("Target: ^[\(project.targetCount) photo](inflect: true)")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            Button("Review photos") {
                coordinator.openReview(project.id)
            }
            .buttonStyle(PrimaryActionButtonStyle())
            .accessibilityHint("Scans your library for this album's photos, then opens review.")
        }
        .padding(32)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Overview")
        .navigationBarTitleDisplayMode(.inline)
    }
}
