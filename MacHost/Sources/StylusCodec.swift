import Foundation

/// What the client says the pen just did. Unknown values are rejected by
/// `StylusCodec.decode` so a client that adds actions cannot have them misread as
/// draw actions by an un-upgraded host.
///
/// The four contact values are frozen — the golden-byte vectors on both sides pin
/// them — so the hover actions took the next three free values rather than
/// renumbering anything. A hover message carries pressure zero, which is a real
/// zero: the pen is not touching.
enum StylusAction: UInt8 {
    case down = 0
    case move = 1
    case up = 2
    case cancel = 3
    /// One hover position. There is no enter or exit on the wire: proximity is
    /// derived on both sides from when the last hover sample arrived, so a
    /// terminating message is never needed and can never be lost.
    case hover = 4
}

/// One digitizer sample. Coordinates are normalized to the display (0...1);
/// pressure is the digitizer's reported force, normalized and clamped by the
/// client to 0...1. A zero pressure is a real zero — the client resolves
/// "device reports no pressure axis" to full scale before encoding.
struct StylusSample: Equatable {
    let x: Double
    let y: Double
    let pressure: Double
}

struct StylusMessage: Equatable {
    let action: StylusAction
    let samples: [StylusSample]
}

/// Outcome of looking at the head of the input buffer.
enum StylusFraming: Equatable {
    /// A whole message is present; consume exactly this many bytes.
    case complete(length: Int)
    /// The header is plausible but the buffer does not hold the whole message yet.
    case incomplete
    /// The header cannot be a stylus message. The caller resyncs one byte at a
    /// time, the way the touch and decoder-limits cases already do.
    case invalidHeader
}

/// Wire codec for the stylus message (client -> host, type 12).
///
/// Layout, plain big-endian binary:
///   [0] message type (12)
///   [1] action (0 down, 1 move, 2 up, 3 cancel, 4 hover enter, 5 hover move, 6 hover exit)
///   [2] sample format (1 = x, y, pressure)
///   [3] sample count, 1...64
///   [4...] 6 bytes per sample: x uint16, y uint16, pressure uint16
///
/// The six-byte sample stride is fixed. Any additional per-sample axis needs its
/// own message type with its own capability signal, not an extension of this one.
/// `AndroidClient/app/src/main/java/com/sidescreen/app/StylusWire.kt` owns the
/// same layout and both sides carry golden-byte tests against it.
enum StylusCodec {
    static let messageType: UInt8 = 12
    static let sampleFormatXYP: UInt8 = 1
    static let headerSize = 4
    static let sampleStride = 6
    static let maxSamples = 64

    /// Full scale of a quantized unit field.
    static let unitScale: Double = 65535

    /// Largest a whole message can be: header plus the maximum sample count.
    /// A caller framing a byte stream needs to look at no more than this.
    static let maxMessageSize = headerSize + maxSamples * sampleStride

    /// Classifies the head of `data` without consuming anything.
    ///
    /// Three outcomes, because the caller needs to tell "wait for more bytes"
    /// from "this can never become a stylus message" — the first must not
    /// advance the buffer and the second must, or a malformed byte wedges the
    /// input loop forever.
    static func frame(_ data: Data) -> StylusFraming {
        let bytes = [UInt8](data)
        if let type = bytes.first, type != messageType { return .invalidHeader }
        if bytes.count >= 3, bytes[2] != sampleFormatXYP { return .invalidHeader }
        if bytes.count >= 4 {
            let count = Int(bytes[3])
            guard count >= 1 && count <= maxSamples else { return .invalidHeader }
            let total = headerSize + count * sampleStride
            return bytes.count >= total ? .complete(length: total) : .incomplete
        }
        return .incomplete
    }

    /// Decodes exactly one message. `data` must be the whole frame and nothing
    /// else — the length is validated against the declared sample count, per R24.
    ///
    /// Returns nil rather than throwing so the caller can consume the frame and
    /// skip it without disturbing the messages behind it. The host validates
    /// even though the client clamps: a client that does not run our encoder is
    /// not bound by its clamps.
    ///
    /// Decoded values need no separate range check — a uint16 divided by 65535
    /// is within 0...1 by construction, and the fixed stride is enforced above.
    static func decode(_ data: Data) -> StylusMessage? {
        let bytes = [UInt8](data)
        guard bytes.count >= headerSize else { return nil }
        guard bytes[0] == messageType else { return nil }
        guard bytes[2] == sampleFormatXYP else { return nil }
        guard let action = StylusAction(rawValue: bytes[1]) else { return nil }
        let count = Int(bytes[3])
        guard count >= 1 && count <= maxSamples else { return nil }
        guard bytes.count == headerSize + count * sampleStride else { return nil }

        var samples: [StylusSample] = []
        samples.reserveCapacity(count)
        for i in 0..<count {
            let base = headerSize + i * sampleStride
            samples.append(StylusSample(
                x: unit(bytes[base], bytes[base + 1]),
                y: unit(bytes[base + 2], bytes[base + 3]),
                pressure: unit(bytes[base + 4], bytes[base + 5])
            ))
        }
        return StylusMessage(action: action, samples: samples)
    }

    private static func unit(_ hi: UInt8, _ lo: UInt8) -> Double {
        Double((UInt16(hi) << 8) | UInt16(lo)) / unitScale
    }
}
