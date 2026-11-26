import CoreGraphics

/// Decides whether a drag across the lyrics page is a deliberate horizontal
/// page turn rather than the start of a vertical lyric scroll.
///
/// The pager keeps the platform's own page swipe; this only answers the
/// "should the finger travel count as a turn" question so the rule can be
/// tested without a running view.
enum PagerSwipeDecision {
    /// Horizontal travel below this never turns a page, however straight the
    /// drag is.
    static let minimumHorizontalDistance: CGFloat = 60
    /// The horizontal travel must beat the vertical travel by this factor, so
    /// a diagonal lyric scroll stays a scroll.
    static let horizontalDominance: CGFloat = 1.8

    static func shouldPage(dx: CGFloat, dy: CGFloat) -> Bool {
        let horizontal = abs(dx)
        return horizontal >= minimumHorizontalDistance
            && horizontal > horizontalDominance * abs(dy)
    }
}
