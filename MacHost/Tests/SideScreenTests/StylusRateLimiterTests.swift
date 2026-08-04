import XCTest
@testable import SideScreen

final class StylusRateLimiterTests: XCTestCase {
    func testMeasuredDigitizerRatePassesUntouched() {
        var limiter = StylusRateLimiter()
        // ~600 Hz delivered as ~123 messages of ~5 samples, the measured shape.
        var now: TimeInterval = 1000
        for _ in 0..<123 {
            XCTAssertTrue(limiter.admit(action: .move, sampleCount: 5, now: now))
            now += 1.0 / 123.0
        }
    }

    func testSamplesBeyondTheCeilingAreDroppedWithinTheWindow() {
        var limiter = StylusRateLimiter()
        for _ in 0..<(StylusRateLimiter.maxSamplesPerSecond / 64) {
            XCTAssertTrue(limiter.admit(action: .move, sampleCount: 64, now: 10))
        }
        // 31 * 64 = 1984 admitted; the next full batch would cross 2000.
        XCTAssertFalse(limiter.admit(action: .move, sampleCount: 64, now: 10))
        // A batch that still fits is not collateral damage.
        XCTAssertTrue(limiter.admit(action: .move, sampleCount: 16, now: 10))
        XCTAssertFalse(limiter.admit(action: .move, sampleCount: 1, now: 10))
    }

    func testWindowResetsAfterOneSecond() {
        var limiter = StylusRateLimiter()
        XCTAssertTrue(limiter.admit(action: .move, sampleCount: 2000, now: 20))
        XCTAssertFalse(limiter.admit(action: .move, sampleCount: 1, now: 20.9))
        XCTAssertTrue(limiter.admit(action: .move, sampleCount: 2000, now: 21))
    }

    func testDropIsLoggedOncePerConnection() {
        var limiter = StylusRateLimiter()
        XCTAssertTrue(limiter.admit(action: .move, sampleCount: 2000, now: 30))
        XCTAssertFalse(limiter.shouldLogDrop)

        XCTAssertFalse(limiter.admit(action: .move, sampleCount: 64, now: 30.1))
        XCTAssertTrue(limiter.shouldLogDrop, "first drop asks for the one log line")

        XCTAssertFalse(limiter.admit(action: .move, sampleCount: 64, now: 30.2))
        XCTAssertFalse(limiter.shouldLogDrop, "per-message logging on the receive queue is the stall we avoid")

        // The server replaces the limiter per connection, so a later client
        // gets its own line.
        var next = StylusRateLimiter()
        XCTAssertTrue(next.admit(action: .move, sampleCount: 2000, now: 40))
        XCTAssertFalse(next.admit(action: .move, sampleCount: 1, now: 40.1))
        XCTAssertTrue(next.shouldLogDrop)
    }

    func testCeilingSitsWellAboveTheMeasuredDigitizerRate() {
        XCTAssertGreaterThan(StylusRateLimiter.maxSamplesPerSecond, 3 * 606)
    }

    /// The whole point of the terminal exemption. Hovering arms no stale timeout, so
    /// a dropped `up` strands the button down with nothing able to clear
    /// it — Mac apps go on seeing a pen that left minutes ago.
    func testHoverExitIsAdmittedWithTheWindowAlreadyExhausted() {
        var limiter = StylusRateLimiter()
        XCTAssertTrue(limiter.admit(action: .hover, sampleCount: 2000, now: 50))
        XCTAssertFalse(limiter.admit(action: .hover, sampleCount: 1, now: 50.1),
                       "an ordinary hover sample is droppable")

        XCTAssertTrue(limiter.admit(action: .up, sampleCount: 1, now: 50.2),
                      "a dropped exit strands proximity forever")
        XCTAssertFalse(limiter.shouldLogDrop)
    }

    /// `up` and `cancel` are bounded by the host's 0.5 s stale timer, but half a
    /// second of a button physically held down is still half a second of dragging
    /// across the Mac. They are as rare as the exit and exempt for the same reason.
    func testUpAndCancelAreAdmittedWithTheWindowAlreadyExhausted() {
        for terminal in [StylusAction.up, .cancel] {
            var limiter = StylusRateLimiter()
            XCTAssertTrue(limiter.admit(action: .move, sampleCount: 2000, now: 60))
            XCTAssertFalse(limiter.admit(action: .move, sampleCount: 1, now: 60.1))
            XCTAssertTrue(limiter.admit(action: terminal, sampleCount: 1, now: 60.2),
                          "\(terminal) must never be dropped")
        }
    }

    /// Exempt from refusal, not from accounting: an admitted terminal still spends
    /// window budget, so it cannot be used as a hole in the ceiling.
    func testTerminalsStillCountTowardTheWindow() {
        var limiter = StylusRateLimiter()
        XCTAssertTrue(limiter.admit(action: .up, sampleCount: 1999, now: 70))
        XCTAssertTrue(limiter.admit(action: .move, sampleCount: 1, now: 70.1))
        XCTAssertFalse(limiter.admit(action: .move, sampleCount: 1, now: 70.2),
                       "the terminal's samples were counted")
    }

    /// Only the state-clearing actions are exempt; the sample-carrying ones are all
    /// still droppable, which is what keeps the ceiling meaningful.
    func testOnlyStateClearingActionsAreTerminal() {
        XCTAssertTrue(StylusRateLimiter.isTerminal(.up))
        XCTAssertTrue(StylusRateLimiter.isTerminal(.cancel))
        XCTAssertFalse(StylusRateLimiter.isTerminal(.hover))
        XCTAssertFalse(StylusRateLimiter.isTerminal(.down))
        XCTAssertFalse(StylusRateLimiter.isTerminal(.move))
        XCTAssertFalse(StylusRateLimiter.isTerminal(.hover))
    }
}
