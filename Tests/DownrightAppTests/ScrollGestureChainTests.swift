import AppKit
import Testing
@testable import DownrightApp

@Suite(.serialized)
@MainActor
struct ScrollGestureChainTests {

    private final class Stub: ScrollGestureHandler {
        var claims = false
        var owns = false
        private(set) var seen = 0

        var isClaimingGesture: Bool { owns }

        func handle(_ event: NSEvent) -> Bool {
            seen += 1
            return claims
        }
    }

    private func event() throws -> NSEvent {
        try SyntheticScroll.event(deltaY: -12)
    }

    @Test
    func theFirstHandlerToClaimEndsTheChain() throws {
        let first = Stub()
        let second = Stub()
        let third = Stub()
        second.claims = true
        let chain = ScrollGestureChain([first, second, third])

        #expect(chain.handle(try event()))
        #expect(first.seen == 1)
        #expect(second.seen == 1)
        // Two gestures acting on one event is a page that scrolls and zooms at
        // the same time; the one behind the winner never hears about it.
        #expect(third.seen == 0)
    }

    @Test
    func handlersThatDeclineStillSeeEveryEvent() throws {
        let first = Stub()
        let second = Stub()
        let chain = ScrollGestureChain([first, second])

        // Both swipes spend the first few events deciding, and they can only
        // decide by accumulating travel — so declining must not cost them the
        // events they are declining.
        #expect(!chain.handle(try event()))
        #expect(!chain.handle(try event()))
        #expect(first.seen == 2)
        #expect(second.seen == 2)
    }

    @Test
    func aGestureThatHasAlreadyCaughtKeepsTheRestOfIt() throws {
        let first = Stub()
        let second = Stub()
        first.claims = true
        second.owns = true
        let chain = ScrollGestureChain([first, second])

        // The swipe on screen owns the fingers.  Polling from the top here is
        // how a modifier pressed halfway through a swipe would hand the events
        // to a zoom and leave a translated pane nobody owns.
        #expect(!chain.handle(try event()))
        #expect(first.seen == 0)
        #expect(second.seen == 1)

        second.owns = false
        #expect(chain.handle(try event()))
        #expect(first.seen == 1)
        #expect(second.seen == 1)
    }

    @Test
    func anEventNobodyWantsGoesStraightBackToTheScrollView() throws {
        let chain = ScrollGestureChain([Stub(), Stub()])
        #expect(!chain.handle(try event()))
    }
}
