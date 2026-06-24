//
//  PhotoLibraryProvider.swift
//  PoimiApp — composition root / DI seam for the photo library (issue #23, D30).
//
//  Chooses the concrete `PhotoLibraryProviding` the app runs against: the real
//  `SystemPhotoLibrary`, or — only in DEBUG, and only when launched with
//  `-PoimiUseFakeLibrary` — the deterministic `FakePhotoLibrary`. The fake reference and the
//  launch-flag check live behind `#if DEBUG`, so a release build neither references the fake
//  nor honors the flag (D30); the fake's source is DEBUG-only too, so it isn't even compiled
//  into release.
//

import Foundation
import SwiftUI
import Curation

enum PhotoLibraryProvider {
    /// Build the photo-library dependency for this launch.
    static func make() -> any PhotoLibraryProviding {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-PoimiUseFakeLibrary") {
            return FakePhotoLibrary()
        }
        #endif
        return SystemPhotoLibrary()
    }
}

extension EnvironmentValues {
    /// The injected photo-library seam. Phase 2's navigation coordinator / stores read this
    /// via `@Environment(\.photoLibrary)`; today it's wired through so the seam is live and
    /// the composition root has a consumer.
    @Entry var photoLibrary: any PhotoLibraryProviding = SystemPhotoLibrary()
}
