//
//  TargetCountField.swift
//  PoimiApp — the target photo-count control, shared by new-album setup + album settings (issue #123).
//
//  A bare `Stepper(step: 10)` made a large change painful — 100 → 1000 was 90 taps. This is a plain
//  number-pad text field: type the target directly. (The earlier field-plus-stepper combo was confusing
//  — the field didn't track the ± buttons and the number pad had no obvious dismiss, #159 follow-up — so
//  it's manual entry only now.) Both screens use this ONE component so the setup draft and the persisted
//  edit of the same field stay identical.
//
//  Dismissing the number pad (it has no return key): a keyboard "Done" button is the discoverable way,
//  and the host `Form`'s `.scrollDismissesKeyboard(.interactively)` lets a swipe dismiss too. The field
//  **commits live** (updates `count` on every keystroke), so tapping Create / leaving the screen without
//  first dismissing the keyboard can't lose the typed value. The `1...10_000` bound is a UI affordance
//  (clamped here), not a persisted data invariant.
//

import SwiftUI

struct TargetCountField: View {
    @Binding var count: Int
    private let range: ClosedRange<Int>
    /// The field's live text — decoupled from `count` so a mid-entry reformat never fights typing;
    /// resynced from `count` when editing ends (an emptied / over-max entry snaps to the clamped value).
    @State private var text: String
    @FocusState private var focused: Bool

    init(count: Binding<Int>, range: ClosedRange<Int> = 1...10_000) {
        _count = count
        self.range = range
        _text = State(initialValue: String(count.wrappedValue))
    }

    var body: some View {
        LabeledContent {
            TextField("Target", text: $text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .fixedSize()
                .accessibilityLabel(Text("Target photo count"))
                .toolbar {
                    // A "Done" above the number pad — the discoverable dismiss (the pad has no return key).
                    if focused {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") { focused = false }
                        }
                    }
                }
        } label: {
            // The live, inflected target ("1,000 photos") — consistent across both screens, localized
            // (the count drives the plural).
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
        // Snap the field to the committed (clamped) value when editing ends, or if `count` is changed
        // elsewhere while we're not editing.
        .onChange(of: focused) { if !focused { text = String(count) } }
        .onChange(of: count) { if !focused { text = String(count) } }
    }

    /// Clamp a value into `range` — pure + testable (the empty-field-reverts behavior is SwiftUI's,
    /// exercised on device).
    static func clamped(_ value: Int, in range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
