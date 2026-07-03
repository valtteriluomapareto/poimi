//
//  ReviewStateViews.swift
//  PoimiApp — the shared empty / failure states for the review scan (issue #40; design 2JE).
//
//  `ScanningView` (the grid) and `AlbumOverviewView` (the cluster index) both drive a
//  `CandidateStore` and must render its non-`.ready` phases identically — so those states live here,
//  once, instead of duplicated in each. Every state is ACTIONABLE / recoverable, never a dead-end:
//  empty points at the range or the exclusions (→ album settings); a transient failure retries; lost
//  access routes to the recovery screen (§10).
//

import SwiftUI

/// Pure, testable copy for the empty state, keyed by reason (the `RecoveryGuidance` pattern). Kept out
/// of the view so the reason→message mapping + the date-range phrasing are unit-tested without rendering.
struct ReviewEmptyCopy: Equatable {
    let title: String
    let message: String

    static func forReason(
        _ reason: CandidateStore.EmptyReason,
        rangeStart: Date, rangeEnd: Date, calendar: Calendar = .current
    ) -> ReviewEmptyCopy {
        // rangeEnd is end-EXCLUSIVE; the message wants the inclusive last day ("…and 31 Dec 2025").
        let style = Date.FormatStyle.dateTime.day().month(.abbreviated).year()
        let lastDay = calendar.date(byAdding: .day, value: -1, to: rangeEnd) ?? rangeEnd
        let range = String(localized: "\(rangeStart.formatted(style)) and \(lastDay.formatted(style))",
                           comment: "A date range embedded in empty-state messages: start and end")
        switch reason {
        case .noPhotosInRange:
            return ReviewEmptyCopy(
                title: String(localized: "No photos in this range",
                              comment: "Empty scan title: the range yielded nothing"),
                message: String(localized: "No photos between \(range). Try a wider date range.",
                                comment: "Empty scan message: %@ is the date range"))
        case .allExcluded:
            return ReviewEmptyCopy(
                title: String(localized: "Everything's filtered out",
                              comment: "Empty scan title: all candidates excluded"),
                message: String(localized: """
                    Every photo between \(range) is a screenshot or in an excluded album. \
                    Try fewer exclusions.
                    """, comment: "Empty scan message: %@ is the date range"))
        }
    }
}

/// The empty state (design 2JE): a range-aware message + actions that actually fix it — Change range
/// and/or Review excluded albums (both land in the album's settings, where period + exclusions live).
struct ReviewEmptyView: View {
    let reason: CandidateStore.EmptyReason
    let rangeStart: Date
    let rangeEnd: Date
    let onChangeRange: () -> Void
    let onReviewExclusions: () -> Void

    var body: some View {
        let copy = ReviewEmptyCopy.forReason(reason, rangeStart: rangeStart, rangeEnd: rangeEnd)
        ContentUnavailableView {
            Label(copy.title, systemImage: "photo.on.rectangle.angled")
        } description: {
            Text(copy.message)
        } actions: {
            switch reason {
            case .noPhotosInRange:
                Button("Change range", action: onChangeRange)
                    .buttonStyle(.borderedProminent)
            case .allExcluded:
                Button("Review exclusions", action: onReviewExclusions)
                    .buttonStyle(.borderedProminent)
                Button("Change range", action: onChangeRange)
            }
        }
    }
}

/// A transient scan failure (iCloud/network) — recoverable with a retry that re-runs the pass.
struct ReviewLoadFailedView: View {
    let onRetry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Couldn't load your photos", systemImage: "exclamationmark.triangle")
        } description: {
            Text("Something went wrong reaching your library. Check your connection and try again.")
        } actions: {
            Button("Try again", action: onRetry)
                .buttonStyle(.borderedProminent)
        }
    }
}

/// Photo access was revoked mid-session: a retry can't succeed, so re-read authorization — that flips
/// the coordinator's root phase to `.recovery`, replacing the whole UI with `AccessRecoveryView` (§10).
/// This is the brief placeholder shown until that swap lands.
struct ReviewAccessLostView: View {
    @Environment(AppCoordinator.self) private var coordinator
    /// Re-run the scan if the re-read comes back authorized after all — so a transient throw that was
    /// mis-read as "access lost" (or an access flap) heals instead of stranding this placeholder.
    let onRecovered: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Photo access changed", systemImage: "lock")
        } description: {
            Text("Checking your photo access…")
        }
        .task {
            await coordinator.refreshAuthorization()
            // Non-authorized → rootPhase flips to .recovery and this view is swapped out. Still
            // authorized → no swap happens, so re-run the scan rather than sit here forever.
            if coordinator.authorization == .authorized { onRecovered() }
        }
    }
}
