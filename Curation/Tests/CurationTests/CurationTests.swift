import Testing
@testable import Curation

@Suite("Curation bootstrap")
struct CurationTests {
    /// Trivial smoke test: the package compiles, exports a public symbol, and the
    /// placeholder carries its default purpose string. Real domain tests
    /// (filtering, day-grouping, target math, selection sets) arrive in Phase 1.
    @Test("Placeholder exposes its purpose")
    func placeholderHasPurpose() {
        let placeholder = CurationPlaceholder()
        #expect(!placeholder.purpose.isEmpty)
    }
}
