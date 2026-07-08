//
//  PhotoInfoFormatTests.swift
//  PoimiAppTests — the photo viewer's info-field formatting (#127).
//
//  `PhotoInfoFormat` is pulled out of `PhotoViewerView` so the resolution/megapixel rounding and the
//  day·time join are unit-tested instead of formatted in a `body` (the repo's no-work-in-body rule).
//

import Testing
import Curation
@testable import PoimiApp

@Suite("Photo info formatting (#127)")
struct PhotoInfoFormatTests {

    @Test("resolution: dimensions + rounded megapixels")
    func resolutionMP() {
        // 4032 × 3024 = 12,192,768 px → 12 MP (rounds down from 12.19).
        #expect(PhotoInfoFormat.resolution(PixelSize(width: 4032, height: 3024)) == "4032 × 3024 · 12 MP")
        // 1000 × 750 = 750,000 px → 0.75 MP rounds UP to 1 MP.
        #expect(PhotoInfoFormat.resolution(PixelSize(width: 1000, height: 750)) == "1000 × 750 · 1 MP")
    }

    @Test("resolution: sub-half-megapixel drops the MP suffix (just dimensions)")
    func resolutionTiny() {
        // 640 × 480 = 307,200 px → 0.3 MP rounds to 0 → no MP suffix.
        #expect(PhotoInfoFormat.resolution(PixelSize(width: 640, height: 480)) == "640 × 480")
    }

    @Test("resolution: a zero / empty size yields an empty string (row omitted / '—')")
    func resolutionZero() {
        #expect(PhotoInfoFormat.resolution(.zero) == "")
        #expect(PhotoInfoFormat.resolution(PixelSize(width: 0, height: 3024)) == "")
    }

    @Test("date·time line: joins with ' · ' only when BOTH day and time are present")
    func dateTimeJoin() {
        #expect(PhotoInfoFormat.dateTimeLine(day: "Sat, Jul 5", time: "14.32") == "Sat, Jul 5 · 14.32")
        #expect(PhotoInfoFormat.dateTimeLine(day: "Sat, Jul 5", time: "") == "Sat, Jul 5")   // undated-time
        #expect(PhotoInfoFormat.dateTimeLine(day: "", time: "14.32") == "14.32")              // no review context
        #expect(PhotoInfoFormat.dateTimeLine(day: "", time: "") == "")                        // nothing
    }
}
