//
//  AppSettingsView.swift
//  PoimiApp — app-level settings (Paper artboard "App settings" 3N9-0).
//
//  App-WIDE settings, distinct from the per-album `AlbumSettingsView` (#41): the Photos-access
//  status + deep-link (the permission is app-wide, not per-album) and About (version / license /
//  source). Reached from the album library's cog; the per-album screen uses a sliders "adjustments"
//  icon instead, so the two entry points never look alike.
//
//  Thin by design: it reads the coordinator's authorization and opens URLs — no stores, no model.
//

import SwiftUI
import UIKit          // UIApplication.openSettingsURLString (the constant only — no UIKit UI)
import Curation       // LibraryAuthorization

struct AppSettingsView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.openURL) private var openURL

    /// The public source repository — Poimi is dual-licensed (AGPL-3.0 + commercial), curating in the open.
    private static let sourceURL = URL(string: "https://github.com/valtteriluomapareto/poimi")!

    var body: some View {
        Form {
            Section("Access") {
                // App-wide permission → tapping deep-links to the system Settings (we can't re-prompt);
                // on return, the app's scenePhase re-read routes onward if it changed (§10, like recovery).
                Button(action: openPhotosSettings) {
                    LabeledContent("Photos access") {
                        let display = PhotosAccessDisplay.forAuthorization(coordinator.authorization)
                        Label(display.label, systemImage: display.symbol)   // icon leads → "✓ Full"
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(accessTint)
                    }
                }
                .tint(.primary)   // a settings row, not a call-to-action — don't tint the label blue
            }

            Section("About") {
                LabeledContent("Version", value: appVersion)
                LabeledContent("License", value: "AGPL-3.0")
                Button { openURL(Self.sourceURL) } label: {
                    LabeledContent("Source code") {
                        // Text then an up-right glyph → reads "GitHub ↗" (opens Safari), not an in-app push.
                        HStack(spacing: 4) {
                            Text("GitHub")
                            Image(systemName: "arrow.up.right")
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .tint(.primary)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func openPhotosSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }

    /// The full version identity for display: marketing version + build number, e.g.
    /// "0.1.0 (1234)" — mirroring the TestFlight identity (#135). Marketing version is the
    /// canonical `CFBundleShortVersionString` (MARKETING_VERSION); the build is `CFBundleVersion`
    /// (CURRENT_PROJECT_VERSION = $GITHUB_RUN_NUMBER on release builds). Both come from
    /// `Bundle.main` — no hardcoded duplicates. The build is appended only when present.
    private var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let build, !build.isEmpty {
            return "\(short) (\(build))"
        }
        return short
    }

    /// Status colour: full = brand green (the "all set"), limited = gold (attention), off = neutral.
    private var accessTint: Color {
        switch coordinator.authorization {
        case .authorized: .brandGreen
        case .limited: .accentColor
        case .denied, .restricted: .secondary
        case .notDetermined: .secondary
        }
    }
}

/// Pure, testable display for the Photos-access row — the status label + SF Symbol keyed by
/// authorization. Kept out of the view (the `RecoveryGuidance` pattern, §10) so the status→label
/// mapping is unit-tested without rendering. The tint (a SwiftUI `Color`) stays in the view.
struct PhotosAccessDisplay: Equatable {
    let label: String
    let symbol: String

    static func forAuthorization(_ status: LibraryAuthorization) -> PhotosAccessDisplay {
        switch status {
        case .authorized:
            PhotosAccessDisplay(label: String(localized: "Full", comment: "Photo access status: full library access"),
                                symbol: "checkmark.circle.fill")
        case .limited:
            PhotosAccessDisplay(label: String(localized: "Limited", comment: "Photo access status: limited selection"),
                                symbol: "checkmark.circle")
        case .denied, .restricted:
            PhotosAccessDisplay(label: String(localized: "Off", comment: "Photo access status: denied or restricted"),
                                symbol: "exclamationmark.circle")
        case .notDetermined:
            PhotosAccessDisplay(label: String(localized: "Not set", comment: "Photo access status: not yet requested"),
                                symbol: "circle")
        }
    }
}
