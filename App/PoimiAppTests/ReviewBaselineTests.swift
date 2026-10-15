import Foundation
import Testing
import Curation
@testable import PoimiApp

@Suite("Historical review baseline interpretation (#290)")
struct ReviewBaselineTests {
    private let day = DayKey.day(year: 2025, month: 7, day: 5)

    @Test("legacy data is assigned only to its activation lens", arguments: MediaSelection.allCases)
    func legacyLens(_ lens: MediaSelection) throws {
        let data = Data(#"{"2025-07-05":["photo-1","photo-1"],"undated":["unknown"],"invalid":["skip"]}"#.utf8)
        let result = ReviewBaseline.interpret(data, lens: lens)
        if lens == .videosOnly {
            #expect(result == .incompatibleLegacyLens)
        } else {
            #expect(result == .legacy([lens.rawValue: [day: ["photo-1"], .undated: ["unknown"]]]))
        }
    }

    @Test("missing or unreadable baselines cannot be adopted", arguments: [
        nil, Data(), Data([0xFF, 0x01]), Data("null".utf8), Data("[]".utf8),
        Data(#"{"invalid":["skip"]}"#.utf8), Data(#"{"2025-07-05":12}"#.utf8)
    ] as [Data?])
    func unavailable(_ data: Data?) {
        #expect(ReviewBaseline.interpret(data, lens: .photosOnly) == .unavailable)
    }

    @Test("an empty object is already keyed and does not request a save")
    func emptyObject() {
        #expect(ReviewBaseline.interpret(Data("{}".utf8), lens: .photosOnly) == .keyed([:]))
    }

    @Test("a valid legacy day with no IDs keeps its existing meaning")
    func emptyDay() {
        let data = Data(#"{"2025-07-05":[]}"#.utf8)
        #expect(ReviewBaseline.interpret(data, lens: .photosOnly) == .legacy(["photosOnly": [day: []]]))
    }

    @Test("keyed data preserves every lens independently of the current lens", arguments: MediaSelection.allCases)
    func keyed(_ lens: MediaSelection) throws {
        let data = Data(#"""
        {"photosOnly":{"2025-07-05":["p","p"],"bad":["skip"]},
         "photosAndVideos":{"undated":["v"]},"videosOnly":{},"futureLens":{"undated":["future"]}}
        """#.utf8)
        let expected: ReviewBaseline.Lenses = [
            "photosOnly": [day: ["p"]], "photosAndVideos": [.undated: ["v"]],
            "videosOnly": [:], "futureLens": [.undated: ["future"]]
        ]
        #expect(ReviewBaseline.interpret(data, lens: lens) == .keyed(expected))
        let encoded = try #require(ReviewBaseline.encode(expected))
        #expect(ReviewBaseline.decodeKeyed(encoded) == expected)
        #expect(ReviewBaseline.interpret(encoded, lens: lens) == .keyed(expected))
    }

    @Test("mixed flat and keyed values are rejected without partial adoption")
    func mixedShape() {
        let data = Data(#"{"photosOnly":{"2025-07-05":["p"]},"2025-07-05":["p"]}"#.utf8)
        #expect(ReviewBaseline.interpret(data, lens: .photosOnly) == .unavailable)
    }
}
