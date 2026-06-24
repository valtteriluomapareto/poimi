//
//  PhotoLibraryChangeObserver.swift
//  PoimiApp — the PHPhotoLibraryChangeObserver shim (issue #22, D16).
//
//  `photoLibraryDidChange(_:)` is NOT guaranteed to run on the main thread, and an `actor`
//  cannot conform to the `@objc` `PHPhotoLibraryChangeObserver` protocol — so this small
//  `NSObject` receives the callback and hops a `Sendable` signal into the actor. In Phase 2
//  it carries the `Sendable` results of `changeDetails(for:)` (computed against the
//  actor-owned fetch result); the Phase-1 skeleton forwards a bare "something changed"
//  signal, which is the seam the reconciliation plugs into.
//

import Foundation
import Photos

final class PhotoLibraryChangeObserver: NSObject, PHPhotoLibraryChangeObserver {
    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        super.init()
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        // Any thread. Carry only the `Sendable` closure across — never `PHChange` itself.
        onChange()
    }
}
