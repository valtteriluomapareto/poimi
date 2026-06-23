// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Curation",
    // Pure domain. A platform floor is declared only so the package resolves cleanly
    // when embedded in the iOS 26 app target; the source itself imports nothing
    // platform-specific (no Photos / PhotoKit / SwiftData / UIKit / SwiftUI) — see the
    // boundary invariant enforced by Scripts/check-curation-boundary.sh.
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "Curation", targets: ["Curation"]),
    ],
    targets: [
        .target(
            name: "Curation",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CurationTests",
            dependencies: ["Curation"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
