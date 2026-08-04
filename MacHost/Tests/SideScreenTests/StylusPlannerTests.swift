import CoreGraphics
import XCTest
@testable import SideScreen

/// The stroke lifecycle is the one place in the stylus path where the
/// proximity-balance and stuck-button bugs can be caught without a device, so
/// these tests assert whole step sequences rather than individual steps.
final class StylusPlannerTests: XCTestCase {
    private var planner = StylusPlanner()

    override func setUp() {
        super.setUp()
        planner = StylusPlanner()
    }

    // MARK: - Helpers

    /// The virtual display these strokes are drawn on. Samples are normalized and
    /// `GestureThresholds` is in points, so the tap bounds only mean something
    /// against a size: 0.01 normalized is 10 points across this one.
    private let displaySize = CGSize(width: 1000, height: 800)

    private func sample(_ x: Double, _ y: Double, _ pressure: Double = 0.5) -> StylusSample {
        StylusSample(x: x, y: y, pressure: pressure)
    }

    private func message(_ action: StylusAction, _ samples: StylusSample...) -> StylusMessage {
        StylusMessage(action: action, samples: samples)
    }

    /// The timer-arming steps are bookkeeping, not gesture output. Stripping
    /// them lets a test state the gesture sequence the way the requirement
    /// does, without losing the exact-equality assertions above.
    private func gestureSteps(_ steps: [StylusStep]) -> [StylusStep] {
        steps.filter {
            if case .armStaleTimeout = $0 { return false }
            return true
        }
    }

    private func armInterval(_ step: StylusStep?) -> TimeInterval? {
        guard case .armStaleTimeout(let after)? = step else { return nil }
        return after
    }

    /// A full stroke: down, three moves, up. Returns every step in order.
    private func drawThreeSegmentStroke(startingAt time: TimeInterval = 100) -> [StylusStep] {
        var steps = planner.plan(message(.down, sample(0.10, 0.10, 0.20)), displaySize: displaySize, now: time)
        steps += planner.plan(message(.move, sample(0.20, 0.20, 0.30)), displaySize: displaySize, now: time + 0.01)
        steps += planner.plan(message(.move, sample(0.30, 0.30, 0.40)), displaySize: displaySize, now: time + 0.02)
        steps += planner.plan(message(.move, sample(0.40, 0.40, 0.50)), displaySize: displaySize, now: time + 0.03)
        steps += planner.plan(message(.up, sample(0.50, 0.50, 0.10)), displaySize: displaySize, now: time + 0.04)
        return steps
    }

    /// One tap: down and up in the same place, well inside the tap bounds.
    /// Returns every step both messages produced.
    private func tap(at x: Double, _ y: Double, from start: TimeInterval,
                     lasting duration: TimeInterval = 0.05) -> [StylusStep] {
        var steps = planner.plan(message(.down, sample(x, y, 0.5)), displaySize: displaySize, now: start)
        steps += planner.plan(message(.up, sample(x, y, 0)), displaySize: displaySize, now: start + duration)
        return steps
    }

    /// The click count of every press and release in order, so a test can see a
    /// mismatched pair — the specific bug `76247b7` fixed on the finger path.
    private func clickCounts(_ steps: [StylusStep]) -> [Int] {
        steps.compactMap { step in
            switch step {
            case .mouseDown(_, let count), .mouseUp(_, let count): return count
            default: return nil
            }
        }
    }

    // MARK: - R26: a press and its release declare a matching click count

    func testASingleTapDeclaresClickOneOnBothPressAndRelease() {
        XCTAssertEqual(clickCounts(tap(at: 0.5, 0.5, from: 10)), [1, 1])
    }

    func testAQuickNearbySecondTapIsClickTwoOnBothPressAndRelease() {
        _ = tap(at: 0.5, 0.5, from: 10)
        // 0.1s after the first tap released, one point away from it: inside both
        // `doubleTapMaxTime` and `doubleTapMaxDistance`.
        XCTAssertEqual(clickCounts(tap(at: 0.501, 0.5, from: 10.15)), [2, 2])
    }

    func testAThirdTapDoesNotChainToClickThree() {
        _ = tap(at: 0.5, 0.5, from: 10)
        XCTAssertEqual(clickCounts(tap(at: 0.5, 0.5, from: 10.15)), [2, 2])
        // The double click is complete; the next tap starts a fresh sequence
        // rather than riding the same window.
        XCTAssertEqual(clickCounts(tap(at: 0.5, 0.5, from: 10.3)), [1, 1])
    }

    func testASecondTapOutsideTheTimeWindowIsClickOne() {
        _ = tap(at: 0.5, 0.5, from: 10)
        XCTAssertEqual(clickCounts(tap(at: 0.5, 0.5, from: 10.6)), [1, 1])
    }

    func testASecondTapOutsideTheDistanceWindowIsClickOne() {
        _ = tap(at: 0.2, 0.2, from: 10)
        // 600 points away across this display — far outside the 20-point reach.
        XCTAssertEqual(clickCounts(tap(at: 0.8, 0.8, from: 10.15)), [1, 1])
    }

    func testADrawnStrokeEndingNearAnEarlierTapDoesNotSeedADoubleTap() {
        _ = tap(at: 0.2, 0.2, from: 10)

        // A stroke that starts far away, travels, and happens to release right on
        // top of the earlier tap. It is a drag, not a tap.
        _ = planner.plan(message(.down, sample(0.8, 0.8, 0.5)), displaySize: displaySize, now: 10.1)
        _ = planner.plan(message(.move, sample(0.5, 0.5, 0.5)), displaySize: displaySize, now: 10.2)
        let drag = planner.plan(message(.up, sample(0.2, 0.2, 0)), displaySize: displaySize, now: 10.3)
        XCTAssertEqual(clickCounts(drag), [1])

        // Nothing to chain into: the tap the drag landed on was already consumed
        // by the drag's own down, and the drag itself seeds nothing.
        XCTAssertEqual(clickCounts(tap(at: 0.2, 0.2, from: 10.35)), [1, 1])
    }

    func testAContactHeldTooLongDoesNotSeedADoubleTap() {
        // Same place both times, but the first contact outlasts `tapMaxTime`.
        _ = tap(at: 0.5, 0.5, from: 10, lasting: 0.3)
        XCTAssertEqual(clickCounts(tap(at: 0.5, 0.5, from: 10.35)), [1, 1])
    }

    func testAnAbnormalCloseEndsTheDoubleTapSequence() {
        _ = tap(at: 0.5, 0.5, from: 10)
        // A cancelled stroke is not a tap, and it clears the pending sequence the
        // way the finger path's release guard does.
        _ = planner.plan(message(.down, sample(0.5, 0.5, 0.5)), displaySize: displaySize, now: 10.15)
        XCTAssertEqual(clickCounts(planner.plan(message(.cancel, sample(0.5, 0.5, 0)),
                                                displaySize: displaySize, now: 10.2)), [2])

        XCTAssertEqual(clickCounts(tap(at: 0.5, 0.5, from: 10.25)), [1, 1])
    }

    // MARK: - R11: proximity brackets a stroke exactly once

    func testDownMovesUpProduceOrderedStrokeWithOneProximityPair() {
        let steps = drawThreeSegmentStroke()

        // The order the requirement names: proximity enter, mouse down, three
        // drags, mouse up, proximity exit — plus the gesture cancel that opens
        // the stroke (R19) and the cursor park that precedes the press.
        XCTAssertEqual(gestureSteps(steps), [
            .cancelHostGesture,
            .proximityEnter,
            .moveCursor(sample(0.10, 0.10, 0.20)),
            .mouseDown(sample(0.10, 0.10, 0.20), clickCount: 1),
            .mouseDragged(sample(0.20, 0.20, 0.30)),
            .mouseDragged(sample(0.30, 0.30, 0.40)),
            .mouseDragged(sample(0.40, 0.40, 0.50)),
            .mouseUp(sample(0.50, 0.50, 0), clickCount: 1),
            .proximityExit
        ])

        let proximity = steps.filter { $0 == .proximityEnter || $0 == .proximityExit }
        XCTAssertEqual(proximity, [.proximityEnter, .proximityExit])
        XCTAssertFalse(planner.isStrokeOpen)
    }

    func testStrokeEndedByCancelStillProducesExactlyOneEnterExitPair() {
        var steps = planner.plan(message(.down, sample(0.1, 0.1)), displaySize: displaySize, now: 10)
        steps += planner.plan(message(.move, sample(0.2, 0.2)), displaySize: displaySize, now: 10.01)
        steps += planner.plan(message(.cancel, sample(0.3, 0.3)), displaySize: displaySize, now: 10.02)

        let proximity = steps.filter { $0 == .proximityEnter || $0 == .proximityExit }
        XCTAssertEqual(proximity, [.proximityEnter, .proximityExit])
        XCTAssertEqual(gestureSteps(steps).suffix(2), [.mouseUp(sample(0.3, 0.3, 0), clickCount: 1), .proximityExit])
        XCTAssertFalse(planner.isStrokeOpen)
    }

    func testMouseUpNeverAppearsWithoutAProximityExitBehindIt() {
        var steps = planner.plan(message(.down, sample(0.1, 0.1)), displaySize: displaySize, now: 1)
        steps += planner.plan(message(.up, sample(0.1, 0.1)), displaySize: displaySize, now: 1.01)

        let ups = steps.enumerated().filter { $0.element == .mouseUp(sample(0.1, 0.1, 0), clickCount: 1) }
        XCTAssertEqual(ups.count, 1)
        for (index, _) in ups {
            XCTAssertEqual(steps[index + 1], .proximityExit)
        }
    }

    // MARK: - R11, R16: every termination closes through the same path

    func testEveryTeardownReasonClosesAnOpenStrokeWithUpThenExit() {
        let reasons: [StylusCloseReason] = [
            .clientDisconnected, .serverStopped, .touchDisabled, .appQuit, .newClientConnected
        ]
        for reason in reasons {
            let fresh = StylusPlanner()
            _ = fresh.plan(StylusMessage(action: .down, samples: [sample(0.4, 0.6, 0.9)]), displaySize: displaySize, now: 5)
            XCTAssertTrue(fresh.isStrokeOpen, "\(reason)")

            XCTAssertEqual(fresh.close(reason: reason),
                           [.mouseUp(sample(0.4, 0.6, 0), clickCount: 1), .proximityExit],
                           "\(reason)")
            XCTAssertFalse(fresh.isStrokeOpen, "\(reason)")
        }
    }

    func testCloseUsesTheLastSampleSeenNotTheStrokeOrigin() {
        _ = planner.plan(message(.down, sample(0.1, 0.1, 0.3)), displaySize: displaySize, now: 2)
        _ = planner.plan(message(.move, sample(0.7, 0.8, 0.6)), displaySize: displaySize, now: 2.01)

        XCTAssertEqual(planner.close(reason: .clientDisconnected),
                       [.mouseUp(sample(0.7, 0.8, 0), clickCount: 1), .proximityExit])
    }

    // MARK: - AE6: closing a closed stroke is a no-op

    func testClosingAnAlreadyClosedStrokeReturnsNoSteps() {
        _ = planner.plan(message(.down, sample(0.2, 0.2)), displaySize: displaySize, now: 3)
        _ = planner.plan(message(.up, sample(0.2, 0.2)), displaySize: displaySize, now: 3.01)

        XCTAssertEqual(planner.close(reason: .clientDisconnected), [])
        XCTAssertEqual(planner.close(reason: .appQuit), [])
    }

    func testClosingBeforeAnyStrokeReturnsNoSteps() {
        XCTAssertEqual(planner.close(reason: .serverStopped), [])
    }

    func testTeardownAfterCancelDoesNotDoubleUp() {
        _ = planner.plan(message(.down, sample(0.2, 0.2)), displaySize: displaySize, now: 4)
        _ = planner.plan(message(.cancel, sample(0.2, 0.2)), displaySize: displaySize, now: 4.01)

        XCTAssertEqual(planner.close(reason: .touchDisabled), [])
    }

    // MARK: - R20: no implicit down

    func testMoveWithNoOpenStrokeReturnsNoStepsAndOpensNothing() {
        XCTAssertEqual(planner.plan(message(.move, sample(0.5, 0.5)), displaySize: displaySize, now: 7), [])
        XCTAssertFalse(planner.isStrokeOpen)

        // Still nothing after the fact: the move must not have latched state
        // that a later up could complete.
        XCTAssertEqual(planner.plan(message(.up, sample(0.6, 0.6)), displaySize: displaySize, now: 7.01), [])
        XCTAssertEqual(planner.close(reason: .clientDisconnected), [])
    }

    func testUpWithNoOpenStrokeReturnsNoSteps() {
        XCTAssertEqual(planner.plan(message(.up, sample(0.5, 0.5)), displaySize: displaySize, now: 8), [])
        XCTAssertFalse(planner.isStrokeOpen)
    }

    func testCancelWithNoOpenStrokeReturnsNoSteps() {
        XCTAssertEqual(planner.plan(message(.cancel, sample(0.5, 0.5)), displaySize: displaySize, now: 9), [])
    }

    func testMoveAfterStrokeEndedReturnsNoSteps() {
        _ = drawThreeSegmentStroke()
        XCTAssertEqual(planner.plan(message(.move, sample(0.9, 0.9)), displaySize: displaySize, now: 200), [])
    }

    // MARK: - R3: a finger during a stroke is suppressed

    func testFingerEventDuringOpenStrokeSuppressesAndProducesNoGestureSteps() {
        _ = planner.plan(message(.down, sample(0.3, 0.3)), displaySize: displaySize, now: 11)

        XCTAssertEqual(planner.planFingerEvent(), [.suppressFinger])
        // The stroke is untouched by the finger — no up, no exit, still open.
        XCTAssertTrue(planner.isStrokeOpen)
        XCTAssertEqual(planner.plan(message(.move, sample(0.35, 0.35)), displaySize: displaySize, now: 11.01).first,
                       .mouseDragged(sample(0.35, 0.35)))
    }

    func testFingerEventWithNoOpenStrokeIsNotSuppressed() {
        XCTAssertEqual(planner.planFingerEvent(), [])
        _ = drawThreeSegmentStroke()
        XCTAssertEqual(planner.planFingerEvent(), [])
    }

    // MARK: - R22: the host closes on its own timer

    func testStrokeWithNoSampleFor500msClosesOnTheTimerAlone() {
        _ = planner.plan(message(.down, sample(0.4, 0.4, 0.7)), displaySize: displaySize, now: 50)

        // No inbound event of any kind between the down and the timer firing.
        XCTAssertEqual(planner.staleTimeoutFired(now: 50.5),
                       [.mouseUp(sample(0.4, 0.4, 0), clickCount: 1), .proximityExit])
        XCTAssertFalse(planner.isStrokeOpen)
    }

    func testTimerIsArmedOnEverySampleSoALiveStrokeSurvivesAnEarlyFire() throws {
        var steps = planner.plan(message(.down, sample(0.1, 0.1)), displaySize: displaySize, now: 60)
        XCTAssertEqual(armInterval(steps.last), StylusPlanner.staleTimeout)

        steps = planner.plan(message(.move, sample(0.2, 0.2)), displaySize: displaySize, now: 60.4)
        XCTAssertEqual(armInterval(steps.last), StylusPlanner.staleTimeout)

        // A fire left over from the down's arming lands 0.1s into the move's
        // window: it must re-arm for the remainder, not end a live stroke.
        let early = planner.staleTimeoutFired(now: 60.5)
        XCTAssertEqual(early.count, 1)
        XCTAssertEqual(try XCTUnwrap(armInterval(early.first)), 0.4, accuracy: 1e-9)
        XCTAssertTrue(planner.isStrokeOpen)

        XCTAssertEqual(planner.staleTimeoutFired(now: 60.9),
                       [.mouseUp(sample(0.2, 0.2, 0), clickCount: 1), .proximityExit])
    }

    func testStaleTimerWithNoOpenStrokeReturnsNoSteps() {
        XCTAssertEqual(planner.staleTimeoutFired(now: 70), [])
        _ = drawThreeSegmentStroke(startingAt: 70)
        XCTAssertEqual(planner.staleTimeoutFired(now: 999), [])
    }

    // MARK: - R19: a stylus down abandons a pending finger gesture

    func testStylusDownCancelsAPendingHostGestureBeforePressing() {
        // The host may be holding a long-press-ready finger. The planner cannot
        // complete that gesture — its vocabulary has no click or right click —
        // and it orders the cancel ahead of everything the stroke does.
        let steps = planner.plan(message(.down, sample(0.5, 0.5, 0.4)), displaySize: displaySize, now: 80)

        XCTAssertEqual(steps.first, .cancelHostGesture)
        XCTAssertEqual(steps.filter { $0 == .cancelHostGesture }.count, 1)
        XCTAssertEqual(gestureSteps(steps), [
            .cancelHostGesture,
            .proximityEnter,
            .moveCursor(sample(0.5, 0.5, 0.4)),
            .mouseDown(sample(0.5, 0.5, 0.4), clickCount: 1)
        ])
    }

    // MARK: - No state leaks between strokes

    func testTwoConsecutiveStrokesProduceIdenticalStepSequences() {
        let first = drawThreeSegmentStroke(startingAt: 100)
        let second = drawThreeSegmentStroke(startingAt: 200)

        XCTAssertEqual(first, second)
        XCTAssertFalse(planner.isStrokeOpen)
    }

    func testADownWithNoInterveningUpClosesThePreviousStrokeFirst() {
        _ = planner.plan(message(.down, sample(0.1, 0.1)), displaySize: displaySize, now: 300)
        let steps = planner.plan(message(.down, sample(0.9, 0.9, 0.6)), displaySize: displaySize, now: 300.01)

        XCTAssertEqual(gestureSteps(steps), [
            .mouseUp(sample(0.1, 0.1, 0), clickCount: 1),
            .proximityExit,
            .cancelHostGesture,
            .proximityEnter,
            .moveCursor(sample(0.9, 0.9, 0.6)),
            .mouseDown(sample(0.9, 0.9, 0.6), clickCount: 1)
        ])
        let proximity = steps.filter { $0 == .proximityEnter || $0 == .proximityExit }
        XCTAssertEqual(proximity, [.proximityExit, .proximityEnter])
    }

    // MARK: - Batched samples (R6/R7 fidelity reaches the injector intact)

    func testEverySampleInABatchedMoveBecomesADragInOrder() {
        _ = planner.plan(message(.down, sample(0, 0)), displaySize: displaySize, now: 400)
        let steps = planner.plan(
            message(.move, sample(0.1, 0.1, 0.1), sample(0.2, 0.2, 0.2), sample(0.3, 0.3, 0.3)),
            displaySize: displaySize,
            now: 400.01
        )

        XCTAssertEqual(gestureSteps(steps), [
            .mouseDragged(sample(0.1, 0.1, 0.1)),
            .mouseDragged(sample(0.2, 0.2, 0.2)),
            .mouseDragged(sample(0.3, 0.3, 0.3))
        ])
    }

    func testABatchedDownDragsTheHistoryBehindTheFirstSample() {
        let steps = planner.plan(
            message(.down, sample(0.1, 0.1, 0.1), sample(0.2, 0.2, 0.2)),
            displaySize: displaySize,
            now: 500
        )

        XCTAssertEqual(gestureSteps(steps), [
            .cancelHostGesture,
            .proximityEnter,
            .moveCursor(sample(0.1, 0.1, 0.1)),
            .mouseDown(sample(0.1, 0.1, 0.1), clickCount: 1),
            .mouseDragged(sample(0.2, 0.2, 0.2))
        ])
    }

    // MARK: - Hover (follow-up plan U2)

    /// Every proximity step in order, so a test can state the balance requirement
    /// the way R11 does rather than by counting.
    private func proximitySteps(_ steps: [StylusStep]) -> [StylusStep] {
        steps.filter { $0 == .proximityEnter || $0 == .proximityExit }
    }

    private func buttonSteps(_ steps: [StylusStep]) -> [StylusStep] {
        steps.filter { step in
            switch step {
            case .mouseDown, .mouseUp, .mouseDragged: return true
            default: return false
            }
        }
    }

    /// Covers AE2, R1/KD1. Hovering moves the cursor and does nothing else — no
    /// press, no release, no drag, and no click state on anything it posts.
    func testHoverSamplesProduceCursorMovesAndZeroButtonEvents() {
        var steps = planner.plan(message(.hover, sample(0.1, 0.1, 0)), displaySize: displaySize, now: 10)
        steps += planner.plan(message(.hover, sample(0.2, 0.2, 0)), displaySize: displaySize, now: 10.01)
        steps += planner.plan(message(.hover, sample(0.3, 0.3, 0), sample(0.4, 0.4, 0)),
                              displaySize: displaySize, now: 10.02)

        XCTAssertEqual(gestureSteps(steps), [
            .proximityEnter,
            .moveCursor(sample(0.1, 0.1, 0)),
            .moveCursor(sample(0.2, 0.2, 0)),
            .moveCursor(sample(0.3, 0.3, 0)),
            .moveCursor(sample(0.4, 0.4, 0))
        ])
        XCTAssertEqual(buttonSteps(steps), [])
        XCTAssertFalse(planner.isStrokeOpen)
        XCTAssertTrue(planner.inProximity)
    }

    /// R1. Every hover sample arms the proximity timer, because that timer is the
    /// only thing that ends proximity — there is no exit on the wire. A fire that
    /// arrives while the pen is still hovering re-arms for the remainder instead
    /// of ending it.
    func testEveryHoverSampleArmsTheProximityTimer() {
        var steps = planner.plan(message(.hover, sample(0.5, 0.5, 0)), displaySize: displaySize, now: 20)
        steps += planner.plan(message(.hover, sample(0.6, 0.6, 0)), displaySize: displaySize, now: 20.5)
        XCTAssertEqual(steps.filter { armInterval($0) != nil }.count, 2)

        // Still hovering as far as the planner knows: 0.05s idle, window is 0.15s.
        let reArm = planner.staleTimeoutFired(now: 20.55)
        XCTAssertEqual(reArm.count, 1)
        XCTAssertEqual(armInterval(reArm[0]) ?? -1, 0.1, accuracy: 0.001)
        XCTAssertTrue(planner.inProximity)

        // Silence past the window is the exit.
        XCTAssertEqual(planner.staleTimeoutFired(now: 20.7), [.proximityExit])
        XCTAssertFalse(planner.inProximity)

        // And it is idempotent — nothing left to leave.
        XCTAssertEqual(planner.staleTimeoutFired(now: 30), [])
    }

    /// A hover move that arrives with no enter behind it enters anyway, so a
    /// dropped enter cannot leave the host tracking a pen it never admitted.
    func testHoverMoveWithoutAnEnterStillEntersProximityOnce() {
        var steps = planner.plan(message(.hover, sample(0.5, 0.5, 0)), displaySize: displaySize, now: 25)
        steps += planner.plan(message(.hover, sample(0.6, 0.6, 0)), displaySize: displaySize, now: 25.01)
        XCTAssertEqual(proximitySteps(steps), [.proximityEnter])
    }

    /// Covers R2/KTD6. The whole hover, draw, release, hover sequence is bracketed
    /// by exactly one proximity pair — the pen was in range the entire time.
    func testHoverDownUpHoverPostsExactlyOneProximityEnterAndOneExit() {
        var steps = planner.plan(message(.hover, sample(0.10, 0.10, 0)), displaySize: displaySize, now: 30)
        steps += planner.plan(message(.hover, sample(0.20, 0.20, 0)), displaySize: displaySize, now: 30.01)
        steps += planner.plan(message(.down, sample(0.20, 0.20, 0.4)), displaySize: displaySize, now: 30.02)
        steps += planner.plan(message(.move, sample(0.25, 0.25, 0.5)), displaySize: displaySize, now: 30.03)
        steps += planner.plan(message(.up, sample(0.30, 0.30, 0)), displaySize: displaySize, now: 30.04)
        steps += planner.plan(message(.hover, sample(0.40, 0.40, 0)), displaySize: displaySize, now: 30.05)
        XCTAssertTrue(planner.inProximity, "the pen never left range between the stroke and the hover after it")

        steps += planner.staleTimeoutFired(now: 30.36)

        XCTAssertEqual(proximitySteps(steps), [.proximityEnter, .proximityExit])
        XCTAssertEqual(gestureSteps(steps), [
            .proximityEnter,
            .moveCursor(sample(0.10, 0.10, 0)),
            .moveCursor(sample(0.20, 0.20, 0)),
            .cancelHostGesture,
            .moveCursor(sample(0.20, 0.20, 0.4)),
            .mouseDown(sample(0.20, 0.20, 0.4), clickCount: 1),
            .mouseDragged(sample(0.25, 0.25, 0.5)),
            .mouseUp(sample(0.30, 0.30, 0), clickCount: 1),
            .moveCursor(sample(0.40, 0.40, 0)),
            .proximityExit
        ])
        XCTAssertFalse(planner.isStrokeOpen)
        XCTAssertFalse(planner.inProximity)
    }

    /// Two strokes drawn without the pen leaving range still share one pair.
    func testTwoStrokesWithoutLeavingRangeShareOneProximityPair() {
        var steps = planner.plan(message(.hover, sample(0.1, 0.1, 0)), displaySize: displaySize, now: 40)
        steps += planner.plan(message(.down, sample(0.1, 0.1, 0.5)), displaySize: displaySize, now: 40.01)
        steps += planner.plan(message(.up, sample(0.1, 0.1, 0)), displaySize: displaySize, now: 40.02)
        steps += planner.plan(message(.hover, sample(0.5, 0.5, 0)), displaySize: displaySize, now: 40.5)
        steps += planner.plan(message(.down, sample(0.5, 0.5, 0.5)), displaySize: displaySize, now: 40.51)
        steps += planner.plan(message(.up, sample(0.5, 0.5, 0)), displaySize: displaySize, now: 40.52)
        steps += planner.staleTimeoutFired(now: 41.3)

        XCTAssertEqual(proximitySteps(steps), [.proximityEnter, .proximityExit])
    }

    /// R16. A disconnect while merely hovering still posts the exit, and leaves no
    /// button held because none was ever pressed.
    func testDisconnectWhileHoveringPostsTheProximityExitAndHoldsNoButton() {
        _ = planner.plan(message(.hover, sample(0.3, 0.3, 0)), displaySize: displaySize, now: 50)
        _ = planner.plan(message(.hover, sample(0.4, 0.4, 0)), displaySize: displaySize, now: 50.01)

        XCTAssertEqual(planner.close(reason: .clientDisconnected), [.proximityExit])
        XCTAssertFalse(planner.inProximity)
        XCTAssertEqual(planner.close(reason: .clientDisconnected), [])
    }

    /// R16. A disconnect mid-stroke on a hovering pen still releases the button and
    /// then leaves proximity — hover ownership never suppresses a teardown exit.
    func testDisconnectMidStrokeStartedFromHoverStillReleasesAndExits() {
        _ = planner.plan(message(.hover, sample(0.3, 0.3, 0)), displaySize: displaySize, now: 60)
        _ = planner.plan(message(.down, sample(0.3, 0.3, 0.6)), displaySize: displaySize, now: 60.01)

        XCTAssertEqual(planner.close(reason: .clientDisconnected),
                       [.mouseUp(sample(0.3, 0.3, 0), clickCount: 1), .proximityExit])
        XCTAssertFalse(planner.inProximity)
    }

    /// A cancel takes the pen back to idle, per the plan's state machine — and the
    /// hover that follows re-enters cleanly rather than being swallowed.
    func testCancelFromAHoveredStrokeExitsProximityAndTheNextHoverReenters() {
        var steps = planner.plan(message(.hover, sample(0.2, 0.2, 0)), displaySize: displaySize, now: 70)
        steps += planner.plan(message(.down, sample(0.2, 0.2, 0.5)), displaySize: displaySize, now: 70.01)
        steps += planner.plan(message(.cancel, sample(0.2, 0.2, 0)), displaySize: displaySize, now: 70.02)
        XCTAssertEqual(proximitySteps(steps), [.proximityEnter, .proximityExit])
        XCTAssertFalse(planner.inProximity)

        steps += planner.plan(message(.hover, sample(0.9, 0.9, 0)), displaySize: displaySize, now: 70.03)
        steps += planner.staleTimeoutFired(now: 70.34)
        XCTAssertEqual(proximitySteps(steps),
                       [.proximityEnter, .proximityExit, .proximityEnter, .proximityExit])
    }

    /// A stroke outranks proximity in the one timer both share: while a stroke is
    /// open the fire is judged against the stroke's 0.5s bound, not the 0.15s
    /// proximity window, so a pen resting on the glass is never torn down early.
    func testAnOpenStrokeOutranksTheProximityWindowInTheSharedTimer() {
        _ = planner.plan(message(.hover, sample(0.2, 0.2, 0)), displaySize: displaySize, now: 80)
        _ = planner.plan(message(.down, sample(0.2, 0.2, 0.5)), displaySize: displaySize, now: 80.01)

        // Past the proximity window but well inside the stroke bound: re-arm, not close.
        let reArm = planner.staleTimeoutFired(now: 80.32)
        XCTAssertEqual(reArm.count, 1)
        XCTAssertEqual(armInterval(reArm[0]) ?? -1, 0.19, accuracy: 0.001)
        XCTAssertTrue(planner.isStrokeOpen)

        // Past the stroke bound: the one close path releases the button and proximity.
        XCTAssertEqual(planner.staleTimeoutFired(now: 80.6),
                       [.mouseUp(sample(0.2, 0.2, 0), clickCount: 1), .proximityExit])
        XCTAssertFalse(planner.isStrokeOpen)
        XCTAssertFalse(planner.inProximity)
    }

    /// A hover sample arriving while the nib is down is the tail of a transition
    /// the client already resolved; chasing it would drag the cursor out from
    /// under an open stroke.
    func testHoverSampleDuringAnOpenStrokeIsIgnored() {
        _ = planner.plan(message(.down, sample(0.2, 0.2, 0.5)), displaySize: displaySize, now: 90)
        XCTAssertEqual(planner.plan(message(.hover, sample(0.9, 0.9, 0)), displaySize: displaySize, now: 90.01),
                       [])
        XCTAssertTrue(planner.isStrokeOpen)
    }

    /// A hover exit with nothing open is a no-op, not an unbalanced exit.
    func testHoverExitWithNothingOpenReturnsNoSteps() {
        XCTAssertEqual(planner.staleTimeoutFired(now: 95.3), [])
        XCTAssertEqual(planner.staleTimeoutFired(now: 96.3), [])
    }

    /// KTD6. With hover absent — the client has it off, or is an older build —
    /// proximity stays stroke-scoped and every step of the core plan's lifecycle
    /// is byte-identical to what it was before hover existed.
    func testWithNoHoverSamplesProximityStaysStrokeScoped() {
        let steps = drawThreeSegmentStroke()
        XCTAssertEqual(gestureSteps(steps), [
            .cancelHostGesture,
            .proximityEnter,
            .moveCursor(sample(0.10, 0.10, 0.20)),
            .mouseDown(sample(0.10, 0.10, 0.20), clickCount: 1),
            .mouseDragged(sample(0.20, 0.20, 0.30)),
            .mouseDragged(sample(0.30, 0.30, 0.40)),
            .mouseDragged(sample(0.40, 0.40, 0.50)),
            .mouseUp(sample(0.50, 0.50, 0), clickCount: 1),
            .proximityExit
        ])
        XCTAssertFalse(planner.inProximity)

        // And a second stroke repeats it exactly: nothing hover-shaped latched.
        XCTAssertEqual(gestureSteps(drawThreeSegmentStroke(startingAt: 200)), gestureSteps(steps))
    }

    /// R9 is a client-side rule. The host's own finger guard stays stroke-scoped
    /// on purpose: the pen hovers continuously while it is held, so suppressing
    /// finger input for the whole of proximity here would turn one lost hover exit
    /// into a dead touchscreen with nothing left to revive it.
    func testHoveringAloneDoesNotSuppressFingerEventsOnTheHost() {
        _ = planner.plan(message(.hover, sample(0.5, 0.5, 0)), displaySize: displaySize, now: 100)
        XCTAssertEqual(planner.planFingerEvent(), [])

        _ = planner.plan(message(.down, sample(0.5, 0.5, 0.5)), displaySize: displaySize, now: 100.01)
        XCTAssertEqual(planner.planFingerEvent(), [.suppressFinger])
    }

    /// The host's finger suppression is stroke-scoped, so a merely hovering pen is
    /// not covered by it. While a finger gesture holds the left button down —
    /// `.dragging` or `.penDrawing` — a hover sample must not teleport the cursor
    /// out from under that button.
    func testHoverDoesNotMoveTheCursorWhileAFingerHoldsTheButtonDown() {
        var steps = planner.plan(message(.hover, sample(0.1, 0.1, 0)),
                                 displaySize: displaySize, fingerButtonHeld: true, now: 120)
        steps += planner.plan(message(.hover, sample(0.2, 0.2, 0), sample(0.3, 0.3, 0)),
                              displaySize: displaySize, fingerButtonHeld: true, now: 120.01)

        // Proximity is still reported: the pen really is in range, and a host-side
        // proximity suppression is exactly the dead-touchscreen failure to avoid.
        XCTAssertEqual(gestureSteps(steps), [.proximityEnter])
        XCTAssertTrue(planner.inProximity)
        // And the finger gesture is left entirely alone.
        XCTAssertFalse(steps.contains(.cancelHostGesture))
        XCTAssertEqual(buttonSteps(steps), [])
    }

    /// The suppression lasts exactly as long as the held button does.
    func testHoverResumesMovingTheCursorWhenTheFingerLetsGo() {
        _ = planner.plan(message(.hover, sample(0.1, 0.1, 0)),
                         displaySize: displaySize, fingerButtonHeld: true, now: 130)
        let steps = planner.plan(message(.hover, sample(0.7, 0.7, 0)),
                                 displaySize: displaySize, fingerButtonHeld: false, now: 130.01)
        XCTAssertEqual(gestureSteps(steps), [.moveCursor(sample(0.7, 0.7, 0))])
    }

    /// A pen that comes down while the finger still holds the button takes the
    /// surface as usual: contact outranks the finger gesture and cancels it (R19).
    /// Only cursor *hover* defers.
    func testAStylusDownStillTakesOverFromAHeldFingerGesture() {
        _ = planner.plan(message(.hover, sample(0.4, 0.4, 0)),
                         displaySize: displaySize, fingerButtonHeld: true, now: 140)
        let steps = planner.plan(message(.down, sample(0.4, 0.4, 0.5)),
                                 displaySize: displaySize, fingerButtonHeld: true, now: 140.01)
        XCTAssertEqual(gestureSteps(steps), [
            .cancelHostGesture,
            .moveCursor(sample(0.4, 0.4, 0.5)),
            .mouseDown(sample(0.4, 0.4, 0.5), clickCount: 1)
        ])
    }

    /// Suppressed cursor moves do not cost the planner its idea of where the pen
    /// is: an exit while the finger is still down releases proximity at the last
    /// hovered point rather than a stale one.
    func testSuppressedHoverStillRecordsWhereThePenIs() {
        _ = planner.plan(message(.hover, sample(0.1, 0.1, 0)),
                         displaySize: displaySize, fingerButtonHeld: true, now: 150)
        _ = planner.plan(message(.hover, sample(0.8, 0.9, 0)),
                         displaySize: displaySize, fingerButtonHeld: true, now: 150.01)
        XCTAssertEqual(planner.staleTimeoutFired(now: 150.32),
                       [.proximityExit])
        XCTAssertFalse(planner.inProximity)
    }

    /// A double tap survives the hover samples between its two contacts: hover
    /// carries no click state and must not break the sequence.
    func testHoverBetweenTwoTapsDoesNotBreakTheDoubleTap() {
        _ = planner.plan(message(.hover, sample(0.5, 0.5, 0)), displaySize: displaySize, now: 110)
        XCTAssertEqual(clickCounts(tap(at: 0.5, 0.5, from: 110.01)), [1, 1])
        _ = planner.plan(message(.hover, sample(0.5, 0.5, 0)), displaySize: displaySize, now: 110.1)
        XCTAssertEqual(clickCounts(tap(at: 0.5, 0.5, from: 110.15)), [2, 2])
    }

    func testABatchedUpDragsEverySampleBeforeTheLastOne() {
        _ = planner.plan(message(.down, sample(0, 0)), displaySize: displaySize, now: 600)
        let steps = planner.plan(
            message(.up, sample(0.1, 0.1, 0.1), sample(0.2, 0.2, 0.2), sample(0.3, 0.3, 0)),
            displaySize: displaySize,
            now: 600.01
        )

        XCTAssertEqual(steps, [
            .mouseDragged(sample(0.1, 0.1, 0.1)),
            .mouseDragged(sample(0.2, 0.2, 0.2)),
            .mouseUp(sample(0.3, 0.3, 0), clickCount: 1),
            .proximityExit
        ])
    }
}
