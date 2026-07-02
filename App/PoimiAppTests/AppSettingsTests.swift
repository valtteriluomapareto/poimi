//
//  AppSettingsTests.swift
//  PoimiAppTests — the pure status→display mapping behind the app-settings Photos-access row
//  (the `RecoveryGuidance` pattern: keep the copy out of the view so it's tested without rendering).
//

import Testing
import Curation
@testable import PoimiApp

@Suite("App settings (#—): Photos-access display")
struct AppSettingsTests {

    @Test("each authorization maps to its status label + SF Symbol")
    func mapping() {
        #expect(PhotosAccessDisplay.forAuthorization(.authorized)
            == PhotosAccessDisplay(label: "Full", symbol: "checkmark.circle.fill"))
        #expect(PhotosAccessDisplay.forAuthorization(.limited)
            == PhotosAccessDisplay(label: "Limited", symbol: "checkmark.circle"))
        #expect(PhotosAccessDisplay.forAuthorization(.denied)
            == PhotosAccessDisplay(label: "Off", symbol: "exclamationmark.circle"))
        #expect(PhotosAccessDisplay.forAuthorization(.restricted)
            == PhotosAccessDisplay(label: "Off", symbol: "exclamationmark.circle"))
        #expect(PhotosAccessDisplay.forAuthorization(.notDetermined)
            == PhotosAccessDisplay(label: "Not set", symbol: "circle"))
    }
}
