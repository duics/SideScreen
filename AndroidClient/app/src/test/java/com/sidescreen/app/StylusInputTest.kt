package com.sidescreen.app

import android.view.MotionEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Palm suppression is where this unit is either right or subtly wrong, and it is
 * cheap to prove without a device — which is the whole reason `StylusInput` takes
 * plain data instead of a `MotionEvent`.
 */
class StylusInputTest {
    private fun point(
        x: Float,
        y: Float,
        pressure: Float = 0.4f,
    ) = StylusInput.Point(x, y, pressure)

    private fun stylus(
        id: Int = 1,
        x: Float = 0.5f,
        y: Float = 0.5f,
        pressure: Float = 0.4f,
        history: List<StylusInput.Point> = emptyList(),
    ) = StylusInput.Pointer(id, StylusInput.Tool.STYLUS, point(x, y, pressure), history)

    private fun finger(
        id: Int = 9,
        x: Float = 0.2f,
        y: Float = 0.8f,
    ) = StylusInput.Pointer(id, StylusInput.Tool.FINGER, point(x, y, 1f))

    private fun frame(
        action: StylusInput.Action,
        actionPointerId: Int,
        pointers: List<StylusInput.Pointer>,
        canceled: Boolean = false,
        hasPressureAxis: Boolean = true,
        eventTimeMs: Long = 0L,
    ) = StylusInput.Frame(action, actionPointerId, pointers, canceled, hasPressureAxis, eventTimeMs)

    /** Open a stroke with the stylus pointer id 1 and return the core. */
    private fun openStroke(
        core: StylusInput = StylusInput(),
        others: List<StylusInput.Pointer> = emptyList(),
        eventTimeMs: Long = 0L,
    ): StylusInput {
        val down =
            core.process(
                frame(
                    if (others.isEmpty()) StylusInput.Action.DOWN else StylusInput.Action.POINTER_DOWN,
                    1,
                    others + stylus(),
                    eventTimeMs = eventTimeMs,
                ),
            )
        assertTrue("stylus down must be handled by the stylus path", down.handled)
        return core
    }

    // --- AE1 / AE2: palm handling -------------------------------------------------

    /** Covers AE1, R3. A palm landing mid-stroke produces nothing and does not end the stroke. */
    @Test
    fun palmDuringStrokeIsSuppressedAndStrokeContinues() {
        val core = openStroke()

        val palmDown =
            core.process(frame(StylusInput.Action.POINTER_DOWN, 9, listOf(stylus(), finger()), eventTimeMs = 10))
        assertTrue(palmDown.handled)
        assertTrue(palmDown.sends.isEmpty())

        val moving = listOf(stylus(x = 0.6f), finger(x = 0.3f))
        val palmMove = core.process(frame(StylusInput.Action.MOVE, 9, moving, eventTimeMs = 20))
        assertTrue(palmMove.handled)
        // The stylus in the same event is still forwarded; the finger contributes nothing.
        assertEquals(1, palmMove.sends.size)
        assertEquals(StylusWire.Action.MOVE, palmMove.sends[0].action)
        assertEquals(1, palmMove.sends[0].samples.size)
        assertTrue(core.isStrokeOpen)
    }

    /** Covers AE2, R2, R3. A palm already down does not make the pen contact a two-pointer gesture. */
    @Test
    fun palmBeforePenOpensStylusStroke() {
        val core = StylusInput()
        val palm = core.process(frame(StylusInput.Action.DOWN, 9, listOf(finger())))
        assertFalse("a finger with no stroke belongs to the existing path", palm.handled)

        val penDown =
            core.process(frame(StylusInput.Action.POINTER_DOWN, 1, listOf(finger(), stylus()), eventTimeMs = 5))
        assertTrue(penDown.handled)
        assertEquals(listOf(StylusWire.Action.DOWN), penDown.sends.map { it.action })

        // The palm that was already on the glass is now suppressed.
        val palmMove =
            core.process(frame(StylusInput.Action.MOVE, 9, listOf(finger(x = 0.25f), stylus()), eventTimeMs = 10))
        assertTrue(palmMove.handled)
    }

    // --- R6: every measured sample ------------------------------------------------

    /** Covers R6. Three historical samples plus the current one forward as four, in digitizer order. */
    @Test
    fun moveForwardsHistoryInDigitizerOrder() {
        val core = openStroke()
        val history = listOf(point(0.10f, 0.10f), point(0.20f, 0.20f), point(0.30f, 0.30f))
        val pointers = listOf(stylus(x = 0.40f, y = 0.40f, history = history))
        val move = core.process(frame(StylusInput.Action.MOVE, 1, pointers, eventTimeMs = 8))
        val samples = move.sends.single().samples
        assertEquals(4, samples.size)
        assertEquals(listOf(0.10f, 0.20f, 0.30f, 0.40f), samples.map { it.x })
        assertEquals(listOf(0.10f, 0.20f, 0.30f, 0.40f), samples.map { it.y })
    }

    /** Covers R6. The measured shape on a Tab S9: ~4.8 samples per event. */
    @Test
    fun moveWithFourHistoricalSamplesForwardsFive() {
        val core = openStroke()
        val history = (1..4).map { point(it / 100f, it / 100f) }
        val move =
            core.process(frame(StylusInput.Action.MOVE, 1, listOf(stylus(history = history)), eventTimeMs = 8))
        assertEquals(5, move.sends.single().samples.size)
    }

    /** Covers R5. Every forwarded coordinate is the reported one — nothing is extrapolated. */
    @Test
    fun forwardedCoordinatesAreExactlyTheReportedOnes() {
        val core = openStroke()
        val history = listOf(point(0.111f, 0.222f), point(0.333f, 0.444f))
        val pointers = listOf(stylus(x = 0.555f, y = 0.666f, history = history))
        val move = core.process(frame(StylusInput.Action.MOVE, 1, pointers, eventTimeMs = 8))
        val samples = move.sends.single().samples
        assertEquals(listOf(0.111f, 0.333f, 0.555f), samples.map { it.x })
        assertEquals(listOf(0.222f, 0.444f, 0.666f), samples.map { it.y })
    }

    // --- R4: cancellation ----------------------------------------------------------

    /** Covers R4. ACTION_CANCEL during a stroke emits a cancel, not a plain up. */
    @Test
    fun cancelDuringStrokeEmitsCancel() {
        val core = openStroke()
        val cancel = core.process(frame(StylusInput.Action.CANCEL, 1, listOf(stylus()), eventTimeMs = 20))
        assertTrue(cancel.handled)
        assertEquals(listOf(StylusWire.Action.CANCEL), cancel.sends.map { it.action })
        assertFalse(core.isStrokeOpen)
    }

    /** Covers R4. FLAG_CANCELED on the stylus pointer's up ends the stroke as cancelled. */
    @Test
    fun canceledPointerUpEndsStrokeAsCancel() {
        val core = openStroke(others = listOf(finger()))
        val up =
            core.process(
                frame(
                    StylusInput.Action.POINTER_UP,
                    1,
                    listOf(finger(), stylus()),
                    canceled = true,
                    eventTimeMs = 30,
                ),
            )
        assertEquals(listOf(StylusWire.Action.CANCEL), up.sends.map { it.action })
        assertFalse(core.isStrokeOpen)
    }

    /** A clean lift ends the stroke with an up. */
    @Test
    fun cleanLiftEndsStrokeWithUp() {
        val core = openStroke()
        val up = core.process(frame(StylusInput.Action.UP, 1, listOf(stylus()), eventTimeMs = 30))
        assertEquals(listOf(StylusWire.Action.UP), up.sends.map { it.action })
        assertFalse(core.isStrokeOpen)
        assertFalse(core.isActive(0))
    }

    // --- Passthrough ---------------------------------------------------------------

    /** With no stylus pointer present, the existing path owns every event. */
    @Test
    fun fingerOnlyEventsAreNotHandled() {
        val core = StylusInput()
        assertFalse(core.process(frame(StylusInput.Action.DOWN, 9, listOf(finger()))).handled)
        assertFalse(core.process(frame(StylusInput.Action.MOVE, 9, listOf(finger(x = 0.3f)))).handled)
        assertFalse(core.process(frame(StylusInput.Action.POINTER_DOWN, 8, listOf(finger(), finger(8)))).handled)
        assertFalse(core.process(frame(StylusInput.Action.UP, 9, listOf(finger()))).handled)
        assertFalse(core.isActive(0))
    }

    /**
     * Covers KTD2, KTD11. When the host has not advertised the capability bit the
     * adapter calls [StylusInput.reset] and never consults the core, so the legacy
     * path handles the stylus as a finger. Reset must leave no state behind that
     * could suppress a later finger.
     */
    @Test
    fun resetLeavesTheExistingPathInCharge() {
        val core = openStroke(others = listOf(finger()))
        assertTrue(core.isActive(0))
        core.reset()
        assertFalse(core.isActive(0))
        assertFalse(core.isStrokeOpen)
        assertFalse(core.process(frame(StylusInput.Action.MOVE, 9, listOf(finger()))).handled)
    }

    /** Coordinates agree with the existing path's normalization, flips included. */
    @Test
    fun normalizationMatchesTheExistingTouchPath() {
        val rawX = 512f
        val rawY = 300f
        val width = 2560f
        val height = 1600f
        assertEquals(rawX / width, StylusInput.normalize(rawX, width, flip = false), 1e-6f)
        assertEquals(1f - rawX / width, StylusInput.normalize(rawX, width, flip = true), 1e-6f)
        assertEquals(rawY / height, StylusInput.normalize(rawY, height, flip = false), 1e-6f)
        assertEquals(1f - rawY / height, StylusInput.normalize(rawY, height, flip = true), 1e-6f)
    }

    // --- R25: suppression outlives the stroke ---------------------------------------

    /** Covers R25. The palm stays suppressed after the pen lifts, until its own up. */
    @Test
    fun suppressedFingerStaysSuppressedAfterTheStylusLifts() {
        val core = openStroke(others = listOf(finger()))

        val penUp =
            core.process(frame(StylusInput.Action.POINTER_UP, 1, listOf(finger(), stylus()), eventTimeMs = 40))
        assertEquals(listOf(StylusWire.Action.UP), penUp.sends.map { it.action })
        assertFalse(core.isStrokeOpen)
        assertTrue("the palm is still down and still suppressed", core.isActive(0))

        // Its moves are not forwarded, and its down is never sent retroactively.
        val palmMove = core.process(frame(StylusInput.Action.MOVE, 9, listOf(finger(x = 0.4f)), eventTimeMs = 50))
        assertTrue(palmMove.handled)
        assertTrue(palmMove.sends.isEmpty())

        // Its own up is swallowed too — the host never saw the matching down.
        val palmUp = core.process(frame(StylusInput.Action.UP, 9, listOf(finger()), eventTimeMs = 60))
        assertTrue(palmUp.handled)
        assertTrue(palmUp.sends.isEmpty())
        assertFalse(core.isActive(0))

        // The pen was on the glass moments ago, so it is still treated as in range:
        // lifting a nib a few millimetres does not end proximity, and a finger
        // landing now is still the wrist.
        assertTrue(core.process(frame(StylusInput.Action.DOWN, 9, listOf(finger()), eventTimeMs = 70)).handled)

        // Once the window has passed with no pen activity, the existing path owns
        // fingers again — with no message needed to say so.
        val gone = StylusInput.PROXIMITY_WINDOW_MS + 100
        assertFalse(core.process(frame(StylusInput.Action.DOWN, 9, listOf(finger()), eventTimeMs = gone)).handled)
    }

    /** A finger landing while a palm is still suppressed is suppressed too: its down never went out. */
    @Test
    fun fingerLandingWhileSuppressionHoldsIsAlsoSuppressed() {
        val core = openStroke(others = listOf(finger()))
        core.process(frame(StylusInput.Action.POINTER_UP, 1, listOf(finger(), stylus()), eventTimeMs = 40))

        val second =
            core.process(frame(StylusInput.Action.POINTER_DOWN, 8, listOf(finger(), finger(8)), eventTimeMs = 50))
        assertTrue(second.handled)
        assertTrue(second.sends.isEmpty())
    }

    // --- R9 / R12: pressure ----------------------------------------------------------

    /** Covers R12. A device with no pressure axis yields full scale on every sample. */
    @Test
    fun missingPressureAxisYieldsFullScale() {
        val core = StylusInput()
        val down =
            core.process(
                frame(StylusInput.Action.DOWN, 1, listOf(stylus(pressure = 0f)), hasPressureAxis = false),
            )
        assertEquals(1f, down.sends.single().samples.single().pressure, 0f)

        val move =
            core.process(
                frame(
                    StylusInput.Action.MOVE,
                    1,
                    listOf(stylus(pressure = 0f, history = listOf(point(0.1f, 0.1f, 0f)))),
                    hasPressureAxis = false,
                    eventTimeMs = 8,
                ),
            )
        assertTrue(move.sends.single().samples.all { it.pressure == 1f })
    }

    /** Covers R12. A device that reports pressure passes its values through, zero included. */
    @Test
    fun reportedPressurePassesThroughIncludingZero() {
        val core = StylusInput()
        val down = core.process(frame(StylusInput.Action.DOWN, 1, listOf(stylus(pressure = 0f))))
        assertEquals(0f, down.sends.single().samples.single().pressure, 0f)

        val move =
            core.process(
                frame(StylusInput.Action.MOVE, 1, listOf(stylus(pressure = 0.348f)), eventTimeMs = 8),
            )
        assertEquals(0.348f, move.sends.single().samples.single().pressure, 1e-6f)
    }

    /** Covers R9. The 2.44 this hardware actually reports is clamped before encoding. */
    @Test
    fun pressureAboveFullScaleIsClamped() {
        val core = StylusInput()
        val down = core.process(frame(StylusInput.Action.DOWN, 1, listOf(stylus(pressure = 2.44f))))
        val sample = down.sends.single().samples.single()
        assertEquals(1f, sample.pressure, 0f)
        // And it survives the wire as full scale rather than wrapping.
        val bytes = StylusWire.encode(StylusWire.Action.DOWN, listOf(sample))
        assertEquals(0xFF, bytes[8].toInt() and 0xFF)
        assertEquals(0xFF, bytes[9].toInt() and 0xFF)
    }

    // --- R22: staleness ---------------------------------------------------------------

    /** Covers R22. 500 ms with no stylus sample cancels the stroke and releases suppression. */
    @Test
    fun staleStrokeCancelsAndReleasesSuppression() {
        val core = openStroke(others = listOf(finger()), eventTimeMs = 1_000)

        val late = core.process(frame(StylusInput.Action.MOVE, 9, listOf(finger(x = 0.4f)), eventTimeMs = 1_500))
        assertEquals(listOf(StylusWire.Action.CANCEL), late.sends.map { it.action })
        assertFalse(core.isStrokeOpen)
        assertFalse("suppression must not outlive the staleness bound", core.isActive(0))
        assertFalse("the existing path takes the finger back", late.handled)
    }

    /** A stroke still receiving samples is never closed by the staleness bound. */
    @Test
    fun freshStrokeIsNotClosedByTheStalenessBound() {
        val core = openStroke(eventTimeMs = 1_000)
        var t = 1_000L
        repeat(20) {
            t += 400
            val move = core.process(frame(StylusInput.Action.MOVE, 1, listOf(stylus()), eventTimeMs = t))
            assertEquals(listOf(StylusWire.Action.MOVE), move.sends.map { it.action })
        }
        assertTrue(core.isStrokeOpen)
    }

    // --- Wire-cap safety ----------------------------------------------------------------

    /** A batch larger than the wire cap splits, and only the last message carries the real action. */
    @Test
    fun oversizedBatchSplitsWithTheActionOnTheLastMessage() {
        val core = openStroke()
        val history = (1..99).map { point(it / 1000f, it / 1000f) }
        val up =
            core.process(frame(StylusInput.Action.UP, 1, listOf(stylus(history = history)), eventTimeMs = 40))
        assertEquals(listOf(StylusWire.Action.MOVE, StylusWire.Action.UP), up.sends.map { it.action })
        assertEquals(StylusWire.MAX_SAMPLES, up.sends[0].samples.size)
        assertEquals(36, up.sends[1].samples.size)
        // Every message the core produces is encodable — `encode` rejects an over-count one.
        up.sends.forEach { StylusWire.encode(it.action, it.samples) }
    }

    // --- Hover (follow-up plan U1) ----------------------------------------------------

    private fun hover(
        action: StylusInput.HoverAction,
        x: Float = 0.5f,
        y: Float = 0.5f,
        tool: StylusInput.Tool = StylusInput.Tool.STYLUS,
        distance: Float? = null,
        eventTimeMs: Long = 0L,
    ) = StylusInput.HoverFrame(action, tool, point(x, y, 0f), distance, eventTimeMs)

    /** Covers R1. Every hover sample is one HOVER message at a real zero pressure. */
    @Test
    fun hoverSamplesForwardAsOneActionAtZeroPressure() {
        val core = StylusInput()
        val first = core.processHover(hover(StylusInput.HoverAction.ENTER, x = 0.10f, y = 0.20f, eventTimeMs = 100))
        assertTrue(first.handled)
        assertEquals(listOf(StylusWire.Action.HOVER), first.sends.map { it.action })
        assertEquals(StylusWire.Sample(0.10f, 0.20f, 0f), first.sends.single().samples.single())
        assertTrue(core.isInProximity(100))

        val moved =
            (1..3).map {
                core.processHover(
                    hover(StylusInput.HoverAction.MOVE, x = it / 10f, y = it / 10f, eventTimeMs = 100L + it * 8),
                )
            }
        assertEquals(List(3) { StylusWire.Action.HOVER }, moved.map { it.sends.single().action })
        assertTrue(moved.all { it.sends.single().samples.single().pressure == 0f })
    }

    /**
     * There is no enter on the wire, so a missing one cannot strand anything: the
     * first sample of a session is indistinguishable from any other.
     */
    @Test
    fun aHoverMoveWithNoEnterBehindItStillEntersProximity() {
        val core = StylusInput()
        val move = core.processHover(hover(StylusInput.HoverAction.MOVE, eventTimeMs = 500))
        assertEquals(listOf(StylusWire.Action.HOVER), move.sends.map { it.action })
        assertTrue(core.isInProximity(500))
    }

    /** Covers R3. A finger the digitizer reports as hovering is never forwarded. */
    @Test
    fun fingerHoverIsIgnored() {
        val core = StylusInput()
        for (action in StylusInput.HoverAction.values()) {
            val decision = core.processHover(hover(action, tool = StylusInput.Tool.FINGER))
            assertFalse("a finger hover belongs to the rest of the app", decision.handled)
            assertTrue(decision.sends.isEmpty())
        }
        assertFalse(core.isInProximity(0))
    }

    /**
     * The reason proximity is derived rather than latched. `ViewGroup.exitHoverTargets`
     * builds the exit it synthesizes on surface detach with `TOOL_TYPE_UNKNOWN`, which
     * maps to [StylusInput.Tool.FINGER]. Under a latch that exit had to be recognised
     * or proximity stuck forever and swallowed every finger. Here it is simply ignored
     * and the window ends proximity on its own.
     */
    @Test
    fun aSynthesizedExitIsIgnoredAndProximityStillEnds() {
        val core = StylusInput()
        core.processHover(hover(StylusInput.HoverAction.ENTER, x = 0.3f, y = 0.4f, eventTimeMs = 1_000))
        assertTrue(core.isInProximity(1_000))

        val synthesized =
            core.processHover(
                hover(
                    StylusInput.HoverAction.EXIT,
                    x = 0.3f,
                    y = 0.4f,
                    tool = StylusInput.toolFor(MotionEvent.TOOL_TYPE_UNKNOWN),
                    eventTimeMs = 1_010,
                ),
            )
        assertFalse("an unknown-tool event is not ours", synthesized.handled)
        assertTrue(synthesized.sends.isEmpty())

        // Nothing cleared it, and nothing had to: the window did.
        assertTrue(core.isInProximity(1_100))
        assertFalse(core.isInProximity(1_000 + StylusInput.PROXIMITY_WINDOW_MS))

        // And the touchscreen works again, with no message needed to say so.
        assertFalse(core.process(frame(StylusInput.Action.DOWN, 9, listOf(finger()), eventTimeMs = 1_200)).handled)
    }

    /**
     * An exit changes nothing at all. Android emits one as the nib reaches the
     * glass, so acting on it would drop finger suppression in the instant before
     * the pen touches down — when the wrist is most likely already resting.
     */
    @Test
    fun aStylusExitIsConsumedAndOtherwiseIgnored() {
        val core = StylusInput()
        core.processHover(hover(StylusInput.HoverAction.ENTER, eventTimeMs = 2_000))
        val exit = core.processHover(hover(StylusInput.HoverAction.EXIT, eventTimeMs = 2_010))
        assertTrue("a stylus event is ours either way", exit.handled)
        assertTrue(exit.sends.isEmpty())
        assertTrue("proximity survives the transition to contact", core.isInProximity(2_010))
    }

    /**
     * Suppression held on proximity's behalf is released once proximity expires, so
     * a lost exit cannot present as "touch stopped working".
     */
    @Test
    fun proximityExpiryReleasesSuppression() {
        val core = StylusInput()
        core.processHover(hover(StylusInput.HoverAction.ENTER, x = 0.6f, y = 0.7f, eventTimeMs = 1_000))
        // A finger that lands while the pen is genuinely still there is suppressed.
        assertTrue(core.process(frame(StylusInput.Action.DOWN, 9, listOf(finger()), eventTimeMs = 1_100)).handled)
        assertTrue(core.process(frame(StylusInput.Action.UP, 9, listOf(finger()), eventTimeMs = 1_120)).handled)

        // No hover sample since; past the window the pen is treated as gone.
        val late = core.process(frame(StylusInput.Action.DOWN, 9, listOf(finger()), eventTimeMs = 1_400))
        assertFalse("the existing path takes the finger back", late.handled)
        assertTrue("nothing has to be sent to say so", late.sends.isEmpty())
        assertFalse(core.isInProximity(1_400))
        assertFalse(core.isActive(1_400))
    }

    /** A pen genuinely in range emits samples continuously, so the bound never fires on it. */
    @Test
    fun proximityIsNotExpiredWhileHoverSamplesKeepArriving() {
        val core = StylusInput()
        var t = 1_000L
        core.processHover(hover(StylusInput.HoverAction.ENTER, eventTimeMs = t))
        // The measured cadence on the target device is 8 ms at the median and 9 ms
        // at the 90th percentile, so 20 ms is already a pessimistic stand-in for a
        // pen actually in range.
        repeat(50) {
            t += 20
            core.processHover(hover(StylusInput.HoverAction.MOVE, eventTimeMs = t))
            val finger = core.process(frame(StylusInput.Action.DOWN, 9, listOf(finger()), eventTimeMs = t + 1))
            assertTrue("the pen is still in range", finger.handled)
            core.process(frame(StylusInput.Action.UP, 9, listOf(finger()), eventTimeMs = t + 2))
        }
        assertTrue(core.isInProximity(t))
    }

    /** A stroke keeps proximity alive: hover falls silent while the nib is down, by design. */
    @Test
    fun aStrokeKeepsTheProximityBoundFresh() {
        val core = StylusInput()
        core.processHover(hover(StylusInput.HoverAction.ENTER, eventTimeMs = 1_000))
        core.process(frame(StylusInput.Action.DOWN, 1, listOf(stylus()), eventTimeMs = 1_100))
        var t = 1_100L
        repeat(10) {
            t += 100
            core.process(frame(StylusInput.Action.MOVE, 1, listOf(stylus()), eventTimeMs = t))
        }
        val up = core.process(frame(StylusInput.Action.UP, 1, listOf(stylus()), eventTimeMs = t + 100))
        assertEquals(listOf(StylusWire.Action.UP), up.sends.map { it.action })
        assertTrue("the pen never left range", core.isInProximity(t + 100))
    }

    /**
     * Leaving the foreground needs no hook and no message. The client stops
     * emitting hover samples because the surface is gone, and both sides expire
     * proximity on the same window — which is the whole point of deriving it.
     */
    @Test
    fun backgroundingExpiresProximityWithNoMessageAndNoHook() {
        val core = StylusInput()
        core.processHover(hover(StylusInput.HoverAction.ENTER, x = 0.25f, y = 0.75f, eventTimeMs = 3_000))
        assertTrue(core.isInProximity(3_000))

        // Nothing further arrives — the app is no longer receiving hover events.
        assertFalse(core.isInProximity(3_000 + StylusInput.PROXIMITY_WINDOW_MS))

        // And a finger reaching the app afterwards goes back to the existing path.
        val finger = core.process(frame(StylusInput.Action.DOWN, 9, listOf(finger()), eventTimeMs = 3_500))
        assertFalse(finger.handled)
        assertTrue(finger.sends.isEmpty())
    }

    /** Covers AE4, R8. With hover off nothing is forwarded and no proximity is entered. */
    @Test
    fun hoverOffForwardsNothing() {
        val core = StylusInput()
        assertTrue(core.isHoverEnabled)
        core.setHoverEnabled(false)
        assertFalse(core.isHoverEnabled)

        for (action in StylusInput.HoverAction.values()) {
            val decision = core.processHover(hover(action))
            assertFalse(decision.handled)
            assertTrue(decision.sends.isEmpty())
        }
        assertFalse(core.isInProximity(0))

        // AE4. Drawing is untouched: the stroke behaves exactly as the core plan's.
        val down = core.process(frame(StylusInput.Action.DOWN, 1, listOf(stylus())))
        assertEquals(listOf(StylusWire.Action.DOWN), down.sends.map { it.action })
        val up = core.process(frame(StylusInput.Action.UP, 1, listOf(stylus()), eventTimeMs = 20))
        assertEquals(listOf(StylusWire.Action.UP), up.sends.map { it.action })
        assertFalse(core.isActive(0))
    }

    /** Turning hover off mid-hover drops proximity immediately and sends nothing. */
    @Test
    fun turningHoverOffWhileHoveringDropsProximity() {
        val core = StylusInput()
        core.processHover(hover(StylusInput.HoverAction.ENTER, x = 0.4f, y = 0.6f, eventTimeMs = 4_000))
        assertTrue(core.isInProximity(4_000))

        core.setHoverEnabled(false)
        assertFalse(core.isInProximity(4_000))
        assertFalse(core.isActive(4_000))
    }

    /** Covers R2. Leaving range is consumed but forwards nothing — the window ends it. */
    @Test
    fun leavingRangeForwardsNothing() {
        val core = StylusInput()
        core.processHover(hover(StylusInput.HoverAction.ENTER, eventTimeMs = 5_000))
        val exit =
            core.processHover(
                hover(StylusInput.HoverAction.EXIT, x = 0.7f, y = 0.8f, distance = 102f, eventTimeMs = 5_010),
            )
        assertTrue(exit.handled)
        assertTrue(exit.sends.isEmpty())
        assertTrue("the exit changes nothing; the window ends proximity", core.isInProximity(5_010))
        assertFalse(core.isInProximity(5_000 + StylusInput.PROXIMITY_WINDOW_MS))
    }

    /** Covers R2. The exit Android fires as the nib reaches the glass is not forwarded — the down implies it. */
    @Test
    fun hoverExitAtContactIsNotForwarded() {
        val core = StylusInput()
        core.processHover(hover(StylusInput.HoverAction.ENTER))

        // Input reader order: the real stylus hover exit, at distance zero, then the down.
        val exit = core.processHover(hover(StylusInput.HoverAction.EXIT, distance = 0f))
        assertTrue(exit.handled)
        assertTrue("the down is the transition; an exit here would unbalance proximity", exit.sends.isEmpty())
        assertTrue(core.isInProximity(0))

        val down = core.process(frame(StylusInput.Action.DOWN, 1, listOf(stylus()), eventTimeMs = 10))
        assertEquals(listOf(StylusWire.Action.DOWN), down.sends.map { it.action })

        // ViewGroup order: the synthesized exit arrives from inside the down's dispatch.
        val late = core.processHover(hover(StylusInput.HoverAction.EXIT))
        assertTrue(late.sends.isEmpty())
        assertTrue(core.isInProximity(10))
    }

    /**
     * Covers AE1. Hover moves, then a touch down: hover samples then a down, with no
     * exit and no duplicate position event between them.
     */
    @Test
    fun hoverThenTouchDownForwardsHoverSamplesThenADownWithNothingInBetween() {
        val core = StylusInput()
        val sends = mutableListOf<StylusInput.Send>()
        sends += core.processHover(hover(StylusInput.HoverAction.ENTER, x = 0.10f, y = 0.10f)).sends
        sends += core.processHover(hover(StylusInput.HoverAction.MOVE, x = 0.20f, y = 0.20f)).sends
        sends += core.processHover(hover(StylusInput.HoverAction.MOVE, x = 0.30f, y = 0.30f)).sends
        sends += core.processHover(hover(StylusInput.HoverAction.EXIT, x = 0.30f, y = 0.30f, distance = 0f)).sends
        sends +=
            core
                .process(
                    frame(StylusInput.Action.DOWN, 1, listOf(stylus(x = 0.30f, y = 0.30f)), eventTimeMs = 10),
                ).sends

        assertEquals(
            listOf(
                StylusWire.Action.HOVER,
                StylusWire.Action.HOVER,
                StylusWire.Action.HOVER,
                StylusWire.Action.DOWN,
            ),
            sends.map { it.action },
        )
    }

    /** Hover coordinates ride the same normalization and flip handling as stroke samples. */
    @Test
    fun hoverUsesTheSameNormalizationAsStrokeSamples() {
        val core = StylusInput()
        val x = StylusInput.normalize(512f, 2560f, flip = true)
        val y = StylusInput.normalize(300f, 1600f, flip = false)
        val enter = core.processHover(hover(StylusInput.HoverAction.ENTER, x = x, y = y))
        val sample = enter.sends.single().samples.single()
        assertEquals(1f - 512f / 2560f, sample.x, 1e-6f)
        assertEquals(300f / 1600f, sample.y, 1e-6f)
    }

    /** After a stroke that started from hover, the pen is still in proximity. */
    @Test
    fun proximitySurvivesAStrokeStartedFromHover() {
        val core = StylusInput()
        core.processHover(hover(StylusInput.HoverAction.ENTER))
        core.process(frame(StylusInput.Action.DOWN, 1, listOf(stylus()), eventTimeMs = 10))
        core.process(frame(StylusInput.Action.UP, 1, listOf(stylus()), eventTimeMs = 20))

        assertFalse(core.isStrokeOpen)
        assertTrue("the pen never left range", core.isInProximity(20))
        // And the next hover sample is just another sample.
        val move = core.processHover(hover(StylusInput.HoverAction.MOVE, eventTimeMs = 30))
        assertEquals(listOf(StylusWire.Action.HOVER), move.sends.map { it.action })
    }

    /** Reset drops proximity along with everything else. */
    @Test
    fun resetClearsProximity() {
        val core = StylusInput()
        core.processHover(hover(StylusInput.HoverAction.ENTER, eventTimeMs = 5))
        core.reset()
        assertFalse(core.isInProximity(5))
        assertFalse(core.isActive(0))
    }

    // --- R9 / AE5: the wrist-before-pen gap ------------------------------------------

    /**
     * Covers AE5, R9. The measured failure: the wrist lands, One UI cancels it 75 ms
     * later, and the pen arrives 339 ms after that — long enough for the wrist's
     * gesture to have completed on the Mac. Proximity is the only signal early enough,
     * so a finger arriving while the pen is in range never reaches the existing path.
     */
    @Test
    fun fingerLandingWhileThePenHoversIsSuppressedBeforeTheStylusTouchesDown() {
        val core = StylusInput()
        // The pen is in range and hovering right up to the moment the wrist lands.
        core.processHover(hover(StylusInput.HoverAction.ENTER, eventTimeMs = 990))

        val wristDown = core.process(frame(StylusInput.Action.DOWN, 9, listOf(finger()), eventTimeMs = 1_000))
        assertTrue("the existing path must never see this down", wristDown.handled)
        assertTrue(wristDown.sends.isEmpty())

        val wristMove =
            core.process(frame(StylusInput.Action.MOVE, 9, listOf(finger(x = 0.25f)), eventTimeMs = 1_050))
        assertTrue(wristMove.handled)
        assertTrue(wristMove.sends.isEmpty())

        // 339 ms later the pen arrives and draws normally.
        val penDown =
            core.process(
                frame(StylusInput.Action.POINTER_DOWN, 1, listOf(finger(), stylus()), eventTimeMs = 1_339),
            )
        assertEquals(listOf(StylusWire.Action.DOWN), penDown.sends.map { it.action })

        val penUp =
            core.process(
                frame(StylusInput.Action.POINTER_UP, 1, listOf(finger(), stylus()), eventTimeMs = 1_400),
            )
        assertEquals(listOf(StylusWire.Action.UP), penUp.sends.map { it.action })

        // The wrist's own up is swallowed too: the host never saw its down.
        val wristUp = core.process(frame(StylusInput.Action.UP, 9, listOf(finger()), eventTimeMs = 1_500))
        assertTrue(wristUp.handled)
        assertTrue(wristUp.sends.isEmpty())
    }

    /**
     * Covers R9. Suppression is identity-based and tied to proximity — it is not a
     * timer and not a blackout window. Once the pen leaves range, fingers are the
     * existing path's again immediately.
     */
    @Test
    fun fingerSuppressionLiftsWhenProximityExpires() {
        val core = StylusInput()
        core.processHover(hover(StylusInput.HoverAction.ENTER, eventTimeMs = 0))
        assertTrue(core.process(frame(StylusInput.Action.DOWN, 9, listOf(finger()), eventTimeMs = 10)).handled)
        core.process(frame(StylusInput.Action.UP, 9, listOf(finger()), eventTimeMs = 20))

        // The pen leaves. No message says so; the samples simply stop.
        val after = StylusInput.PROXIMITY_WINDOW_MS + 10
        assertFalse(core.isInProximity(after))
        assertFalse(core.isActive(after))
        assertFalse(
            "the very next finger belongs to the existing path",
            core.process(frame(StylusInput.Action.DOWN, 9, listOf(finger()), eventTimeMs = after)).handled,
        )
    }

    /**
     * Covers R9. A finger already on the glass when the pen approaches keeps reaching
     * the existing path, up included — its down was forwarded, so swallowing its up
     * would leave the host holding an unfinished gesture. R9 suppresses contacts that
     * *arrive* during proximity, not ones already in progress.
     */
    @Test
    fun fingerAlreadyDownWhenThePenApproachesKeepsItsUp() {
        val core = StylusInput()
        assertFalse(core.process(frame(StylusInput.Action.DOWN, 9, listOf(finger()), eventTimeMs = 0)).handled)

        core.processHover(hover(StylusInput.HoverAction.ENTER))

        assertFalse(core.process(frame(StylusInput.Action.MOVE, 9, listOf(finger(x = 0.3f)), eventTimeMs = 10)).handled)
        assertFalse(core.process(frame(StylusInput.Action.UP, 9, listOf(finger()), eventTimeMs = 20)).handled)
    }

    /**
     * A hover event that lands while the nib is down is dropped, and — the part
     * that is easy to get wrong — it does not become the position a cancel would
     * release at. The stroke's own last sample has to survive it.
     */
    @Test
    fun hoverDuringAStrokeDoesNotDisturbTheStrokesLastSample() {
        val core = StylusInput()
        core.processHover(hover(StylusInput.HoverAction.ENTER))
        core.process(frame(StylusInput.Action.DOWN, 1, listOf(stylus(x = 0.2f, y = 0.2f)), eventTimeMs = 10))
        core.process(frame(StylusInput.Action.MOVE, 1, listOf(stylus(x = 0.3f, y = 0.3f)), eventTimeMs = 20))

        assertTrue(core.processHover(hover(StylusInput.HoverAction.MOVE, x = 0.9f, y = 0.9f)).sends.isEmpty())

        // The stroke pointer vanishes without an up, so the cancel falls back to
        // the remembered sample. It must be the stroke's, not the stray hover's.
        val cancel = core.process(frame(StylusInput.Action.MOVE, 1, emptyList(), eventTimeMs = 30))
        val released = cancel.sends.single().samples.single()
        assertEquals(StylusWire.Action.CANCEL, cancel.sends.single().action)
        assertEquals(0.3f, released.x, 1e-6f)
        assertEquals(0.3f, released.y, 1e-6f)
    }

    /**
     * An eraser-reporting pen must reach the stylus path, not the finger path. The
     * constants are compared against the framework's own so the restated copies in
     * [StylusInput] cannot drift.
     */
    @Test
    fun eraserToolTakesTheStylusPath() {
        assertEquals(MotionEvent.TOOL_TYPE_STYLUS, StylusInput.TOOL_TYPE_STYLUS)
        assertEquals(MotionEvent.TOOL_TYPE_ERASER, StylusInput.TOOL_TYPE_ERASER)
        assertEquals(StylusInput.Tool.STYLUS, StylusInput.toolFor(MotionEvent.TOOL_TYPE_ERASER))
        assertEquals(StylusInput.Tool.STYLUS, StylusInput.toolFor(MotionEvent.TOOL_TYPE_STYLUS))
        assertEquals(StylusInput.Tool.FINGER, StylusInput.toolFor(MotionEvent.TOOL_TYPE_FINGER))
        assertEquals(StylusInput.Tool.FINGER, StylusInput.toolFor(MotionEvent.TOOL_TYPE_UNKNOWN))

        // And an eraser pointer, carried as a stylus, opens a real stroke.
        val core = StylusInput()
        val eraser =
            StylusInput.Pointer(
                1,
                StylusInput.toolFor(MotionEvent.TOOL_TYPE_ERASER),
                point(0.5f, 0.5f),
                emptyList(),
            )
        val down = core.process(frame(StylusInput.Action.DOWN, 1, listOf(eraser)))
        assertTrue(down.handled)
        assertEquals(StylusWire.Action.DOWN, down.sends.single().action)
        assertTrue(core.isStrokeOpen)
    }

    /** Hovering alone keeps the adapter consulting the core, so R9 can see a finger's down at all. */
    @Test
    fun hoveringMakesTheCoreActiveWithoutOpeningAStroke() {
        val core = StylusInput()
        assertFalse(core.isActive(0))
        core.processHover(hover(StylusInput.HoverAction.ENTER))
        assertTrue(core.isActive(0))
        assertFalse(core.isStrokeOpen)
    }
}
