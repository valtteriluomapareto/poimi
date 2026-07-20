//
//  ExportView.swift
//  PoimiApp — album export + completion (issue #39, D19/D31/D34; design 2DN + the export-state mocks).
//
//  The terminal step of a curation: write the picked photos into a native Photos album, then celebrate.
//  Reached from the review grid's Export action (`coordinator.openExport`). `ExportStore` runs the
//  create-or-find + dupe-guarded add through the `\.photoLibrary` write seam (SystemPhotoLibrary); on
//  success it stamps the project's `targetAlbumID` (the created album) + `markedDoneAt` (→ status .done)
//  — a ONE-WAY copy that never reads the album back (D31). The screen is a small state machine:
//  working → completion (first export / re-export copy) or a recoverable error.
//
//  Completion stats reuse the review scan's `id → DayKey` map (the coordinator's `reviewDayByID`), so
//  the celebration needs no second scan. Review STATE (done/picked) is the list's job; here we only
//  summarize (Picked / Reviewed / Kept, `CompletionStats`).
//

import SwiftUI
import UIKit
import Curation

/// The finish/export action's label. **Photos-qualified** so it reads as the boundary to the Photos
/// app — the in-app "album" the user has been building becomes a Photos album here (#185). First export
/// creates it ("Save to Photos"); a re-export updates the album already created ("Update in Photos").
/// A pure function (derived from `project.targetAlbumID != nil`) so the choice is unit-tested, not
/// eyeballed. Returns a resolved `String`, so the call site uses `Button(_:action:)`'s verbatim overload
/// (no double-localization).
func finishActionLabel(isReExport: Bool) -> String {
    isReExport
        ? String(localized: "Update in Photos",
                 comment: "Finish action: re-export to the album already created in Photos")
        : String(localized: "Save to Photos",
                 comment: "Finish action: first export creates the album in Photos")
}

/// Drives the export: one `run` per attempt, publishing the phase the screen renders.
@MainActor
@Observable
final class ExportStore {
    enum Phase: Equatable {
        /// Working. `isReExport` picks the "Creating…" vs "Updating…" copy (captured from the attempt,
        /// so a forceNewAlbum recovery reads "Creating…" even though a stale `targetAlbumID` is set).
        case exporting(isReExport: Bool)
        /// Succeeded. `wasReExport` picks the "Album updated" vs "Your album is ready" copy.
        case done(ExportResult, wasReExport: Bool)
        /// Failed. `canCreateNew` is set when we were updating an EXISTING album (offer a fresh one).
        case failed(ExportError, canCreateNew: Bool)
    }

    private(set) var phase: Phase = .exporting(isReExport: false)
    private let library: any PhotoLibraryProviding

    init(library: any PhotoLibraryProviding) {
        self.library = library
    }

    /// Export `picks` into `project`'s album. `forceNewAlbum` ignores any stored `targetAlbumID` (the
    /// error screen's "create a new album instead" recovery when the existing one is gone).
    func run(project: CurationProject, picks: Set<String>, forceNewAlbum: Bool = false) async {
        let existing = forceNewAlbum ? nil : project.targetAlbumID
        phase = .exporting(isReExport: existing != nil)
        do {
            let result = try await library.export(
                assetIDs: picks, toAlbumNamed: project.title, existingAlbumID: existing)
            // Persist OUR state only: the created/found album id + the finalize stamp (never the album
            // contents — D31). Save explicitly at the seam (like ProjectStore/DoneStore) so this — the
            // album's only durable "exported" record — can't be lost to a deferred autosave.
            project.targetAlbumID = result.albumID
            if project.markedDoneAt == nil { project.markedDoneAt = Date.now }   // FIRST export only
            // Stamp the additions-only drift baseline (#191) on EVERY export (incl. the "already up to
            // date" path — same `.done` phase), so editing picks after this shows "edited since export"
            // and a re-export clears it. Fingerprint the user's PICKS (`picks`), not the resolved subset.
            project.exportedSelectionSnapshot = try? SelectionSnapshot(assetIDs: picks).encoded()
            project.exportedPhotoCount = result.total   // the TRUE album membership — honest "N in Photos"
            project.lastExportedAt = Date.now
            do {
                try project.modelContext?.save()
            } catch {
                Log.app.error("export: couldn't persist finalize: \(String(describing: error), privacy: .public)")
            }
            phase = .done(result, wasReExport: existing != nil)
        } catch let error as ExportError {
            phase = .failed(error, canCreateNew: existing != nil)
        } catch {
            phase = .failed(.writeFailed, canCreateNew: existing != nil)
        }
    }
}

struct ExportView: View {
    let project: CurationProject
    @Environment(\.photoLibrary) private var library
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(SelectionStore.self) private var selection
    @Environment(DoneStore.self) private var doneStore
    @Environment(\.openURL) private var openURL
    @State private var store: ExportStore?

    /// Production callers pass no `store` (the `.task` creates + runs one). The screenshot harness may
    /// inject a pre-run store so a settled state (completion / error) renders deterministically.
    init(project: CurationProject, store: ExportStore? = nil) {
        self.project = project
        _store = State(initialValue: store)
    }
    /// Grace-gate the working spinner so an instant export never flashes it.
    @State private var spinnerVisible = false

    var body: some View {
        content
            // Terminal, full-bleed flow: the on-screen actions are the only way out (no nav chrome, no
            // system back mid-write — the working state shouldn't be interruptible into a half state).
            .toolbar(.hidden, for: .navigationBar)
            .navigationBarBackButtonHidden(true)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
            .task {
                selection.activate(project)
                doneStore.activate(project)
                let resolved = store ?? ExportStore(library: library)
                store = resolved
                // Run once on appear; re-runs (Try again / Create new) are driven by the buttons.
                if case .exporting = resolved.phase {
                    await resolved.run(project: project, picks: selection.selected)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch store?.phase ?? .exporting(isReExport: false) {
        case .exporting(let isReExport):
            working(isReExport: isReExport)
        case .done(let result, let wasReExport):
            completion(result: result, wasReExport: wasReExport)
        case .failed(let error, let canCreateNew):
            failure(error: error, canCreateNew: canCreateNew)
        }
    }

    // MARK: Working

    private func working(isReExport: Bool) -> some View {
        VStack(spacing: 20) {
            // A gold indeterminate spinner (the branded loading moment).
            ProgressView()
                .controlSize(.large)
                .tint(.accentColor)
                .opacity(spinnerVisible ? 1 : 0)
            albumLabel(project.title)   // destination not yet resolved mid-write — use the project title
            Text(isReExport ? "Updating your album…" : "Creating your album…")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Text("Adding your \(selection.selected.count.formatted()) photos to \(project.title).")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .task {
            spinnerVisible = false
            try? await Task.sleep(for: .milliseconds(300))
            spinnerVisible = true
        }
    }

    // MARK: Completion (success / re-export)

    private func completion(result: ExportResult, wasReExport: Bool) -> some View {
        let stats = CompletionStats(dayByID: coordinator.reviewDayByID,
                                    doneDays: doneStore.doneDays,
                                    selection: selection.selected)
        return VStack(spacing: 0) {
            Spacer(minLength: 40)
            VStack(spacing: 16) {
                albumLabel(result.title)   // the album the photos actually landed in (#193)
                Text(wasReExport ? "Album updated" : "Your album is ready")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text(completionSubtitle(result: result, wasReExport: wasReExport, stats: stats))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                statCard(stats)
                    .padding(.top, 12)
                // Partial first export: some picks couldn't be resolved (deleted/offline since picking),
                // so the album has fewer than picked. Say so honestly rather than overstating the count.
                if !wasReExport, result.added < stats.totalPicked {
                    Text("""
                        ^[\(stats.totalPicked - result.added) photo](inflect: true) \
                        couldn’t be added — no longer in your library.
                        """)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
                // Where the payoff landed — iOS has no public deep-link to a specific album, so point
                // the user at Photos by name rather than a button that can't reach it. Use the resolved
                // destination title so a re-export names the album the photos are actually in (#193).
                Text("Find it in Photos, in the album “\(result.title)”.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            Spacer(minLength: 20)
            actionButton("Back to albums", role: .primary) { coordinator.popToRoot() }
                .accessibilityIdentifier("completionBackToAlbums")
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }

    private func completionSubtitle(result: ExportResult, wasReExport: Bool, stats: CompletionStats) -> String {
        // `.formatted()` keeps locale number grouping ("1,847"); it lands as a %@ arg in the key.
        if wasReExport {
            // `result.title` (not `project.title`): a re-export can target an existing album whose name
            // differs from the project — name the album the photos are actually in (#193).
            return result.added > 0
                ? String(localized: """
                    Added \(result.added.formatted()) photos · \(result.title) now holds \(result.total.formatted()).
                    """, comment: "Re-export subtitle: N newly added, album total M")
                : String(localized: "\(result.title) is already up to date · \(result.total.formatted()) photos.",
                         comment: "Re-export subtitle: nothing new to add")
        }
        return stats.markedDone > 0
            ? String(localized: """
                \(stats.totalPicked.formatted()) photos, hand-picked from \(stats.markedDone.formatted()) \
                — one tap at a time.
                """, comment: "Completion subtitle: N picked from M reviewed days")
            : String(localized: "\(stats.totalPicked.formatted()) photos, hand-picked — one tap at a time.",
                     comment: "Completion subtitle: N picked, no days marked done")
    }

    private func statCard(_ stats: CompletionStats) -> some View {
        HStack(spacing: 0) {
            stat(value: stats.totalPicked.formatted(), label: "Picked", gold: false)
            // Reviewed/Kept are meaningful only against marked-done days; with none marked done a
            // "0 Reviewed · 0% Kept" reads as failure on a celebration, so show just the pick count.
            if stats.markedDone > 0 {
                statDivider
                stat(value: stats.markedDone.formatted(), label: "Reviewed", gold: false)
                statDivider
                stat(value: "\(Int((stats.fractionKept * 100).rounded()))%", label: "Kept", gold: true)
            }
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // `label` is a LocalizedStringKey so the call-site literals ("Picked"/"Reviewed"/"Kept") extract +
    // localize; `value` stays a String (a formatted number, shown verbatim).
    private func stat(value: String, label: LocalizedStringKey, gold: Bool) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2.bold())
                .foregroundStyle(gold ? Color.accentColor : .primary)
                .monospacedDigit()
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var statDivider: some View {
        Rectangle().fill(Color(.separator)).frame(width: 1, height: 30)
    }

    // MARK: Failure

    private func failure(error: ExportError, canCreateNew: Bool) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 40)
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 52, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                    .padding(.bottom, 8)
                albumLabel(project.title)   // export failed — no resolved destination to name
                Text(canCreateNew ? "Couldn’t update the album" : "Couldn’t create the album")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text(failureMessage(error))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer(minLength: 20)
            VStack(spacing: 12) {
                if error == .notAuthorized {
                    // Retrying can't succeed until access changes, so send them to Settings.
                    actionButton("Open Settings", role: .primary) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                } else {
                    actionButton("Try again", role: .primary) {
                        Task { await store?.run(project: project, picks: selection.selected) }
                    }
                    if canCreateNew {
                        actionButton("Create a new album instead", role: .secondary) {
                            Task { await store?.run(project: project, picks: selection.selected, forceNewAlbum: true) }
                        }
                    }
                }
                actionButton("Back to albums", role: .tertiary) { coordinator.popToRoot() }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }

    private func failureMessage(_ error: ExportError) -> String {
        switch error {
        case .notAuthorized:
            return String(localized: "Poimi needs full photo access to create an album. You can grant it in Settings.",
                          comment: "Export error: authorization not full")
        case .albumMissing:
            return String(localized: "The album was removed from Photos. Your picks are safe — create it again.",
                          comment: "Export error: the target Photos album was deleted")
        case .noAssetsResolved:
            return String(localized: "Those photos are no longer available in your library.",
                          comment: "Export error: none of the picked assets resolved")
        case .writeFailed:
            return String(localized: "Something went wrong adding your photos. Your picks are safe — try again.",
                          comment: "Export error: generic write failure")
        }
    }

    // MARK: Shared bits

    /// The album name in gold caps — "BEST OF 2025". Takes the title so completion can show the
    /// resolved destination album's real name (#193), while working/failure use the project title
    /// (the destination isn't resolved until the export returns).
    private func albumLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.footnote.weight(.semibold))
            .tracking(2)
            .foregroundStyle(Color.accentColor)
            .lineLimit(1)
    }

    private enum ButtonRole { case primary, secondary, tertiary }

    @ViewBuilder
    private func actionButton(_ title: LocalizedStringKey, role: ButtonRole, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(role == .tertiary ? .medium : .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .foregroundStyle(buttonForeground(role))
                .background(buttonBackground(role))
                .overlay {
                    if role == .secondary {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color(.separator), lineWidth: 1.5)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private func buttonForeground(_ role: ButtonRole) -> Color {
        switch role {
        case .primary: return Color(.systemBackground)   // dark text on the light fill (inverts in light mode)
        case .secondary: return .primary
        case .tertiary: return .secondary
        }
    }

    @ViewBuilder
    private func buttonBackground(_ role: ButtonRole) -> some View {
        switch role {
        case .primary:
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary)
        case .secondary, .tertiary:
            Color.clear
        }
    }
}
