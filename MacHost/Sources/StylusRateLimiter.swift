import Foundation

/// Sanity ceiling on injected stylus samples (R23).
///
/// The measured digitizer rate on the target device is ~600 Hz, so the ceiling
/// sits well above anything the hardware can produce: it exists to stop a
/// hostile or buggy client from driving unbounded input injection, not to shape
/// normal traffic. It is deliberately NOT a time cap — the finger path's
/// ~120 Hz interval cap would destroy the very geometry this feature exists to
/// preserve (R7), so the stylus path never consults it.
///
/// Whole messages are admitted or dropped together. A message is one batched
/// digitizer burst (~5 samples, 64 at most), and splitting a burst would leave
/// a stroke with a hole in the middle of a single event's history.
///
/// Not every action is droppable. A dropped `down` or `move` costs geometry; a
/// dropped `up` or `cancel` costs *state* — those are the messages that clear
/// something the host would otherwise hold. They have a second net under them
/// already (the 0.5 s stale timer closes a stroke whose up never landed), but a
/// net is not a reason to aim at it, so they are admitted unconditionally.
///
/// `hover` needs no such exemption, which is the point of deriving proximity
/// rather than latching it: there is no terminal hover message to lose. Dropping
/// a hover sample costs one cursor position; proximity still ends on its own
/// timer. They are also rare — a few per stroke against hundreds of samples — so
/// the terminal actions still count toward the
/// window without meaningfully weakening the ceiling.
///
/// Pure and stateless with respect to the socket: `StreamingServer` owns one
/// instance per connection and replaces it when a new client connects, which is
/// also what makes `shouldLogDrop` a once-per-connection signal.
struct StylusRateLimiter {
    /// Samples per second. ~3.3x the measured digitizer rate.
    static let maxSamplesPerSecond = 2000

    private var windowStart: TimeInterval?
    private var samplesInWindow = 0
    private var hasLoggedDrop = false

    /// True the first time a message is dropped, false forever after — the
    /// caller logs on that one edge. `debugLog` opens, seeks, writes and closes
    /// a file handle per call on the `.userInteractive` receive queue, so a
    /// per-message log here would turn a flood into a stall.
    private(set) var shouldLogDrop = false

    /// True for the actions that clear host state. Losing one of these strands
    /// that state; losing a `down`, `move` or `hover` costs a sample the next one
    /// supersedes. Hover has no terminal action at all — proximity ends on a
    /// timer, so there is nothing here that dropping it could strand.
    static func isTerminal(_ action: StylusAction) -> Bool {
        switch action {
        case .up, .cancel:
            return true
        case .down, .move, .hover:
            return false
        }
    }

    /// Returns true when the whole message may be injected.
    mutating func admit(action: StylusAction,
                        sampleCount: Int,
                        now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        let start = windowStart ?? now
        if now - start >= 1.0 {
            windowStart = now
            samplesInWindow = 0
        } else {
            windowStart = start
        }

        // Counted either way: an admitted terminal still consumes budget, it just
        // cannot be refused.
        guard !Self.isTerminal(action) else {
            samplesInWindow += sampleCount
            shouldLogDrop = false
            return true
        }

        guard samplesInWindow + sampleCount <= Self.maxSamplesPerSecond else {
            shouldLogDrop = !hasLoggedDrop
            hasLoggedDrop = true
            return false
        }

        samplesInWindow += sampleCount
        shouldLogDrop = false
        return true
    }
}
