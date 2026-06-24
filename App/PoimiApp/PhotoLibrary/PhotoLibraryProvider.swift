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
    /// via `@Environment(\.photoLibrary)`; `@main` injects the composition-root instance, so
    /// this default is only ever hit by an un-injected reader (e.g. a SwiftUI preview). In
    /// DEBUG that default is the deterministic fake — never a real-PhotoKit instance that
    /// would trip authorization inside a preview. Release keeps `SystemPhotoLibrary` (there
    /// are no previews, and `@main` always injects, so the default isn't reached at runtime).
    #if DEBUG
    @Entry var photoLibrary: any PhotoLibraryProviding = FakePhotoLibrary()
    #else
    @Entry var photoLibrary: any PhotoLibraryProviding = SystemPhotoLibrary()
    #endif
}
