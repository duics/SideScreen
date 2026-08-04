package com.sidescreen.app

/**
 * Decision core for the stylus input path (client side).
 *
 * This class never sees a `MotionEvent`. The adapter in `MainActivity.handleTouch`
 * extracts tool type, pointer ids, coordinates, pressure and the historical
 * samples into the plain data classes below, and this core decides what to send
 * and whether the existing touch path should still run. Two reasons for the split:
 * `MotionEvent.obtain(...)` throws "not mocked" under this Gradle setup (JUnit
 * only, no Robolectric), so a core that took framework types could not be tested
 * at all; and the repo's tested units — `AuthHandshake`, `StylusWire` — are
 * exactly the ones with no framework entanglement.
 *
 * Rules it implements:
 * - R3/R25: a finger that is down while a stylus stroke is open never reaches the
 *   host. Because its down was never forwarded, its later moves and its up must
 *   not be forwarded either — suppression outlives the stroke and ends when that
 *   pointer physically lifts.
 * - R5/R6: every sample is a measured one. Historical samples are forwarded in
 *   digitizer order ahead of the current sample, and the predictor is never
 *   consulted on this path.
 * - R8: batching stays on. Nothing here asks for unbuffered dispatch — that would
 *   suppress the very coalescing R6 harvests, turning ~123 messages per second
 *   carrying 4.8 samples each into ~600 single-sample ones for identical fidelity.
 * - R9/R12: pressure is clamped to 0..1 (the device reports up to 2.44), and a
 *   device with no pressure axis yields full scale, so a zero on the wire always
 *   means a real zero.
 * - R22: a stroke that goes 500 ms without a stylus sample closes itself with a
 *   cancel and releases suppression, so a lost stylus-up cannot wedge the client.
 *
 * Hover (follow-up plan U1) extends the same core rather than paralleling it:
 * - R1/R2: proximity is one flag. Hover enter and exit move it; a stylus down
 *   does not disturb it, so a stroke started from hover returns to hover.
 * - R9: a finger that lands while the pen is in proximity is suppressed by
 *   identity, exactly the way one landing mid-stroke already is. It is NOT a
 *   timer and NOT a blackout window — the pen hovers continuously while it is
 *   held, so anything interval-based here would disable finger touch invisibly
 *   and permanently. A finger that was already on the glass when the pen
 *   approached keeps reaching the existing path; only contacts that *arrive*
 *   during proximity are dropped, which is exactly what R9 asks for.
 * - R22, extended to proximity. Suppression by identity is only safe while
 *   proximity itself is bounded: a hover exit that never arrives would otherwise
 *   hold every finger inert with no event left that could release it. Proximity
 *   therefore expires after the same 500 ms of silence a stroke does. That is a
 *   bound on a *missing* exit, not a blackout window — a pen actually in range
 *   refreshes it several hundred times a second.
 */
class StylusInput {
    /**
     * Tool that produced a pointer.
     *
     * [ERASER] is a stylus for every routing decision — it draws, it suppresses
     * palms, it is not a finger — and differs only in being a bindable trigger.
     * Use [isStylus] rather than comparing to [STYLUS], or an eraser-reporting pen
     * silently routes to the finger path.
     */
    enum class Tool {
        STYLUS,
        ERASER,
        FINGER,
        ;

        val isStylus: Boolean
            get() = this == STYLUS || this == ERASER
    }

    /**
     * A physical signal the pen can produce, which the user binds to an action.
     *
     * Triggers are *discovered* rather than declared: the client reports the ones
     * it has actually seen this device emit, so hardware nobody has tested is
     * bindable without a device table. The Tab S9's pen, for instance, reports no
     * eraser tool on either end, so its only trigger is the barrel button.
     */
    enum class Trigger {
        BARREL_BUTTON,
        ERASER_TOOL,
    }

    /** What a bound trigger makes a contact mean. */
    enum class PenAction {
        SECONDARY_CLICK,
        ERASER,
        ;

        val flag: Int
            get() =
                when (this) {
                    SECONDARY_CLICK -> StylusWire.FLAG_SECONDARY
                    ERASER -> StylusWire.FLAG_ERASER
                }
    }

    /** The `actionMasked` values this path cares about. Anything else never reaches the core. */
    enum class Action {
        DOWN,
        POINTER_DOWN,
        MOVE,
        UP,
        POINTER_UP,
        CANCEL,
    }

    /**
     * The hover actions, which arrive on a different dispatch path entirely —
     * `View.dispatchHoverEvent` via `setOnHoverListener`, never the touch listener.
     */
    enum class HoverAction {
        ENTER,
        MOVE,
        EXIT,
    }

    /**
     * One pointer position, already normalized to 0..1 with display flips applied
     * by the adapter (see [normalize]). Pressure is the raw reported value —
     * clamping happens here so the clamp is testable.
     */
    data class Point(
        val x: Float,
        val y: Float,
        val pressure: Float,
    )

    /** A pointer in one event, with its coalesced history oldest-first. */
    data class Pointer(
        val id: Int,
        val tool: Tool,
        val point: Point,
        val history: List<Point> = emptyList(),
    )

    /**
     * One `MotionEvent` reduced to plain data.
     *
     * @param actionPointerId pointer id at `actionIndex` — the pointer this action is about.
     * @param canceled `FLAG_CANCELED`, which One UI sets when it retroactively rejects a contact.
     * @param hasPressureAxis false when the input device reports no pressure axis (R12).
     * @param eventTimeMs `MotionEvent.eventTime`, used only for the R22 staleness bound.
     */
    data class Frame(
        val action: Action,
        val actionPointerId: Int,
        val pointers: List<Pointer>,
        val canceled: Boolean = false,
        val hasPressureAxis: Boolean = true,
        val eventTimeMs: Long = 0L,
        /** `MotionEvent.BUTTON_STYLUS_PRIMARY` is set in `buttonState`. */
        val barrelButtonHeld: Boolean = false,
    )

    /**
     * One hover `MotionEvent` reduced to plain data. A hover event is always one
     * pointer with no coalesced history, so it needs none of [Frame]'s machinery.
     *
     * @param point normalized exactly as a stroke sample is; its pressure field is
     *   ignored, because a hovering pen is by definition not pressing (R12's real
     *   zero, not an absent value).
     * @param distance `AXIS_DISTANCE` when the device reports that axis, else null.
     *   Never forwarded — the wire's sample stride is fixed at x, y, pressure. It is
     *   read for one purpose: telling an exit caused by the nib reaching the glass
     *   (distance 0) from an exit caused by the pen leaving range (distance at the
     *   top of its ramp, ~102 on the measured device). See [processHover].
     * @param eventTimeMs `MotionEvent.eventTime`, used only for the proximity
     *   staleness bound in [process] — the hover twin of R22's stroke bound.
     */
    data class HoverFrame(
        val action: HoverAction,
        val tool: Tool,
        val point: Point,
        val distance: Float? = null,
        val eventTimeMs: Long = 0L,
        /**
         * `MotionEvent.BUTTON_STYLUS_PRIMARY` is set. Hovering with the button held
         * is how a user naturally presses it, so this is the main way the barrel
         * button gets *discovered* — the contact path only ever sees it if the
         * button happened to be held at touch-down.
         */
        val barrelButtonHeld: Boolean = false,
    )

    /** One stylus message to hand to `StreamClient.sendStylus`. */
    data class Send(
        val action: StylusWire.Action,
        val samples: List<StylusWire.Sample>,
        /** Resolved intent for this contact — see [StylusWire.FLAG_SECONDARY]. */
        val flags: Int = 0,
    )

    /**
     * @param handled true when the existing `handleTouch` body must not run for this event.
     * @param sends messages to send, in order, even when [handled] is false — a staleness
     *   cancel can accompany an event that the existing path still owns.
     */
    data class Decision(
        val handled: Boolean,
        val sends: List<Send> = emptyList(),
    )

    private var strokePointerId: Int? = null
    private val suppressed = mutableSetOf<Int>()
    private var lastStylusEventMs = 0L

    /**
     * When the last hover sample arrived. Proximity is derived from this, never
     * latched — see [isInProximity].
     */
    private var lastHoverMs: Long? = null
    private var lastSample = StylusWire.Sample(0f, 0f, 0f)
    private var hoverEnabled = true

    /**
     * Which trigger means what. Keyed by trigger, which is what makes the "a
     * button cannot be mapped twice" rule structural rather than a validation
     * step: a map cannot hold one key twice, so binding a trigger that is already
     * bound moves it instead of duplicating it.
     */
    private val bindings = mutableMapOf<Trigger, PenAction>()

    /**
     * Triggers this device has actually been seen to emit, so the settings UI can
     * offer what exists rather than what the spec sheet claims. The Tab S9's pen
     * reports no eraser tool at all, so [Trigger.ERASER_TOOL] never appears here
     * on that hardware however hard the user flips it.
     */
    private val observedTriggers = mutableSetOf<Trigger>()

    /**
     * Flags for the contact currently open, decided when it opened and carried to
     * its release — the same rule click count follows. A button pressed halfway
     * through a stroke must not turn that stroke into a right-drag under the
     * app's feet.
     */
    private var strokeFlags = 0

    /**
     * True while this path owns the *touch* stream — a stroke is open, or fingers
     * are still suppressed. Deliberately excludes proximity: a finger that was
     * already on the glass when the pen approached was forwarded to the existing
     * path, so its up has to reach that path too or the host is left mid-gesture.
     */
    private val ownsTouchStream: Boolean
        get() = strokePointerId != null || suppressed.isNotEmpty()

    /**
     * True while the adapter must consult this core for every touch event. Wider
     * than [ownsTouchStream] by proximity, because R9 needs to see a finger's
     * *down* in order to suppress it.
     */
    fun isActive(nowMs: Long): Boolean = ownsTouchStream || isInProximity(nowMs)

    /** True while a stylus stroke is open. */
    val isStrokeOpen: Boolean
        get() = strokePointerId != null

    /**
     * R1. True while the pen is within range, whether or not it is touching.
     *
     * Derived from when the last hover sample arrived, never latched. A pen in
     * range emits hover samples continuously — measured at a median of 8 ms and a
     * 90th percentile of 9 ms on the target device — so silence for
     * [PROXIMITY_WINDOW_MS] means it is gone.
     *
     * This is the whole reason proximity cannot get stuck. A latch needs a
     * terminating event to clear it, and that event can be lost in at least four
     * ways: Android synthesizes the exit from `ViewGroup.exitHoverTargets` with
     * `TOOL_TYPE_UNKNOWN` when the surface detaches, the app can leave the
     * foreground, the host's rate limiter can drop the message, and the process
     * can die. Every one of those is a stuck latch and a silently dead
     * touchscreen. A derived value has nothing to lose: the samples stop and it
     * expires on its own.
     */
    fun isInProximity(nowMs: Long): Boolean {
        val last = lastHoverMs ?: return false
        // Bounded at both ends. A sample stamped in the future is not evidence the
        // pen is here now, and an unbounded lower end would read a negative elapsed
        // time as "recent" — which is the same latch this design exists to avoid.
        val elapsed = nowMs - last
        return elapsed >= 0 && elapsed < PROXIMITY_WINDOW_MS
    }

    /** Triggers this device has been seen to emit. Empty until the pen produces one. */
    fun triggersSeen(): Set<Trigger> = observedTriggers.toSet()

    /** The trigger currently bound to [action], or null. */
    fun triggerFor(action: PenAction): Trigger? = bindings.entries.firstOrNull { it.value == action }?.key

    /**
     * Bind [trigger] to [action], moving it off whatever it was bound to before.
     * Also clears any other trigger already bound to [action], so the relationship
     * stays one to one in both directions and a user cannot end up with two ways
     * to right click and no way to erase.
     */
    fun bind(
        trigger: Trigger,
        action: PenAction,
    ) {
        bindings.entries.removeAll { it.value == action }
        bindings[trigger] = action
    }

    /** Unbind whatever is bound to [action]. */
    fun unbind(action: PenAction) {
        bindings.entries.removeAll { it.value == action }
    }

    /** Replace the whole mapping, for restoring persisted settings at startup. */
    fun restoreBindings(map: Map<Trigger, PenAction>) {
        bindings.clear()
        for ((trigger, action) in map) bind(trigger, action)
    }

    /** The current mapping, for persisting it. */
    fun currentBindings(): Map<Trigger, PenAction> = bindings.toMap()

    /**
     * The triggers active for this event, whether or not they are bound. The
     * settings UI listens through this: a press-to-bind row takes the first one
     * reported and binds it, so a signal nobody anticipated is still bindable.
     */
    fun activeTriggers(
        frame: Frame,
        actor: Pointer?,
    ): Set<Trigger> {
        val active = mutableSetOf<Trigger>()
        if (frame.barrelButtonHeld) active.add(Trigger.BARREL_BUTTON)
        if (actor?.tool == Tool.ERASER) active.add(Trigger.ERASER_TOOL)
        observedTriggers.addAll(active)
        return active
    }

    /** The wire flags the active triggers resolve to, per the current bindings. */
    private fun flagsFor(
        frame: Frame,
        actor: Pointer?,
    ): Int =
        activeTriggers(frame, actor).fold(0) { acc, trigger ->
            acc or (bindings[trigger]?.flag ?: 0)
        }

    /** R8. False while hover forwarding is turned off. */
    val isHoverEnabled: Boolean
        get() = hoverEnabled

    /** Drop all state without emitting anything. Used when the host cannot accept stylus messages. */
    fun reset() {
        strokePointerId = null
        suppressed.clear()
        lastStylusEventMs = 0L
        lastHoverMs = null
        strokeFlags = 0
    }

    /**
     * R8. Turn hover forwarding on or off.
     *
     * Nothing has to be sent when turning it off: the host derives proximity the
     * same way this does, so it expires there too once the samples stop.
     */
    fun setHoverEnabled(enabled: Boolean) {
        hoverEnabled = enabled
    }

    /**
     * One hover event. Returns [Decision.handled] true when the stylus path
     * consumed it, which is what the hover listener returns to the framework.
     *
     * Only two rules survive, because proximity is derived rather than latched:
     * - R3. Only a stylus hover counts. A finger or palm the digitizer reports as
     *   hovering goes back to the rest of the app.
     * - R2/R8. A sample is not forwarded while the nib is down, or while hover is
     *   off. A hover sample during a stroke is the tail of the transition, not a
     *   position the host should chase, and it must not overwrite the stroke's
     *   last sample — that is where a cancel would have to release.
     *
     * There is deliberately no exit handling and no enter/exit distinction on the
     * wire. An exit is only ever an optimization, and depending on one is what
     * made this fragile: Android synthesizes exits with `TOOL_TYPE_UNKNOWN` from
     * `ViewGroup.exitHoverTargets`, the app can be backgrounded, the host can rate-
     * limit the message away, and the process can die. Every sample is instead a
     * heartbeat, and both sides expire proximity when the heartbeats stop.
     */
    fun processHover(frame: HoverFrame): Decision {
        if (!frame.tool.isStylus) return Decision(handled = false)
        // An exit is consumed because it is ours, and otherwise ignored. Acting on
        // it would reintroduce the dependency this design removes, and it is wrong
        // even when it arrives: Android emits an exit as the nib reaches the glass,
        // so clearing there would drop finger suppression in the instant before the
        // pen touches down — exactly when the wrist is most likely already resting.
        if (frame.action == HoverAction.EXIT) return Decision(handled = true)
        if (strokePointerId != null) return Decision(handled = true)

        lastHoverMs = frame.eventTimeMs
        // R9 is not a hover feature and must not be switched off with one. The
        // preference governs whether hover is *forwarded* — whether the Mac cursor
        // follows the pen — and proximity is tracked either way, because palm
        // suppression before contact depends on it. A user who turns the cursor
        // off to stop it being distracting would otherwise silently lose the
        // wrist rejection that R8 promises drawing keeps.
        if (frame.barrelButtonHeld) observedTriggers.add(Trigger.BARREL_BUTTON)
        if (frame.tool == Tool.ERASER) observedTriggers.add(Trigger.ERASER_TOOL)
        if (!hoverEnabled) return Decision(handled = true)
        val at = hoverSample(frame.point.x, frame.point.y)
        // A hover sample is not a contact, so it reports the trigger state live
        // rather than a frozen one: that is how a hovering eraser announces its
        // pointer type to the host before it ever touches down.
        val hoverTriggers = mutableSetOf<Trigger>()
        if (frame.tool == Tool.ERASER) hoverTriggers.add(Trigger.ERASER_TOOL)
        observedTriggers.addAll(hoverTriggers)
        val flags = hoverTriggers.fold(0) { acc, t -> acc or (bindings[t]?.flag ?: 0) }
        return Decision(handled = true, sends = listOf(Send(StylusWire.Action.HOVER, listOf(at), flags)))
    }

    /** A hover position. Pressure is a real zero — the pen is not touching (R12). */
    private fun hoverSample(
        x: Float,
        y: Float,
    ): StylusWire.Sample {
        val sample = StylusWire.Sample(x, y, 0f)
        lastSample = sample
        return sample
    }

    fun process(frame: Frame): Decision {
        val sends = mutableListOf<Send>()

        // R22. The staleness bound outranks R25's suppression rule: a lost stylus-up
        // must not be able to hold every finger inert while the user waits. The cost
        // is that a palm still on the glass resumes reaching the existing touch path.
        if (strokePointerId != null && frame.eventTimeMs - lastStylusEventMs >= STALE_TIMEOUT_MS) {
            closeStroke(sends, StylusWire.Action.CANCEL, lastSample)
            suppressed.clear()
        }

        // Proximity needs no equivalent bound: [isInProximity] is derived from the
        // last hover sample, so it expires by itself and stops suppressing new
        // contacts with nothing to unstick. Pointers already suppressed keep R25's
        // rule — they release on their own lift, or on the ACTION_DOWN below, which
        // is the only moment the glass is known to be empty.

        // ACTION_DOWN is the first pointer of a fresh gesture, so nothing from the
        // previous one is still on the glass. Anything left here is stale bookkeeping.
        if (frame.action == Action.DOWN) {
            closeStroke(sends, StylusWire.Action.CANCEL, lastSample)
            suppressed.clear()
        }

        val actor = frame.pointers.firstOrNull { it.id == frame.actionPointerId }

        return when (frame.action) {
            Action.DOWN, Action.POINTER_DOWN -> onDown(frame, actor, sends)
            Action.MOVE -> onMove(frame, sends)
            Action.UP, Action.POINTER_UP -> onUp(frame, actor, sends)
            Action.CANCEL -> onCancel(frame, sends)
        }
    }

    private fun onDown(
        frame: Frame,
        actor: Pointer?,
        sends: MutableList<Send>,
    ): Decision {
        if (actor != null && actor.tool.isStylus) {
            if (strokePointerId != actor.id) {
                closeStroke(sends, StylusWire.Action.CANCEL, lastSample)
            }
            strokePointerId = actor.id
            // Decided once, here. A button pressed halfway through a stroke must
            // not turn it into a right-drag under the app's feet.
            strokeFlags = flagsFor(frame, actor)
            lastStylusEventMs = frame.eventTimeMs
            // A pen on the glass is a pen in range: contact keeps the proximity bound
            // fresh, so the hover silence a stroke necessarily causes cannot expire it.
            lastHoverMs = frame.eventTimeMs
            // AE2. A palm already on the glass does not make this a two-pointer gesture.
            suppressFingers(frame)
            // A down carries no history; the current sample is the whole message.
            emit(sends, StylusWire.Action.DOWN, listOf(sampleOf(actor.point, frame)))
            return Decision(handled = true, sends = sends)
        }
        // R9. Proximity is enough on its own: the wrist lands while the pen is still
        // approaching, so suppression keyed on contact is always too late — the
        // measured sequence has the wrist land, get cancelled by One UI 75 ms later,
        // and the pen arrive 339 ms after that, by which time the wrist's gesture has
        // already completed on the Mac.
        if (isActive(frame.eventTimeMs)) {
            // AE1. Its down is never forwarded, so neither is anything else it produces.
            if (actor != null) suppressed.add(actor.id)
            return Decision(handled = true, sends = sends)
        }
        return Decision(handled = false, sends = sends)
    }

    private fun onMove(
        frame: Frame,
        sends: MutableList<Send>,
    ): Decision {
        val strokeId = strokePointerId
        if (strokeId == null) {
            // No open stroke. A stylus move is swallowed rather than sent (R20 has the
            // host drop it anyway) and, crucially, never handed to the gesture path:
            // under KD2 the pen is not a gesture pointer. Suppressed fingers keep
            // producing moves the host must never see either.
            val hasStylus = frame.pointers.any { it.tool.isStylus }
            return Decision(handled = hasStylus || suppressed.isNotEmpty(), sends = sends)
        }
        val stylus = frame.pointers.firstOrNull { it.id == strokeId }
        if (stylus == null) {
            // The stroke pointer disappeared without an up. Close it rather than leave it open.
            closeStroke(sends, StylusWire.Action.CANCEL, lastSample)
            return Decision(handled = true, sends = sends)
        }
        lastStylusEventMs = frame.eventTimeMs
        lastHoverMs = frame.eventTimeMs
        suppressFingers(frame)
        // R6. History first, oldest to newest, then the current sample.
        emit(sends, StylusWire.Action.MOVE, samplesOf(stylus, frame))
        return Decision(handled = true, sends = sends)
    }

    private fun onUp(
        frame: Frame,
        actor: Pointer?,
        sends: MutableList<Send>,
    ): Decision {
        val strokeId = strokePointerId
        if (strokeId != null && frame.actionPointerId == strokeId) {
            lastHoverMs = frame.eventTimeMs
            val samples = if (actor != null) samplesOf(actor, frame) else listOf(lastSample)
            // R4. A cancelled pointer ends the stroke as a cancel, not as a plain up.
            val action = if (frame.canceled) StylusWire.Action.CANCEL else StylusWire.Action.UP
            emit(sends, action, samples)
            strokePointerId = null
            // R25. Fingers stay suppressed past the stroke, until each one lifts.
            if (frame.action == Action.UP) suppressed.clear()
            return Decision(handled = true, sends = sends)
        }
        val wasSuppressed = suppressed.remove(frame.actionPointerId)
        // A stylus lifting with no matching stroke is swallowed, not passed to the
        // gesture path — the pen is never a gesture pointer once the host can take it.
        val handled = wasSuppressed || ownsTouchStream || actor?.tool?.isStylus == true
        // ACTION_UP is the last pointer leaving the glass; nothing can still be suppressed.
        if (frame.action == Action.UP) suppressed.clear()
        return Decision(handled = handled, sends = sends)
    }

    private fun onCancel(
        frame: Frame,
        sends: MutableList<Send>,
    ): Decision {
        val handled = ownsTouchStream
        val strokeId = strokePointerId
        val stylus = if (strokeId != null) frame.pointers.firstOrNull { it.id == strokeId } else null
        val sample = if (stylus != null) sampleOf(stylus.point, frame) else lastSample
        closeStroke(sends, StylusWire.Action.CANCEL, sample)
        // Every pointer in this event is gone; none of them will report an up.
        suppressed.clear()
        return Decision(handled = handled, sends = sends)
    }

    private fun closeStroke(
        sends: MutableList<Send>,
        action: StylusWire.Action,
        sample: StylusWire.Sample,
    ) {
        if (strokePointerId == null) return
        strokePointerId = null
        emit(sends, action, listOf(sample))
        strokeFlags = 0
    }

    private fun suppressFingers(frame: Frame) {
        for (pointer in frame.pointers) {
            if (!pointer.tool.isStylus) suppressed.add(pointer.id)
        }
    }

    private fun samplesOf(
        pointer: Pointer,
        frame: Frame,
    ): List<StylusWire.Sample> {
        val out = ArrayList<StylusWire.Sample>(pointer.history.size + 1)
        for (point in pointer.history) out.add(sampleOf(point, frame))
        out.add(sampleOf(pointer.point, frame))
        return out
    }

    private fun sampleOf(
        point: Point,
        frame: Frame,
    ): StylusWire.Sample {
        // R12. Absence is resolved here, so the wire never carries an "unknown" pressure.
        // R9. The clamp is required, not defensive: this device reports up to 2.44.
        val pressure = if (frame.hasPressureAxis) point.pressure.coerceIn(0f, 1f) else 1f
        val sample = StylusWire.Sample(point.x, point.y, pressure)
        lastSample = sample
        return sample
    }

    /**
     * Split into messages the wire accepts. Leading chunks always carry MOVE so a
     * batch larger than the cap cannot close the stroke early; the real action
     * rides on the last chunk. At the measured 4.8 samples per event this never
     * splits, but `StylusWire.encode` rejects an over-count message outright.
     */
    private fun emit(
        sends: MutableList<Send>,
        action: StylusWire.Action,
        samples: List<StylusWire.Sample>,
    ) {
        if (samples.isEmpty()) return
        var start = 0
        while (start < samples.size) {
            val end = minOf(start + StylusWire.MAX_SAMPLES, samples.size)
            val isLast = end == samples.size
            sends.add(
                Send(
                    if (isLast) action else StylusWire.Action.MOVE,
                    samples.subList(start, end).toList(),
                    strokeFlags,
                ),
            )
            start = end
        }
    }

    companion object {
        /** R22. No stylus sample for this long closes the stroke from the client side. */
        const val STALE_TIMEOUT_MS = 500L

        /**
         * R1. No hover sample for this long means the pen has left range.
         *
         * Measured on the target device: hover arrives every 8 ms at the median and
         * 9 ms at the 90th percentile — vsync-locked at ~125 Hz — while the gaps
         * between separate hover sessions run to hundreds of milliseconds. 150 ms is
         * roughly seventeen times the 90th-percentile gap, so it cannot expire while
         * the pen is genuinely in range, and it clears within a sixth of a second
         * once the pen is gone.
         */
        const val PROXIMITY_WINDOW_MS = 150L

        /**
         * The normalization the existing touch path applies, extracted so both paths
         * provably agree: `MainActivity.handleTouch` computes `event.x / view.width`
         * and mirrors it when the display is flipped.
         */
        fun normalize(
            value: Float,
            size: Float,
            flip: Boolean,
        ): Float {
            val raw = value / size
            return if (flip) 1f - raw else raw
        }

        /** `MotionEvent.TOOL_TYPE_STYLUS`, restated so this core stays free of framework types. */
        const val TOOL_TYPE_STYLUS = 2

        /** `MotionEvent.TOOL_TYPE_ERASER`, restated for the same reason. */
        const val TOOL_TYPE_ERASER = 4

        /**
         * Tool-type mapping, extracted from the adapter for the same reason as [normalize].
         *
         * An eraser is a pen held the other way up: it carries pressure, tilt and
         * proximity exactly as the tip does, so it belongs on the stylus path. The Tab S9
         * S Pen reports `TOOL_TYPE_STYLUS` when flipped and never `TOOL_TYPE_ERASER`, so
         * this is forward compatibility for other digitizers, not a fix for an observed
         * bug. No eraser *semantics* are implied — the host sees an ordinary stroke.
         */
        fun toolFor(toolType: Int): Tool =
            when (toolType) {
                TOOL_TYPE_STYLUS -> Tool.STYLUS
                TOOL_TYPE_ERASER -> Tool.ERASER
                else -> Tool.FINGER
            }
    }
}
