package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The persisted form of the trigger bindings.
 *
 * `PreferencesManager` needs a `Context` for its `SharedPreferences`, which a JVM
 * unit test has no way to supply — `getSharedPreferences` is one of the framework
 * stubs that throws "not mocked" under this Gradle setup, the same reason
 * `StylusInput` takes plain data instead of `MotionEvent`. So the serialize/parse
 * pair is a pure companion function pair, tested directly, exactly as
 * `AuthHandshake` and `StylusWire` are.
 */
class PenBindingsPreferenceTest {
    @Test
    fun roundTripsAFullMapping() {
        val bindings =
            mapOf(
                StylusInput.Trigger.BARREL_BUTTON to StylusInput.PenAction.SECONDARY_CLICK,
                StylusInput.Trigger.ERASER_TOOL to StylusInput.PenAction.ERASER,
            )
        val stored = PreferencesManager.encodePenBindings(bindings)
        assertEquals(bindings, PreferencesManager.decodePenBindings(stored))
    }

    @Test
    fun roundTripsASingleBinding() {
        val bindings = mapOf(StylusInput.Trigger.BARREL_BUTTON to StylusInput.PenAction.ERASER)
        assertEquals(bindings, PreferencesManager.decodePenBindings(PreferencesManager.encodePenBindings(bindings)))
    }

    /** Nothing is bound out of the box, and an empty map survives the round trip as one. */
    @Test
    fun defaultsToEmpty() {
        assertTrue(PreferencesManager.decodePenBindings(null).isEmpty())
        assertTrue(PreferencesManager.decodePenBindings("").isEmpty())
        assertEquals("", PreferencesManager.encodePenBindings(emptyMap()))
        assertTrue(PreferencesManager.decodePenBindings(PreferencesManager.encodePenBindings(emptyMap())).isEmpty())
    }

    /** Names, not ordinals — so a reorder of either enum cannot repoint a saved binding. */
    @Test
    fun storesEnumNames() {
        val stored =
            PreferencesManager.encodePenBindings(
                mapOf(StylusInput.Trigger.ERASER_TOOL to StylusInput.PenAction.SECONDARY_CLICK),
            )
        assertEquals("ERASER_TOOL:SECONDARY_CLICK", stored)
    }

    /**
     * A downgrade, or a renamed constant, must cost one binding rather than the
     * whole settings screen: the unknown entry is skipped and its neighbours load.
     */
    @Test
    fun skipsUnknownTriggerName() {
        val parsed = PreferencesManager.decodePenBindings("SIDE_SWITCH:ERASER,BARREL_BUTTON:SECONDARY_CLICK")
        assertEquals(mapOf(StylusInput.Trigger.BARREL_BUTTON to StylusInput.PenAction.SECONDARY_CLICK), parsed)
    }

    @Test
    fun skipsUnknownActionName() {
        val parsed = PreferencesManager.decodePenBindings("BARREL_BUTTON:UNDO,ERASER_TOOL:ERASER")
        assertEquals(mapOf(StylusInput.Trigger.ERASER_TOOL to StylusInput.PenAction.ERASER), parsed)
    }

    /** An entirely unrecognized blob reads as "nothing bound", never as an exception. */
    @Test
    fun unknownBlobReadsAsEmpty() {
        assertTrue(PreferencesManager.decodePenBindings("1:0,2:1").isEmpty())
        assertTrue(PreferencesManager.decodePenBindings("garbage").isEmpty())
        assertTrue(PreferencesManager.decodePenBindings(",,:,BARREL_BUTTON::ERASER").isEmpty())
    }

    /**
     * The stored form is only ever loaded through `restoreBindings`, which routes
     * every entry through `bind` — so even a hand-edited file claiming two triggers
     * for one action lands one to one, with no validation step of its own.
     */
    @Test
    fun restoringADuplicatedActionStaysOneToOne() {
        val input = StylusInput()
        input.restoreBindings(
            PreferencesManager.decodePenBindings("BARREL_BUTTON:ERASER,ERASER_TOOL:ERASER"),
        )
        assertEquals(1, input.currentBindings().size)
        assertEquals(StylusInput.Trigger.ERASER_TOOL, input.triggerFor(StylusInput.PenAction.ERASER))
    }

    /** What the app actually does at startup and after a rebind: save, reload, same bindings. */
    @Test
    fun survivesRestoreAndReSave() {
        val input = StylusInput()
        input.bind(StylusInput.Trigger.BARREL_BUTTON, StylusInput.PenAction.SECONDARY_CLICK)
        val stored = PreferencesManager.encodePenBindings(input.currentBindings())

        val reloaded = StylusInput()
        reloaded.restoreBindings(PreferencesManager.decodePenBindings(stored))
        assertEquals(input.currentBindings(), reloaded.currentBindings())
        assertEquals(stored, PreferencesManager.encodePenBindings(reloaded.currentBindings()))
    }
}
