import CoreGraphics
import Testing
@testable import KumoneCore

@Suite("Pager swipe decision tests")
struct PagerSwipeDecisionTests {
    @Test func horizontalTravelWithLittleVerticalTravelPages() {
        #expect(PagerSwipeDecision.shouldPage(dx: 100, dy: 10))
        #expect(PagerSwipeDecision.shouldPage(dx: -100, dy: -10))
    }

    @Test func diagonalTravelDoesNotPage() {
        #expect(!PagerSwipeDecision.shouldPage(dx: 100, dy: 80))
        #expect(!PagerSwipeDecision.shouldPage(dx: -100, dy: 80))
    }

    @Test func shortTravelDoesNotPage() {
        #expect(!PagerSwipeDecision.shouldPage(dx: 50, dy: 0))
        #expect(!PagerSwipeDecision.shouldPage(dx: -50, dy: 0))
    }

    @Test func minimumHorizontalDistanceIsInclusive() {
        #expect(PagerSwipeDecision.shouldPage(dx: 60, dy: 0))
        #expect(!PagerSwipeDecision.shouldPage(dx: 59.99, dy: 0))
    }

    @Test func horizontalDominanceIsStrict() {
        // 60 / 1.8 is the exact point where the two rules meet.
        let evenShare = CGFloat(60) / CGFloat(1.8)
        #expect(PagerSwipeDecision.shouldPage(dx: 60, dy: evenShare - 0.01))
        #expect(!PagerSwipeDecision.shouldPage(dx: 60, dy: evenShare + 0.01))
    }

    @Test func verticalOnlyTravelDoesNotPage() {
        #expect(!PagerSwipeDecision.shouldPage(dx: 0, dy: 200))
    }
}
