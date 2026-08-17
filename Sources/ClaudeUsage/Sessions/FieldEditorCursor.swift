import AppKit

/// Places the insertion point after a title click hands focus to a rename
/// field. AppKit's take-focus default selects the whole text, which arms a
/// touch-up click to destroy the entire name; the caret belongs on the
/// clicked character (or at the end, when the point can't be mapped).
@MainActor
enum FieldEditorCursor {
    /// `windowPoint` is the triggering click in window coordinates. Focus
    /// reaches the field editor a beat after the SwiftUI binding flips, so
    /// placement retries across a few short hops and then gives up quietly —
    /// the field stays usable with the default selection.
    static func place(near windowPoint: CGPoint?, attemptsLeft: Int = 8) {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else {
            if attemptsLeft > 0 {
                Task {
                    try? await Task.sleep(for: .milliseconds(20))
                    place(near: windowPoint, attemptsLeft: attemptsLeft - 1)
                }
            }
            return
        }
        let length = (editor.string as NSString).length
        var index = length
        if let windowPoint {
            let local = editor.convert(windowPoint, from: nil)
            index = min(editor.characterIndexForInsertion(at: local), length)
        }
        editor.selectedRange = NSRange(location: index, length: 0)
    }
}
