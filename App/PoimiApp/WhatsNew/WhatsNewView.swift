//
//  WhatsNewView.swift
//  PoimiApp — the Apple-style "What's New" sheet (#248; Paper artboard 5YI-0).
//
//  A solid light/dark surface (text-heavy → not glass, styleguide §5): a large "What's New" title
//  + a short list of tinted-gold SF-symbol rows (headline + a sentence-or-two detail) + a single
//  Continue. Shown on an upgrade (auto-presented from the albums root) or on demand from App
//  settings → About. Content-only — the presenter owns the `.sheet` and persists on dismiss.
//

import SwiftUI

struct WhatsNewView: View {
    /// The notes whose highlights are shown, flattened in display order. Empty → a generic message.
    let notes: [ReleaseNote]
    /// Continue / dismiss. On the auto-present path the presenter persists via `WhatsNewState.markAsSeen()`.
    let onContinue: () -> Void

    /// On-accent foreground: the Cloudberry gold is light in BOTH modes, so its label is a fixed dark
    /// (#1C1C1E) — `Color(.label)` would go white-on-gold in dark mode (styleguide §1).
    private static let onAccent = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)

    private var highlights: [ReleaseNote.Highlight] { notes.flatMap(\.highlights) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                Group {
                    if highlights.isEmpty {
                        Text("Poimi has been updated with fixes and refinements.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 30) {
                            ForEach(Array(highlights.enumerated()), id: \.offset) { _, highlight in
                                row(highlight)
                            }
                        }
                    }
                }
                .padding(.top, 40)
            }
            .padding(.horizontal, 28)
            .padding(.top, 44)
            .padding(.bottom, 24)
        }
        .background(Color(.systemBackground))
        .safeAreaInset(edge: .bottom) {
            Button(action: onContinue) {
                Text("Continue")
                    .font(.headline)
                    .foregroundStyle(Self.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.accentColor, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 28)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .background(Color(.systemBackground))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What's New")
                .font(.largeTitle)
                .fontWeight(.bold)
            Text("A few things we've added and fixed in this update.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ highlight: ReleaseNote.Highlight) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: highlight.symbol)
                .font(.system(size: 26))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, alignment: .center)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(highlight.headline)
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(highlight.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
