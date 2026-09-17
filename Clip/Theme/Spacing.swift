import SwiftUI

/// The app's spacing scale: a straight 4pt ladder, named by the relationship
/// each step encodes rather than by its number.
///
/// A raw number tells a reader nothing about intent — a future edit sees
/// `spacing: 12` and has no way to know whether that was "these are one
/// idea" or "these are two ideas that happen to sit near each other". A role
/// name answers that question at the call site. The ladder itself stays on
/// 4pt steps (4, 8, 12, 16, 20, 24, 28, 32) because a UI built from one ruler
/// reads as one system; a view three points tighter than its neighbour reads
/// as hand-tuned, not designed.
///
/// Values below 4 (a 1-3pt nudge) are not spacing at all — they are optical
/// corrections (aligning a glyph's baseline to the text beside it) and are
/// left as literals where they occur, called out in a comment at the call
/// site. Converting those into a spacing step would blur the one thing that
/// makes a scale useful: every number on it means "a gap", full stop.
enum Spacing {
    /// Between a glyph and the label it belongs to, or between two marks
    /// that read as one unit (an icon and the badge glued to it). The
    /// smallest real gap the app draws.
    static let inline: CGFloat = 4
    /// Between closely related lines inside one item: a title and the
    /// timestamp under it, the two halves of a compact row.
    static let tight: CGFloat = 8
    /// Between items in a run: chips in a filter rail, fields inside one
    /// row, rows in a dense list.
    static let related: CGFloat = 12
    /// The default gap between independent elements — a row's own inset, the
    /// padding around a standalone control, the rhythm inside one group.
    static let comfortable: CGFloat = 16
    /// Between a labelled group and the next one, or before a control that
    /// acts on everything above it — enough air that the two read as
    /// separate moves, not one long list.
    static let group: CGFloat = 20
    /// Between sections that are visually distinct within the same surface:
    /// a card's outer margin, the gap either side of a real topic change.
    static let section: CGFloat = 24
    /// Panel-level inset — where content meets the edge of a window or an
    /// overlay's own frame.
    static let panel: CGFloat = 28
    /// The most generous gap the app uses: framing a whole overlay away from
    /// the screen edge, or a hero empty state.
    static let loose: CGFloat = 32
}
