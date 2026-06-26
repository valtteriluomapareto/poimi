//
//  RecoveryGuidanceTests.swift
//  PoimiAppTests — the access-recovery copy mapping (#31, D6).
//

import Testing
import Curation
@testable import PoimiApp

@Suite("RecoveryGuidance (#31)")
struct RecoveryGuidanceTests {

    @Test("limited vs denied/restricted get distinct, status-appropriate guidance")
    func mapping() {
        let limited = RecoveryGuidance.forAuthorization(.limited)
        let denied = RecoveryGuidance.forAuthorization(.denied)
        let restricted = RecoveryGuidance.forAuthorization(.restricted)

        // Limited and denied are different problems → different copy.
        #expect(limited != denied)
        #expect(limited.title == "Full access needed")
        #expect(denied.title == "Photo access is off")
        // Intentional contract: `.restricted` and `.denied` share one "access is off" screen
        // (the `case .denied, .restricted` grouping). If they ever need distinct copy, split the
        // mapping AND this assertion together.
        #expect(restricted == denied)
        // The limited copy must name the limited-access trap specifically.
        #expect(limited.message.localizedCaseInsensitiveContains("limited"))
    }

    @Test("non-recovery statuses get a neutral, non-empty fallback (never routed here)")
    func nonRecoveryFallback() {
        for status: LibraryAuthorization in [.authorized, .notDetermined] {
            let guidance = RecoveryGuidance.forAuthorization(status)
            #expect(!guidance.title.isEmpty)
            #expect(!guidance.message.isEmpty)
        }
    }
}
