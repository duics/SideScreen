package com.sidescreen.app

/**
 * Wire codec for the stylus message (client -> host, type 12).
 *
 * Layout, plain big-endian binary:
 *   [0] message type (12)
 *   [1] action (0 down, 1 move, 2 up, 3 cancel, 4 hover enter, 5 hover move, 6 hover exit)
 *   [2] sample format (1 = x, y, pressure)
 *   [3] sample count, 1..64
 *   [4...] 6 bytes per sample: x uint16, y uint16, pressure uint16
 *
 * The six-byte sample stride is fixed. Any additional per-sample axis (tilt,
 * orientation, hover distance) needs its own message type with its own
 * capability signal, not an extension of this one. `MacHost/Sources/StylusCodec.swift`
 * owns the same layout and both sides carry golden-byte tests against it.
 */
object StylusWire {
    const val MESSAGE_TYPE = 12
    const val SAMPLE_FORMAT_XYP = 1
    const val HEADER_SIZE = 4
    const val SAMPLE_SIZE = 6
    const val MAX_SAMPLES = 64

    /** Full scale of a quantized unit field. Pressure of 1.0 encodes to this. */
    const val UNIT_SCALE = 65535

    /**
     * The four contact actions are the core plan's and their codes are frozen —
     * the golden-byte vectors on both sides pin them. Hover took the next three
     * free values rather than renumbering anything, so an old vector still holds
     * and an un-upgraded host rejects a hover action outright instead of reading
     * it as a draw action.
     */
    enum class Action(val code: Int) {
        DOWN(0),
        MOVE(1),
        UP(2),
        CANCEL(3),

        /**
         * One hover position. There is no enter or exit on the wire: proximity is
         * derived on both sides from when the last hover sample arrived, so a
         * terminating message is never needed and can never be lost.
         */
        HOVER(4),
    }

    /**
     * One digitizer sample. Coordinates are normalized to the display (0..1);
     * pressure is the digitizer's reported force, also normalized to 0..1.
     *
     * Pressure absence is resolved before this point — the caller substitutes
     * full scale when the device reports no pressure axis — so a zero here
     * always means a real zero pressure. A hover sample carries zero for that
     * reason: the pen is not touching, which is a measured zero, not an absent
     * value.
     */
    data class Sample(
        val x: Float,
        val y: Float,
        val pressure: Float,
    )

    /**
     * Quantize a normalized 0..1 value to a 16-bit field, clamping out of range
     * input. Samsung reports pressure above 1.0 (2.44 observed), so the clamp is
     * required rather than defensive: without it the value wraps.
     */
    fun quantizeUnit(value: Float): Int {
        if (value.isNaN()) return 0
        val clamped = value.coerceIn(0f, 1f)
        return Math.round(clamped * UNIT_SCALE)
    }

    /** Inverse of [quantizeUnit], for the host-agreeing round trip. */
    fun dequantizeUnit(raw: Int): Float = raw.toFloat() / UNIT_SCALE

    /**
     * Encode one stylus message. Throws if the sample count is outside 1..64 —
     * a caller that batches more than the cap must split, because the host
     * rejects an over-count message outright.
     */
    fun encode(
        action: Action,
        samples: List<Sample>,
    ): ByteArray {
        require(samples.size in 1..MAX_SAMPLES) {
            "sample count must be 1..$MAX_SAMPLES, got ${samples.size}"
        }
        val out = ByteArray(HEADER_SIZE + samples.size * SAMPLE_SIZE)
        out[0] = MESSAGE_TYPE.toByte()
        out[1] = action.code.toByte()
        out[2] = SAMPLE_FORMAT_XYP.toByte()
        out[3] = samples.size.toByte()
        var offset = HEADER_SIZE
        for (sample in samples) {
            offset = putUInt16(out, offset, quantizeUnit(sample.x))
            offset = putUInt16(out, offset, quantizeUnit(sample.y))
            offset = putUInt16(out, offset, quantizeUnit(sample.pressure))
        }
        return out
    }

    private fun putUInt16(
        out: ByteArray,
        offset: Int,
        value: Int,
    ): Int {
        out[offset] = ((value ushr 8) and 0xFF).toByte()
        out[offset + 1] = (value and 0xFF).toByte()
        return offset + 2
    }
}
