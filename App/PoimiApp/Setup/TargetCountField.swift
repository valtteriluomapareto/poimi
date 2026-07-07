//
//  TargetCountField.swift
//  PoimiApp — the target photo-count control, shared by new-album setup + album settings (issue #123).
//
//  A bare `Stepper(step: 10)` made a large change painful — 100 → 1000 was 90 taps. This pairs a
//  number-pad text field (type "1000" in one go) with the ±10 stepper (fine nudge) in one row, clamped
//  to the allowed range. Both screens use this ONE component so the setup draft and the persisted edit
//  of the same field stay identical (same control, same bounds).
//

import SwiftUI

struct TargetCountField: View {
    private let title: LocalizedStringKey
    @Binding var count: Int
    private let range: ClosedRange<Int>
    /// Focus on the number field, so a keyboard "Done" can dismiss the number pad (which has no return
    /// key) — and leaving the field commits + clamps the entry.
    @FocusState private var focused: Bool

    init(_ title: LocalizedStringKey, count: Binding<Int>, range: ClosedRange<Int> = 1...10_000) {
        self.title = title
        _count = count
        self.range = range
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                // `value:format:` handles String↔Int parsing + rejects non-numbers; it commits on
                // focus-loss (the number pad has no return), so `count` — and the live tally bound to it
                // — updates when you leave the field. An empty/invalid entry reverts to the current value.
                TextField(title, value: $count, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .focused($focused)
                    .fixedSize()
                    .accessibilityLabel(Text("Target photo count"))
                Stepper(value: $count, in: range, step: 10) { EmptyView() }
                    .labelsHidden()
            }
        }
        // Clamp direct entry to the bounds (the stepper is already bounded). A value the field committed
        // out of range (e.g. 99999, or 0) snaps back in; idempotent for in-range stepper changes.
        .onChange(of: count) { _, new in
            let clamped = Self.clamped(new, in: range)
            if clamped != new { count = clamped }
        }
        .toolbar {
            if focused {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focused = false }
                }
            }
        }
    }

    /// Clamp a committed value into `range` — pure + testable (the empty-field-reverts behavior is
    /// SwiftUI's, exercised on device).
    static func clamped(_ value: Int, in range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
