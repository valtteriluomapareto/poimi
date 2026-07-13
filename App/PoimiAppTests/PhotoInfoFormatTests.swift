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
        // 1 × 1 → the smallest non-zero size → no MP suffix, just dims.
        #expect(PhotoInfoFormat.resolution(PixelSize(width: 1, height: 1)) == "1 × 1")
    }

    @Test("megapixels: the shared MP count powering both the visible string + the a11y label")
    func megapixels() {
        #expect(PhotoInfoFormat.megapixels(PixelSize(width: 4032, height: 3024)) == 12)
        #expect(PhotoInfoFormat.megapixels(.zero) == nil)
        #expect(PhotoInfoFormat.megapixels(PixelSize(width: 640, height: 480)) == nil)   // 0.31 MP → nil
    }

    @Test("the ~0.5 MP cutoff: exactly-half rounds UP (shows MP), just below drops it")
    func halfMegapixelBoundary() {
        // 816 × 613 = 500,208 px → 0.5002 MP → rounds to 1 (round-half-away-from-zero) → shows "1 MP".
        #expect(PhotoInfoFormat.megapixels(PixelSize(width: 816, height: 613)) == 1)
        #expect(PhotoInfoFormat.resolution(PixelSize(width: 816, height: 613)) == "816 × 613 · 1 MP")
        // 700 × 700 = 490,000 px → 0.49 MP → rounds to 0 → dims only.
        #expect(PhotoInfoFormat.megapixels(PixelSize(width: 700, height: 700)) == nil)
        #expect(PhotoInfoFormat.resolution(PixelSize(width: 700, height: 700)) == "700 × 700")
    }

    @Test("resolution: a zero / empty size yields an empty string (row omitted / '—')")
    func resolutionZero() {
        #expect(PhotoInfoFormat.resolution(.zero) == "")
        #expect(PhotoInfoFormat.resolution(PixelSize(width: 0, height: 3024)) == "")
    }

    @Test("duration: nil → nil (a still); M:SS under an hour; H:MM:SS at/over an hour (#125)")
    func duration() {
        #expect(PhotoInfoFormat.duration(nil) == nil)          // a still carries no duration → no badge
        #expect(PhotoInfoFormat.duration(0) == "0:00")
        #expect(PhotoInfoFormat.duration(9) == "0:09")
        #expect(PhotoInfoFormat.duration(14) == "0:14")
        #expect(PhotoInfoFormat.duration(65) == "1:05")        // seconds zero-padded, minutes not
        #expect(PhotoInfoFormat.duration(600) == "10:00")
        #expect(PhotoInfoFormat.duration(3661) == "1:01:01")   // an hour+ switches to H:MM:SS
        #expect(PhotoInfoFormat.duration(3600) == "1:00:00")
        // Fractional seconds floor; a stray negative clamps to zero (never a "-1" or a crash).
        #expect(PhotoInfoFormat.duration(14.9) == "0:14")
        #expect(PhotoInfoFormat.duration(-5) == "0:00")
    }
}
