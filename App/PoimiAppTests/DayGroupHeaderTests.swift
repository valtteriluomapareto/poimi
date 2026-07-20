//
//  DayGroupHeaderTests.swift
//  PoimiAppTests — the day-group section title (#35).
//
//  Built from real `DayGrouping` output (not hand-rolled DayGroups) with a fixed UTC calendar +
//  en_US locale, so the single-day / merged-run / undated branches are pinned deterministically.
//  Asserts the salient tokens (month/day/weekday, span separator) rather than exact FormatStyle
//  punctuation, which can shift across SDK/locale data.
//

import Testing
import Foundation
import Curation
@testable import PoimiApp

@Suite("DayGroupHeader (#35)")
struct DayGroupHeaderTests {

    private static let enUS = Locale(identifier: "en_US")

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        utcCalendar().date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    private func title(_ assets: [AssetRef]) -> String {
        let groups = DayGrouping.groups(for: assets, calendar: utcCalendar())
        return DayGroupHeader.title(for: groups[0], calendar: utcCalendar(), locale: Self.enUS)
    }

    @Test("a single-day group reads the FULL weekday, month, day")
    func singleDay() {
        // 2025-07-05 is a Saturday; a handful of photos on one day stays a single-day group.
        let assets = (0..<3).map { AssetRef(id: "a\($0)", captureDate: date(2025, 7, 5)) }
        let header = title(assets)
        #expect(header.contains("Jul"))
        #expect(header.contains("5"))
        #expect(header.contains("Saturday"))   // full weekday now, not abbreviated "Sat"
    }

    @Test("a merged quiet run reads a full-weekday span on BOTH ends")
    func multiDayRun() {
        // One photo each on 2025-03-16/17/18 → a merged quiet run of 3 days (Sun 16 → Tue 18).
        let assets = (16...18).map { AssetRef(id: "q\($0)", captureDate: date(2025, 3, $0)) }
        let header = title(assets)
        #expect(header.contains("Mar"))
        #expect(header.contains("16"))
        #expect(header.contains("18"))
        #expect(header.contains("Sunday"))     // weekday on the start end
        #expect(header.contains("Tuesday"))    // …and the end end
        #expect(header.contains("–"))          // an en-dash span, not a single day
    }

    @Test("the weekday is full + first-letter-capitalized for locales that lower-case it (Finnish)")
    func fullWeekdayCapitalizedFinnish() {
        // 2025-02-15 is a Saturday → Finnish "lauantai", shown capitalized as a title ("Lauantai 15.2.").
        let groups = DayGrouping.groups(for: [AssetRef(id: "x", captureDate: date(2025, 2, 15))],
                                        calendar: utcCalendar())
        let fi = DayGroupHeader.title(for: groups[0], calendar: utcCalendar(), locale: Locale(identifier: "fi_FI"))
        #expect(fi.contains("Lauantai"))       // full weekday, capitalized (locale gives lowercase)
        #expect(fi.contains("15"))
        #expect(!fi.contains("lauantai"))       // …the lowercase form must NOT remain
    }

    @Test("the undated group reads \"Undated\"")
    func undated() {
        let header = title([AssetRef(id: "u", captureDate: nil)])
        #expect(header == "Undated")
    }

    @Test("dayLabel formats one calendar day (weekday, month, day) for the viewer (#36)")
    func dayLabelSingleDay() {
        // The viewer labels each photo with its *own* day — same style as a single-day section.
        let label = DayGroupHeader.dayLabel(for: .day(year: 2025, month: 7, day: 5),
                                            calendar: utcCalendar(), locale: Self.enUS)
        #expect(label.contains("Jul"))
        #expect(label.contains("5"))
        #expect(label.contains("Sat"))   // 2025-07-05 is a Saturday
    }

    @Test("dayLabel reads \"Undated\" for the undated key (#36)")
    func dayLabelUndated() {
        #expect(DayGroupHeader.dayLabel(for: .undated, calendar: utcCalendar(), locale: Self.enUS)
            == "Undated")
    }
}

/// The characterful cluster caption (day-cluster personality). Pins the phrasing layer over the pure,
/// string-free `ClusterCharacter`: the media highlights (video / favourite counts), the leading glyph,
/// the spoken (punctuation-free) VoiceOver variant, and the nil-when-empty contract. Media counts are
/// asserted by `contains` (count + stem), not the exact plural — the "s" is Foundation's automatic
/// inflection, exercised for real on the sim; the deterministic parts (glyph, separators) are exact.
/// (Time-of-day span was dropped as low-signal; a locality descriptor is #201.)
@Suite("ClusterCaption — day-cluster personality")
struct ClusterCaptionTests {

    private func character(video: Int = 0, favorite: Int = 0, count: Int = 10) -> ClusterCharacter {
        ClusterCharacter(assetCount: count, videoCount: video, favoriteCount: favorite)
    }

    @Test("nothing worth saying → nil (the row stays a clean bare date)")
    func empty() {
        #expect(ClusterCaption.content(for: character()) == nil)
    }

    @Test("videos lead with a video glyph; the count + stem render")
    func videos() {
        let c = ClusterCaption.content(for: character(video: 2))
        #expect(c?.symbol == "video.fill")
        #expect(c?.text.contains("2") == true)
        #expect(c?.text.contains("video") == true)
        // Regression guard: the inflection markup MUST resolve (it once leaked "^[2 video](inflect: true)"
        // literally because the key wasn't in the String Catalog). If this fails, the catalog entry is missing.
        #expect(c?.text.contains("inflect") == false)
        #expect(c?.text.contains("^[") == false)
    }

    @Test("favorites-only leads with a heart glyph")
    func favoritesGlyph() {
        let c = ClusterCaption.content(for: character(favorite: 2))
        #expect(c?.symbol == "heart.fill")
        #expect(c?.text.contains("favorite") == true)   // US spelling, matches `isFavorite` / Photos
    }

    @Test("videos + favorites join with a middot (display) / comma (spoken); video leads")
    func videosPlusFavorites() {
        let c = ClusterCaption.content(for: character(video: 2, favorite: 3))
        #expect(c?.symbol == "video.fill")               // video leads when both present
        #expect(c?.text.contains(" · ") == true)         // display uses a middot separator
        #expect(c?.text.contains("video") == true)
        #expect(c?.text.contains("favorite") == true)
        #expect(c?.text.contains("inflect") == false)    // markup resolved, not leaked (catalog entry present)
        #expect(c?.spoken.contains(", ") == true)        // spoken uses commas, not middots
        #expect(c?.spoken.contains("·") == false)
    }

    @Test("singular has no trailing s (inflection agrees)")
    func singular() {
        let c = ClusterCaption.content(for: character(video: 1))
        #expect(c?.text.contains("1 video") == true)
        #expect(c?.text.contains("1 videos") == false)
    }

    // MARK: Locality lead (#201)

    @Test("a mostly-home day leads with a house glyph + 'Mostly at home', media following")
    func homeLeads() {
        let c = ClusterCaption.content(for: character(video: 2), locality: .mostlyHome)
        #expect(c?.symbol == "house")
        #expect(c?.text.hasPrefix("Mostly at home") == true)
        #expect(c?.text.contains(" · ") == true)          // media follows
        #expect(c?.text.contains("video") == true)
    }

    @Test("a mostly-away day leads with a walk glyph + 'Out and about'")
    func awayLeads() {
        let c = ClusterCaption.content(for: character(favorite: 1), locality: .mostlyAway)
        #expect(c?.symbol == "figure.walk")
        #expect(c?.text.hasPrefix("Out and about") == true)
        #expect(c?.text.contains("favorite") == true)
    }

    @Test("a home day with NO media is just the locality (no trailing separator)")
    func homeOnlyNoMedia() {
        let c = ClusterCaption.content(for: character(), locality: .mostlyHome)
        #expect(c?.symbol == "house")
        #expect(c?.text == "Mostly at home")
    }

    @Test("a home-led caption's spoken form is comma-joined, locality-first, middot-free; display order pinned")
    func homeSpoken() {
        let c = ClusterCaption.content(for: character(video: 2, favorite: 1), locality: .mostlyHome)
        #expect(c?.spoken.hasPrefix("Mostly at home, ") == true)
        #expect(c?.spoken.contains("·") == false)                       // spoken uses commas, never middots
        #expect(c?.text == "Mostly at home · 2 videos · 1 favorite")    // display: locality, then media
    }

    @Test("mixed / unknown locality adds no line — the caption is media-only, as before")
    func mixedAndUnknownFallBackToMedia() {
        // mixed with media → media-led (no locality)
        let mixed = ClusterCaption.content(for: character(video: 2), locality: .mixed)
        #expect(mixed?.symbol == "video.fill")
        #expect(mixed?.text.contains("home") == false)
        #expect(mixed?.text.contains("about") == false)
        // unknown with NO media → nil (a bare date), unchanged
        #expect(ClusterCaption.content(for: character(), locality: .unknown) == nil)
    }
}

/// Locks the collapsed-peek "foreground the keeps" ordering (#89 product blocker) so it can't
/// regress to raw chronology.
@Suite("Collapsed peek ordering (#89)")
struct KeptFirstOrderingTests {

    @Test("picked ids move to the front, each side keeps source order")
    func keepsFirst() {
        let ordered = keptFirstOrdering(ids: ["a", "b", "c", "d"], picked: ["b", "d"])
        #expect(ordered == ["b", "d", "a", "c"])
    }

    @Test("zero picks leaves the order untouched")
    func nonePicked() {
        #expect(keptFirstOrdering(ids: ["a", "b", "c"], picked: []) == ["a", "b", "c"])
    }

    @Test("a partition: every id appears exactly once regardless of the picked set")
    func partition() {
        let ids = ["a", "b", "c", "d", "e"]
        let ordered = keptFirstOrdering(ids: ids, picked: ["c", "e", "zzz"])  // "zzz" not in ids
        #expect(Set(ordered) == Set(ids))
        #expect(ordered.count == ids.count)
        #expect(Array(ordered.prefix(2)) == ["c", "e"])   // the in-range picks lead, in source order
    }
}
