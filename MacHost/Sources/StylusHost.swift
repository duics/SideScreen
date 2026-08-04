import CoreGraphics
import Foundation

/// Owns the host side of the stylus path: the planner, the injector, the
/// staleness timer, the display geometry a stroke is drawn in, and the
/// reentrancy latch that keeps a teardown from eating the stroke it is opening.
///
/// KTD5. This lives in its own file rather than in `AppDelegate` because the
/// branch merges from upstream `main`: every line added to an existing file is a
/// future conflict site. `AppDelegate` keeps only the hooks — the callback
/// wiring, one close line in `releaseHeldMouseButtonIfNeeded`, one in
/// `onClientConnected`, and the finger-suppression guard in `handleTouch`.
///
/// The two things it cannot own are passed in: the virtual display's frame, and
/// cancelling a pending finger gesture (which touches `AppDelegate`'s private
/// gesture machine).
final class StylusHost {
    /// Stroke state lives in the planner, not in `gestureState` (KTD9), so a
    /// finger lifting mid-stroke cannot half-clear it.
    private let planner = StylusPlanner()
    private let injector: StylusInjector
    /// The virtual display's frame right now, or nil when there is no display.
    private let displayBounds: () -> CGRect?
    /// KTD10/R19. The host has no neutral "abandon the gesture" operation — its
    /// one-finger-up path *completes* whatever is pending — so the owner supplies
    /// one that reaches its private members.
    private let cancelHostGesture: () -> Void
    /// True while the host holds the left button down for a finger gesture
    /// (`.dragging` or `.penDrawing`). Lives in `AppDelegate`'s private
    /// `gestureState`, so like the cancel it is passed in. Hover reads it to
    /// decline moving a cursor that a held button owns.
    private let fingerButtonHeld: () -> Bool

    private var staleTimer: DispatchWorkItem?
    /// The geometry the open stroke was started in, captured at the down. A
    /// stroke still open when the display is torn down has to be released
    /// *somewhere*, and the geometry it was drawn in is the only honest answer —
    /// the same reason the finger path releases at `touchLastPosition`. Capturing
    /// it at open is half of what keeps the close path from ever being
    /// geometry-starved; the other half is that geometry is resolved before the
    /// planner plans, so nothing is ever committed to in the planner that can then
    /// be discarded for want of a rectangle.
    private var strokeBounds: CGRect?
    /// True while a step list is being performed. `cancelHostGesture` repeats
    /// `penDown`'s prologue, which calls `releaseHeldMouseButtonIfNeeded`, which
    /// closes stylus strokes — without this latch a stylus down would tear down
    /// the very stroke its own step list is opening.
    private var performing = false

    /// `post` is the injector's, forwarded here for the same reason the injector
    /// takes one (and following `WirelessAuth`/`PairedDeviceStore`): a test needs
    /// to drive the whole host — plan, geometry resolution, perform — without
    /// injecting into the live session.
    init(eventSource: CGEventSource?,
         displayBounds: @escaping () -> CGRect?,
         cancelHostGesture: @escaping () -> Void,
         fingerButtonHeld: @escaping () -> Bool = { false },
         post: @escaping StylusInjector.PostOperation = { $0.post(tap: .cghidEventTap) }) {
        self.injector = StylusInjector(eventSource: eventSource, post: post)
        self.displayBounds = displayBounds
        self.cancelHostGesture = cancelHostGesture
        self.fingerButtonHeld = fingerButtonHeld
    }

    /// One decoded message, already on the main queue and already rate-limited by
    /// the server. The stylus path never consults `penModeEnabled` (R13) — the
    /// pen draws on contact.
    ///
    /// Geometry is resolved *before* the planner is asked to plan, and no bounds
    /// means the message is refused outright. Planning mutates the planner —
    /// proximity, stroke state, the last sample — so planning first and then
    /// discovering there is nowhere to post the steps would commit to a mouse up
    /// or a proximity exit and then throw it away, leaving state the planner will
    /// never emit again. Refusing early is lossless: the first message of a
    /// session cannot need geometry that a later one will not also have.
    func handle(_ message: StylusMessage) {
        guard let bounds = resolveBounds() else { return }
        perform(planner.plan(message,
                             displaySize: bounds.size,
                             fingerButtonHeld: fingerButtonHeld()),
                in: bounds)
    }

    /// R3/KTD4. True when a finger event arrived while the pen owns the surface
    /// and must be dropped. The client filters these, but the host cannot verify
    /// client behavior, so it drops them again here.
    func suppressesFingerEvent() -> Bool {
        !planner.planFingerEvent().isEmpty
    }

    /// The single close path (R16): mouse up *and* proximity exit, never one
    /// without the other. Closing an already-closed stroke produces nothing, and
    /// a close reached from inside a running step list is ignored — see
    /// `performing`.
    func close(_ reason: StylusCloseReason) {
        guard !performing else { return }
        staleTimer?.cancel()
        staleTimer = nil
        // Same order as `handle`: geometry first, so a close is never committed to
        // in the planner and then dropped. Nothing is lost by returning early —
        // `strokeBounds` is captured the moment a stroke or a hover opens, so a
        // planner with anything to close always has geometry to close it in.
        guard let bounds = resolveBounds() else { return }
        perform(planner.close(reason: reason), in: bounds)
    }

    /// The live display frame when there is one, remembered from the stroke's
    /// open when there is not.
    private func resolveBounds() -> CGRect? {
        displayBounds() ?? strokeBounds
    }

    /// Every stylus step list — messages, the staleness timer, and all the
    /// teardown paths — is performed here.
    private func perform(_ steps: [StylusStep], in bounds: CGRect) {
        guard !steps.isEmpty else { return }
        // Proximity as well as contact: a pen that is merely hovering when the
        // display goes away still owes the session a proximity exit, and the
        // geometry it was hovering over is the only honest place to post it.
        if planner.isStrokeOpen || planner.inProximity {
            strokeBounds = bounds
        }

        performing = true
        defer { performing = false }

        injector.perform(steps,
                         in: bounds,
                         cancelHostGesture: cancelHostGesture,
                         armStaleTimeout: { [weak self] delay in
                             self?.armStaleTimer(after: delay)
                         })
    }

    /// R22. Re-armed on every sample, so a stroke whose up is lost closes itself
    /// rather than holding the button down forever. A fire left over from an
    /// earlier arming re-arms instead of closing — the planner decides which,
    /// from the idle time.
    private func armStaleTimer(after delay: TimeInterval) {
        staleTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let bounds = self.resolveBounds() else { return }
            self.perform(self.planner.staleTimeoutFired(), in: bounds)
        }
        staleTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
