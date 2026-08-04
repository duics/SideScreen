package com.sidescreen.app

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class StylusWireTest {
    /** One 16-bit step — the round-trip tolerance for a quantized unit field. */
    private val step = 1f / StylusWire.UNIT_SCALE

    private fun uint16At(
        bytes: ByteArray,
        offset: Int,
    ): Int = ((bytes[offset].toInt() and 0xFF) shl 8) or (bytes[offset + 1].toInt() and 0xFF)

    private fun sampleAt(
        bytes: ByteArray,
        index: Int,
    ): StylusWire.Sample {
        val base = StylusWire.HEADER_SIZE + index * StylusWire.SAMPLE_SIZE
        return StylusWire.Sample(
            StylusWire.dequantizeUnit(uint16At(bytes, base)),
            StylusWire.dequantizeUnit(uint16At(bytes, base + 2)),
            StylusWire.dequantizeUnit(uint16At(bytes, base + 4)),
        )
    }

    /**
     * The layout contract. `MacHost/Tests/SideScreenTests/StylusCodecTests.swift`
     * asserts the same bytes for the same input — if one side drifts, both fail.
     */
    @Test
    fun encodesGoldenBytes() {
        val bytes =
            StylusWire.encode(
                StylusWire.Action.MOVE,
                listOf(
                    StylusWire.Sample(0.25f, 0.75f, 1.0f),
                    StylusWire.Sample(0.0f, 1.0f, 0.125f),
                ),
            )
        val expected =
            byteArrayOf(
                0x0C, 0x01, 0x02, 0x00, 0x02,
                0x40, 0x00, 0xBF.toByte(), 0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte(),
                0x00, 0x00, 0xFF.toByte(), 0xFF.toByte(), 0x20, 0x00,
            )
        assertArrayEquals(expected, bytes)
    }

    @Test
    fun roundTripsThreeSampleMove() {
        val samples =
            listOf(
                StylusWire.Sample(0.1234f, 0.9876f, 0.0153f),
                StylusWire.Sample(0.5f, 0.5f, 0.3481f),
                StylusWire.Sample(0.9999f, 0.0001f, 0.7f),
            )
        val bytes = StylusWire.encode(StylusWire.Action.MOVE, samples)

        assertEquals(StylusWire.MESSAGE_TYPE, bytes[0].toInt())
        assertEquals(StylusWire.Action.MOVE.code, bytes[1].toInt())
        assertEquals(StylusWire.SAMPLE_FORMAT_XYP_FLAGS, bytes[2].toInt())
        assertEquals("no trigger bound, so no flags", 0, bytes[3].toInt())
        assertEquals(3, bytes[4].toInt())
        assertEquals(StylusWire.HEADER_SIZE + 3 * StylusWire.SAMPLE_SIZE, bytes.size)

        for (i in samples.indices) {
            val decoded = sampleAt(bytes, i)
            assertEquals(samples[i].x, decoded.x, step)
            assertEquals(samples[i].y, decoded.y, step)
            assertEquals(samples[i].pressure, decoded.pressure, step)
        }
    }

    /** R9: the device reports pressure above 1.0 — 2.442 observed — so this clamps. */
    @Test
    fun clampsPressureAboveFullScale() {
        val bytes = StylusWire.encode(StylusWire.Action.MOVE, listOf(StylusWire.Sample(0.5f, 0.5f, 2.44f)))
        assertEquals(StylusWire.UNIT_SCALE, uint16At(bytes, StylusWire.HEADER_SIZE + 4))
        assertEquals(1.0f, sampleAt(bytes, 0).pressure, 0f)
    }

    @Test
    fun clampsCoordinatesOutsideUnitRange() {
        val bytes = StylusWire.encode(StylusWire.Action.MOVE, listOf(StylusWire.Sample(-0.5f, 1.75f, 0.5f)))
        assertEquals(0, uint16At(bytes, StylusWire.HEADER_SIZE))
        assertEquals(StylusWire.UNIT_SCALE, uint16At(bytes, StylusWire.HEADER_SIZE + 2))
    }

    /** R12: absence is resolved before encoding, so a zero on the wire is a real zero. */
    @Test
    fun zeroPressureStaysZero() {
        val bytes = StylusWire.encode(StylusWire.Action.DOWN, listOf(StylusWire.Sample(0.25f, 0.25f, 0.0f)))
        assertEquals(0, uint16At(bytes, StylusWire.HEADER_SIZE + 4))
        assertEquals(0.0f, sampleAt(bytes, 0).pressure, 0f)
    }

    @Test
    fun roundTripsSingleSampleDown() {
        val sample = StylusWire.Sample(0.4f, 0.6f, 0.2f)
        val bytes = StylusWire.encode(StylusWire.Action.DOWN, listOf(sample))
        assertEquals(11, bytes.size)
        assertEquals(StylusWire.Action.DOWN.code, bytes[1].toInt())
        assertEquals(1, bytes[4].toInt())
        val decoded = sampleAt(bytes, 0)
        assertEquals(sample.x, decoded.x, step)
        assertEquals(sample.y, decoded.y, step)
        assertEquals(sample.pressure, decoded.pressure, step)
    }

    @Test
    fun roundTripsSixtyFourSampleMove() {
        val samples =
            (0 until StylusWire.MAX_SAMPLES).map {
                StylusWire.Sample(it / 100f, 1f - it / 100f, it / 64f)
            }
        val bytes = StylusWire.encode(StylusWire.Action.MOVE, samples)
        assertEquals(StylusWire.HEADER_SIZE + StylusWire.MAX_SAMPLES * StylusWire.SAMPLE_SIZE, bytes.size)
        assertEquals(389, bytes.size)
        assertEquals(StylusWire.MAX_SAMPLES, bytes[4].toInt())
        for (i in samples.indices) {
            val decoded = sampleAt(bytes, i)
            assertEquals(samples[i].x, decoded.x, step)
            assertEquals(samples[i].y, decoded.y, step)
            assertEquals(samples[i].pressure, decoded.pressure, step)
        }
    }

    @Test
    fun preservesSampleOrder() {
        val samples =
            listOf(
                StylusWire.Sample(0.1f, 0.1f, 0.1f),
                StylusWire.Sample(0.2f, 0.2f, 0.2f),
                StylusWire.Sample(0.3f, 0.3f, 0.3f),
            )
        val bytes = StylusWire.encode(StylusWire.Action.MOVE, samples)
        assertEquals(0.1f, sampleAt(bytes, 0).x, step)
        assertEquals(0.2f, sampleAt(bytes, 1).x, step)
        assertEquals(0.3f, sampleAt(bytes, 2).x, step)
    }

    @Test
    fun encodesEveryAction() {
        for (action in StylusWire.Action.values()) {
            val bytes = StylusWire.encode(action, listOf(StylusWire.Sample(0f, 0f, 0f)))
            assertEquals(action.code, bytes[1].toInt())
        }
        assertArrayEquals(
            intArrayOf(0, 1, 2, 3, 4),
            StylusWire.Action.values().map { it.code }.toIntArray(),
        )
    }

    /**
     * The four contact codes are frozen. Hover took the next three free values, so
     * every golden-byte vector taken before hover existed still holds and an
     * un-upgraded host rejects a hover action instead of drawing with it.
     */
    @Test
    fun contactActionCodesAreUnchangedByHover() {
        assertEquals(0, StylusWire.Action.DOWN.code)
        assertEquals(1, StylusWire.Action.MOVE.code)
        assertEquals(2, StylusWire.Action.UP.code)
        assertEquals(3, StylusWire.Action.CANCEL.code)
        assertEquals(4, StylusWire.Action.HOVER.code)
    }

    /** A hover sample is an ordinary sample at a real zero pressure (R12). */
    @Test
    fun encodesGoldenHoverBytes() {
        val bytes =
            StylusWire.encode(
                StylusWire.Action.HOVER,
                listOf(StylusWire.Sample(0.25f, 0.75f, 0f)),
            )
        val expected =
            byteArrayOf(
                0x0C, 0x04, 0x02, 0x00, 0x01,
                0x40, 0x00, 0xBF.toByte(), 0xFF.toByte(), 0x00, 0x00,
            )
        assertArrayEquals(expected, bytes)
    }

    @Test
    fun rejectsEmptySampleList() {
        try {
            StylusWire.encode(StylusWire.Action.MOVE, emptyList())
            error("expected IllegalArgumentException")
        } catch (e: IllegalArgumentException) {
            // OK
        }
    }

    @Test
    fun rejectsMoreThanMaxSamples() {
        val samples = (0..StylusWire.MAX_SAMPLES).map { StylusWire.Sample(0f, 0f, 0f) }
        try {
            StylusWire.encode(StylusWire.Action.MOVE, samples)
            error("expected IllegalArgumentException")
        } catch (e: IllegalArgumentException) {
            // OK
        }
    }
}
