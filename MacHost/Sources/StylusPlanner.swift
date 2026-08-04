import CoreGraphics
import Foundation

/// One thing the host should do, in the order the planner returns it. The
/// planner decides these; `StylusInjector` performs them. Nothing here touches
/// `CGEvent`, `AppDelegate`, or the display — coordinates stay normalized
/// (0...1) exactly as they arrived on the wire.
enum StylusStep: Equatable {
    /// Close whatever the finger gesture machine has pending WITHOUT producing
    /// its completion event — no click, no right click, no momentum scroll
    /// (R19). The host has no other neutral way to abandon a gesture: its
    /// one-finger-up path *completes* whatever is pending.
    case cancelHostGesture
    /// Pen entered the tablet's active area. Emitted exactly once per visit to
    /// that area — once per stroke when the client sends no hover, once per hover
    /// session when it does.
    case proximityEnter
    /// Park the cursor on the contact point before pressing, so the app sees
    /// the press where the pen actually is (the touch path's `penDown` does the
    /// same).
    case moveCursor(StylusSample)
    /// R26. `clickCount` is the click number this press declares — 1 for a first
    /// tap, 2 for the second tap of a double click. A press with no click count
    /// is a half-formed click that ordinary Mac controls ignore.
    case mouseDown(StylusSample, clickCount: Int)
    case mouseDragged(StylusSample)
    /// R26. Carries the *same* count the matching `mouseDown` did. A release
    /// whose count disagrees with its press is the bug commit `76247b7` fixed on
    /// the finger pen path.
    case mouseUp(StylusSample, clickCount: Int)
    /// Pen left the active area. Paired with exactly one `proximityEnter`, always
    /// after the mouse up that ended any stroke still open when it happens.
    case proximityExit
    /// A finger arrived while the pen owns the surface — drop it (R3). The
    /// client already filters these; this is the host's defensive guard,
    /// because it cannot verify client behavior.
    case suppressFinger
    /// (Re)arm the host-side staleness timer, this many seconds from now (R22).
    case armStaleTimeout(after: TimeInterval)
}

/// Why a stroke is being closed. Every abnormal end routes through the same
/// close path so each one emits the mouse up *and* the proximity exit (R16) —
/// releasing the button while leaving proximity latched would leave an app
/// tracking the pen forever.
enum StylusCloseReason: Equatable {
    /// The pen lifted normally — the client sent an up.
    case penLifted
    /// The client sent `ACTION_CANCEL` (R4).
    case cancelled
    /// No sample for `staleTimeout` (R22).
    case stale
    case clientDisconnected
    case serverStopped
    case touchDisabled
    case appQuit
    /// The host's shared "release a held button" guard ran. One reason rather than
    /// five, because the guard is a single function reached from a second finger
    /// landing mid-stroke, a disconnect, a server stop, touch input being turned off,
    /// and app quit — its callers do not say which.
    case hostReleasedButton
    /// A new client connected before the previous one closed its stroke.
    case newClientConnected
}

/// Decides what a stylus message should produce, as a function of stroke state.
///
/// Stroke state lives here and NOT in `GestureState` (KTD9): `AppDelegate`
/// writes `gestureState = .idle` unconditionally in three places, so a finger
/// lifting mid-stroke would clear a stylus state through a path the existing
/// release guard never sees — leaving the left button down and proximity never
/// exited.
///
/// Pure in the sense that matters for testing: no event posting, no display
/// lookup, and time enters only through a defaulted parameter, following the
/// defaulted-dependency precedent in `WirelessAuth` and `PairedDeviceStore`.
/// It is not thread-safe; the host drives it from the main queue.
final class StylusPlanner {
    /// R22. A stroke with no sample for this long closes itself. The client
    /// runs the same bound and sends a cancel, but a client that went silent
    /// sends nothing at all — including no finger event — so the host's copy is
    /// a timer armed on every sample, never a check performed when some other
    /// event happens to arrive.
    static let staleTimeout: TimeInterval = 0.5

    /// R1. No hover sample for this long means the pen has left range. Measured on
    /// the target device, hover arrives every 8 ms at the median and 9 ms at the
    /// 90th percentile, so 150 ms cannot expire while the pen is genuinely there.
    /// Mirrors `StylusInput.PROXIMITY_WINDOW_MS` on the client.
    static let proximityWindow: TimeInterval = 0.15

    /// R26. The same bounds the finger pen path uses, in the units this class
    /// works in. `GestureThresholds` times with `DispatchTime`, so its values are
    /// nanoseconds; everything here is seconds.
    static let doubleTapMaxTime = TimeInterval(GestureThresholds.doubleTapMaxTime) / 1_000_000_000
    static let tapMaxTime = TimeInterval(GestureThresholds.tapMaxTime) / 1_000_000_000

    private(set) var isStrokeOpen = false
    /// A single flag whose transitions emit enter/exit. Balance is structural
    /// rather than a discipline the call sites have to keep (R11).
    private(set) var inProximity = false
    /// KTD6. Hover does not add a second proximity mechanism — it changes what
    /// causes `inProximity` to transition. This flag is that change and nothing
    /// more: true while hover boundaries own proximity, false while stroke
    /// boundaries do. A client that never sends hover leaves it false forever and
    /// gets the core plan's stroke-scoped lifecycle byte for byte.
    private var hoverOwnsProximity = false
    private var lastSample: StylusSample?
    private var lastSampleTime: TimeInterval = 0
    /// When the last hover sample arrived. Proximity is derived from this rather
    /// than latched — see `staleTimeoutFired`.
    private var lastHoverTime: TimeInterval = 0

    /// R26. Decided once, when the stroke opens, and carried to the release, so
    /// press and release always agree.
    private var clickCount = 1
    /// Where and when the open stroke started, so its close can tell a tap from a
    /// drawn stroke. The display size is captured with them: samples are
    /// normalized and `GestureThresholds` is in points, so the conversion has to
    /// use the geometry the stroke was actually drawn in.
    private var strokeStartSample: StylusSample?
    private var strokeStartTime: TimeInterval = 0
    private var strokeDisplaySize: CGSize = .zero
    /// End of the last contact that qualified as a tap, or 0 for "no sequence in
    /// progress". Position is normalized, in `strokeDisplaySize`'s geometry.
    private var lastTapTime: TimeInterval = 0
    private var lastTapSample: StylusSample?

    /// Steps for one decoded stylus message.
    ///
    /// `displaySize` is the virtual display's size in points. It is needed only
    /// to compare normalized sample distances against the point-based tap
    /// thresholds (R26); no coordinate leaves this class un-normalized.
    ///
    /// `fingerButtonHeld` is the host's answer to "is the left button physically
    /// down for a finger gesture right now" — `.dragging` or `.penDrawing`. Only
    /// hover reads it; see `planHover`. It defaults to false so the many call
    /// sites that are about contact, where it cannot apply, stay legible.
    func plan(_ message: StylusMessage,
              displaySize: CGSize,
              fingerButtonHeld: Bool = false,
              now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [StylusStep] {
        switch message.action {
        case .down:
            return planDown(message.samples, displaySize: displaySize, now: now)
        case .move:
            return planMove(message.samples, now: now)
        case .up:
            return planUp(message.samples, now: now)
        case .cancel:
            guard isStrokeOpen else { return [] }
            lastSample = message.samples.last ?? lastSample
            return closeSteps()
        case .hover:
            return planHover(message.samples, fingerButtonHeld: fingerButtonHeld, now: now)
        }
    }

    /// R1/KD1. Hover moves the cursor and does nothing else: no button, no click
    /// count, no gesture cancel. The step vocabulary makes that structural —
    /// `moveCursor` is the only thing emitted, and it is the same step the stroke
    /// path uses to park the cursor before pressing.
    ///
    /// Two things can be holding the cursor when a hover sample arrives, and both
    /// outrank it:
    /// - An open stylus stroke. The hover sample is the tail of a transition the
    ///   client already resolved; chasing it would drag the cursor out from under
    ///   the stroke.
    /// - A live finger gesture — the host's left button physically down for a
    ///   `.dragging` or `.penDrawing` contact. The host's finger suppression is
    ///   stroke-scoped, so it does not cover a merely hovering pen, and moving the
    ///   cursor under a held button teleports the drag. The gesture is *not*
    ///   cancelled and proximity is *not* suppressed: exiting proximity here would
    ///   turn one lost hover exit into a dead touchscreen, which is precisely the
    ///   failure this arbitration must not import. The pen is still in range, so
    ///   the host says so and simply declines to move the cursor until the finger
    ///   lets go.
    private func planHover(_ samples: [StylusSample],
                           fingerButtonHeld: Bool,
                           now: TimeInterval) -> [StylusStep] {
        guard !samples.isEmpty else { return [] }
        guard !isStrokeOpen else { return [] }

        hoverOwnsProximity = true
        lastHoverTime = now
        var steps: [StylusStep] = []
        if !inProximity {
            inProximity = true
            steps.append(.proximityEnter)
        }
        if !fingerButtonHeld {
            steps.append(contentsOf: samples.map { StylusStep.moveCursor($0) })
        }
        // Recorded either way: where the pen is is still the truth about where it
        // is, and a later close releases there.
        lastSample = samples.last
        // Proximity is bounded by the same timer a stroke uses. There is no hover
        // exit on the wire to lose, so this is the only thing that ends it.
        steps.append(.armStaleTimeout(after: Self.proximityWindow))
        return steps
    }

    /// A finger event that reached the host while the pen owns the surface.
    func planFingerEvent() -> [StylusStep] {
        isStrokeOpen ? [.suppressFinger] : []
    }

    /// The staleness timer fired. Returns the close steps only if the stroke
    /// really has gone quiet — the timer is re-armed on every sample, so a fire
    /// left over from an earlier arming must re-arm rather than end a live
    /// stroke.
    func staleTimeoutFired(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [StylusStep] {
        if isStrokeOpen {
            let idle = now - lastSampleTime
            guard idle >= Self.staleTimeout else {
                return [.armStaleTimeout(after: Self.staleTimeout - idle)]
            }
            return close(reason: .stale)
        }
        // R1. Proximity ends here and nowhere else. Nothing on the wire announces
        // the pen leaving, so a latch would need a message that can be dropped,
        // synthesized for the wrong tool, or lost to a backgrounded client. The
        // hover samples themselves are the heartbeat; silence is the exit.
        guard inProximity else { return [] }
        let idle = now - lastHoverTime
        guard idle >= Self.proximityWindow else {
            return [.armStaleTimeout(after: Self.proximityWindow - idle)]
        }
        inProximity = false
        hoverOwnsProximity = false
        return [.proximityExit]
    }

    /// The single close path. Disconnect, server stop, touch-off, quit, a new
    /// client connecting, a cancel, and the staleness timer all land here, so
    /// none of them can release the button without also leaving proximity.
    /// Closing an already-closed stroke returns no steps — no double up, no
    /// unbalanced exit.
    func close(reason: StylusCloseReason) -> [StylusStep] {
        closeSteps()
    }

    /// The close path itself. `reason` above exists to make teardown call sites
    /// legible; the steps are identical for every one of them by construction,
    /// which is the property R16 needs.
    ///
    /// `tapEndedAt` is the time the pen actually left the surface, and only a
    /// normal up supplies it. Every other close — cancel, staleness, teardown —
    /// passes nil and so ends the double-tap sequence outright, the same way the
    /// finger path's `releaseHeldMouseButtonIfNeeded` clears `lastTapTime`.
    /// `keepingProximity` is the whole of KTD6's change in behavior: when hover
    /// owns proximity, ending a stroke returns the pen to hovering rather than to
    /// idle, so the enter that hover posted stays live until hover exits. It is
    /// never passed by the teardown paths, so every abnormal end still exits.
    private func closeSteps(tapEndedAt: TimeInterval? = nil,
                            keepingProximity: Bool = false) -> [StylusStep] {
        var steps: [StylusStep] = []
        if isStrokeOpen {
            // Pressure zero: the stroke is ending, not pressing harder.
            let point = lastSample ?? StylusSample(x: 0, y: 0, pressure: 0)
            let release = StylusSample(x: point.x, y: point.y, pressure: 0)
            steps.append(.mouseUp(release, clickCount: clickCount))
            recordTapCandidate(endingAt: release, at: tapEndedAt)
        }
        if inProximity && !keepingProximity {
            steps.append(.proximityExit)
            inProximity = false
            hoverOwnsProximity = false
        }
        isStrokeOpen = false
        // The pen is still in range when proximity is kept, so where it last was
        // is still the truth about where it is.
        if !keepingProximity {
            lastSample = nil
        }
        lastSampleTime = 0
        clickCount = 1
        strokeStartSample = nil
        strokeStartTime = 0
        return steps
    }

    /// R26. Only a short, stationary contact can start or continue a double tap;
    /// a drawn stroke that happens to end near an earlier tap must not chain into
    /// one, and a click 2 does not seed a click 3.
    private func recordTapCandidate(endingAt end: StylusSample, at endTime: TimeInterval?) {
        guard let endTime,
              clickCount == 1,
              let start = strokeStartSample,
              endTime - strokeStartTime < Self.tapMaxTime,
              distance(end, start) < GestureThresholds.tapMaxDistance else {
            lastTapTime = 0
            lastTapSample = nil
            return
        }
        lastTapTime = endTime
        lastTapSample = end
    }

    /// Distance between two normalized samples, in the points of the display the
    /// open stroke is being drawn on.
    private func distance(_ lhs: StylusSample, _ rhs: StylusSample) -> CGFloat {
        hypot(CGFloat(lhs.x - rhs.x) * strokeDisplaySize.width,
              CGFloat(lhs.y - rhs.y) * strokeDisplaySize.height)
    }

    private func planDown(_ samples: [StylusSample],
                          displaySize: CGSize,
                          now: TimeInterval) -> [StylusStep] {
        // A previous stroke can still be open if its up never arrived; never
        // stack two downs without an up in between, and never open a second
        // proximity without exiting the first. Hovering is not a previous stroke:
        // the pen never left range, so its enter stays live and this down is the
        // Hovering -> Drawing edge.
        var steps = closeSteps(keepingProximity: hoverOwnsProximity)
        guard let first = samples.first else { return steps }

        // R26. A press declares its click count up front, exactly as `penDown`
        // does: a second tap that lands close enough to the first, soon enough
        // after it, is click 2 of a double click.
        strokeDisplaySize = displaySize
        let inWindow = now - lastTapTime < Self.doubleTapMaxTime
        let inReach = lastTapSample.map { distance(first, $0) < GestureThresholds.doubleTapMaxDistance } ?? false
        clickCount = (lastTapTime != 0 && inWindow && inReach) ? 2 : 1

        steps.append(.cancelHostGesture)
        // R2/KTD6. Already in proximity means hover put us there and the pen has
        // not left since; entering again would be the second half of an unbalanced
        // pair.
        if !inProximity {
            inProximity = true
            steps.append(.proximityEnter)
        }
        steps.append(.moveCursor(first))
        steps.append(.mouseDown(first, clickCount: clickCount))
        steps.append(contentsOf: samples.dropFirst().map { StylusStep.mouseDragged($0) })

        isStrokeOpen = true
        lastSample = samples.last
        lastSampleTime = now
        strokeStartSample = first
        strokeStartTime = now
        steps.append(.armStaleTimeout(after: Self.staleTimeout))
        return steps
    }

    private func planMove(_ samples: [StylusSample], now: TimeInterval) -> [StylusStep] {
        // A move with no open stroke is dropped and never treated as an
        // implicit down (R20) — the settings sink releases the button before it
        // clears `touchEnabled`, so a sample already in flight can land here.
        guard isStrokeOpen, !samples.isEmpty else { return [] }

        var steps = samples.map { StylusStep.mouseDragged($0) }
        lastSample = samples.last
        lastSampleTime = now
        steps.append(.armStaleTimeout(after: Self.staleTimeout))
        return steps
    }

    private func planUp(_ samples: [StylusSample], now: TimeInterval) -> [StylusStep] {
        guard isStrokeOpen else { return [] }

        // Everything before the final sample is still stroke geometry; only the
        // last one is where the pen left the surface.
        var steps = samples.dropLast().map { StylusStep.mouseDragged($0) }
        if let last = samples.last {
            lastSample = last
        }
        // A stroke that began from hovering returns to hovering, so the pen stays
        // in proximity between strokes exactly as it physically is.
        steps.append(contentsOf: closeSteps(tapEndedAt: now, keepingProximity: hoverOwnsProximity))
        return steps
    }
}
