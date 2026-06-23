//
//  ContentView.swift
//  PoimiApp
//
//  Placeholder root view for the bootstrap skeleton (GitHub issue #3). It also
//  demonstrates the module seam: it reads a value type from the `Curation` package,
//  proving the dependency is wired and pointing the right way. No real UI yet.

import SwiftUI
import Curation

struct ContentView: View {
    private let placeholder = CurationPlaceholder()

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            Text("Poimi")
                .font(.title.weight(.semibold))
            Text("Bootstrap skeleton")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            // Touches the Curation package so the dependency seam is exercised at runtime.
            Text(placeholder.purpose)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
