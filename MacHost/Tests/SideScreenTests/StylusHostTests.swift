import CoreGraphics
import XCTest
@testable import SideScreen

/// The host is where planning meets geometry, and the failure mode that lives
/// only here is an ordering one: the planner is a state machine, so asking it to
/// plan and *then* discovering the steps cannot be performed loses the state
/// transition permanently. These tests drive the real host with a capturing post
/// operation, so nothing reaches the live session.
final class StylusHostTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)

    private func sample(_ x: Double, _ y: Double, _ pressure: Double = 0.5) -> StylusSample {
        StylusSample(x: x, y: y, pressure: pressure)
    }

    private func message(_ action: StylusAction, _ samples: StylusSample...) -> StylusMessage {
        StylusMessage(action: action, samples: samples)
    }

    /// A host whose display bounds the test controls, plus the events it posted.
    private final class Harness {
        var bounds: CGRect?
        var posted: [CGEvent] = []
        var cancelledGestures = 0
        var fingerButtonHeld = false
        private(set) var host: StylusHost!

        init(bounds: CGRect?) {
            self.bounds = bounds
            host = StylusHost(
                eventSource: CGEventSource(stateID: .hidSystemState),
                displayBounds: { [weak self] in self?.bounds },
                cancelHostGesture: { [weak self] in self?.cancelledGestures += 1 },
                fingerButtonHeld: { [weak self] in self?.fingerButtonHeld ?? false },
                post: { [weak self] in self?.posted.append($0) }
            )
        }

        var types: [CGEventType] { posted.map { $0.type } }

        /// Proximity is a mouse-moved event underneath; the enter/exit flag is what
        /// separates it from a cursor move.
        var proximityFlags: [Int64] {
            posted
                .filter { $0.getIntegerValueField(.mouseEventSubtype) == StylusInjector.tabletProximitySubtype }
                .map { $0.getIntegerValueField(.tabletProximityEventEnterProximity) }
        }
    }

    /// The regression this ordering exists for. With no display bounds yet, the
    /// message must be refused *before* the planner is asked to plan — a planner
    /// that has already opened a stroke, entered proximity or committed to a mouse
    /// up whose steps were then discarded will never produce them again.
    func testAMessageWithNoDisplayBoundsDoesNotMutateThePlanner() {
        let harness = Harness(bounds: nil)

        harness.host.handle(message(.down, sample(0.5, 0.5)))
        XCTAssertTrue(harness.posted.isEmpty, "there is nowhere to post it")
        XCTAssertFalse(harness.host.suppressesFingerEvent(),
                       "a stroke the host could not perform must not be open in the planner")

        harness.host.handle(message(.up, sample(0.5, 0.5, 0)))
        XCTAssertTrue(harness.posted.isEmpty)

        // The display arrives. The next stroke is a complete, balanced one — the
        // refused messages left nothing behind.
        harness.bounds = bounds
        harness.host.handle(message(.down, sample(0.5, 0.5)))
        XCTAssertTrue(harness.host.suppressesFingerEvent())
        harness.host.handle(message(.up, sample(0.5, 0.5, 0)))
        XCTAssertFalse(harness.host.suppressesFingerEvent())

        XCTAssertEqual(harness.types, [.mouseMoved, .mouseMoved, .leftMouseDown, .leftMouseUp, .mouseMoved])
        XCTAssertEqual(harness.proximityFlags, [1, 0], "exactly one balanced proximity pair")
    }

    /// The same rule for hover: a hover enter that cannot be performed must not
    /// latch `inProximity`, or the exit that follows it is planned as a no-op and
    /// the host is left tracking a pen no app ever saw enter.
    func testAHoverEnterWithNoDisplayBoundsDoesNotLatchProximity() {
        let harness = Harness(bounds: nil)
        harness.host.handle(message(.hover, sample(0.2, 0.2, 0)))
        XCTAssertTrue(harness.posted.isEmpty)

        harness.bounds = bounds
        harness.host.handle(message(.hover, sample(0.3, 0.3, 0)))
        XCTAssertEqual(harness.proximityFlags, [1],
                       "the enter is posted by the first message that could be performed")
    }

    /// A close with no geometry is refused the same way, and loses nothing: bounds
    /// are captured the moment a stroke or a hover opens, so a planner with
    /// anything to close always has somewhere to close it.
    func testCloseAfterTheDisplayGoesAwayStillReleasesAtTheStrokesGeometry() {
        let harness = Harness(bounds: bounds)
        harness.host.handle(message(.down, sample(0.5, 0.5)))
        harness.posted.removeAll()

        harness.bounds = nil
        harness.host.close(.clientDisconnected)

        XCTAssertEqual(harness.types, [.leftMouseUp, .mouseMoved])
        XCTAssertEqual(harness.proximityFlags, [0])
        XCTAssertFalse(harness.host.suppressesFingerEvent())
    }

    /// Finding 3, end to end: the host reads its owner's gesture state on every
    /// hover message rather than caching it, so the cursor is released the moment
    /// the finger is.
    func testHoverCursorMovesAreWithheldWhileTheHostHoldsAButton() {
        let harness = Harness(bounds: bounds)
        harness.fingerButtonHeld = true
        harness.host.handle(message(.hover, sample(0.2, 0.2, 0)))
        harness.host.handle(message(.hover, sample(0.6, 0.6, 0)))
        XCTAssertEqual(harness.proximityFlags, [1], "proximity is still reported")
        XCTAssertEqual(harness.types, [.mouseMoved], "the proximity event only — no cursor move")

        harness.fingerButtonHeld = false
        harness.posted.removeAll()
        harness.host.handle(message(.hover, sample(0.7, 0.7, 0)))
        XCTAssertEqual(harness.types, [.mouseMoved])
        XCTAssertEqual(harness.proximityFlags, [], "this one is a cursor move, not proximity")
    }
}
