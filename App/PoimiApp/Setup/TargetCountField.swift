//
//  TargetCountField.swift
//  PoimiApp — the target photo-count control, shared by new-album setup + album settings (issue #123).
//
//  A bare `Stepper(step: 10)` made a large change painful — 100 → 1000 was 90 taps. This pairs a
//  number-pad text field (type "1000" in one go) with the ±10 stepper (fine nudge). Both screens use
//  this ONE component (identical control + bounds) so the setup draft and the persisted edit of the same
//  field stay in sync.
//
//  The number pad has no return key, so the field **commits live** (updates `count` on every keystroke),
//  NOT on focus-loss: tapping Create / swiping back without first dismissing the keyboard therefore can't
//  lose the typed value. The host `Form` adds `.scrollDismissesKeyboard(.interactively)` for a reliable
//  dismiss, and a keyboard "Done" button is the discoverable one. The `1...10_000` bound is a UI
//  affordance (clamped here + on the stepper), not a persisted data invariant — a non-view caller could
//  still set any `Int`; nothing downstream depends on the cap.
//

import SwiftUI

struct TargetCountField: View {
    @Binding var count: Int
    private let range: ClosedRange<Int>
    /// The field's live text — decoupled from `count` so typing isn't fought by a reformat mid-entry;
    /// resynced from `count` when not actively editing (stepper changes, and the clamped value on blur).
    @State private var text: String
    @FocusState private var focused: Bool

    init(count: Binding<Int>, range: ClosedRange<Int> = 1...10_000) {
        _count = count
        self.range = range
        _text = State(initialValue: String(count.wrappedValue))
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                TextField("Target", text: $text)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .focused($focused)
                    .fixedSize()
                    .accessibilityLabel(Text("Target photo count"))
                Stepper(value: $count, in: range, step: 10) { EmptyView() }
                    .labelsHidden()
                    .accessibilityLabel(Text("Adjust target by ten"))
            }
        } label: {
            // The live, inflected target ("1,000 photos") — consistent across both screens, and localized
            // (the count drives the plural). The field to the right edits it.
            Text("^[\(count) photo](inflect: true)")
        }
        // Live-commit: `count` follows what's typed on every keystroke (no reliance on focus-loss), so an
        // edit is never lost by tapping Create / navigating away with the pad still up. Non-digits are
        // stripped; an empty field leaves the last value; the parsed value is clamped to `range`.
        .onChange(of: text) { _, new in
            let digits = new.filter(\.isNumber)
            if digits != new { text = digits; return }
            if let parsed = Int(digits) { count = Self.clamped(parsed, in: range) }
        }
        // When NOT editing, keep the field showing `count` — reflects the stepper, and (on blur) snaps the
        // text to the clamped value (e.g. an emptied or over-max entry).
        .onChange(of: count) { if !focused { text = String(count) } }
        .onChange(of: focused) { if !focused { text = String(count) } }
    }

    /// Clamp a value into `range` — pure + testable (the empty-field-reverts behavior is SwiftUI's,
    /// exercised on device).
    static func clamped(_ value: Int, in range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
