import XCTest
@testable import SideScreen

final class StylusCodecTests: XCTestCase {
    /// One 16-bit step — the round-trip tolerance for a quantized unit field.
    private let step = 1.0 / StylusCodec.unitScale

    /// The client's encoder, mirrored here so the host side has a round trip to
    /// assert against. Production code on this side only ever decodes; the real
    /// encoder is `StylusWire.encode` in the Android client.
    private func encode(_ action: StylusAction, _ samples: [StylusSample]) -> Data {
        var bytes: [UInt8] = [
            StylusCodec.messageType, action.rawValue, StylusCodec.sampleFormatXYP, UInt8(samples.count)
        ]
        for sample in samples {
            for value in [sample.x, sample.y, sample.pressure] {
                let quantized = UInt16((min(max(value, 0), 1) * StylusCodec.unitScale).rounded())
                bytes.append(UInt8(quantized >> 8))
                bytes.append(UInt8(quantized & 0xFF))
            }
        }
        return Data(bytes)
    }

    // MARK: - Golden bytes

    /// The layout contract. `AndroidClient/app/src/test/java/com/sidescreen/app/StylusWireTest.kt`
    /// asserts the same bytes for the same input — if one side drifts, both fail.
    func testGoldenBytes() {
        let golden: [UInt8] = [
            0x0C, 0x01, 0x01, 0x02,
            0x40, 0x00, 0xBF, 0xFF, 0xFF, 0xFF,
            0x00, 0x00, 0xFF, 0xFF, 0x20, 0x00
        ]
        // The same input the Kotlin golden test encodes.
        let input = [
            StylusSample(x: 0.25, y: 0.75, pressure: 1.0),
            StylusSample(x: 0.0, y: 1.0, pressure: 0.125)
        ]
        XCTAssertEqual(Array(encode(.move, input)), golden)

        let decoded = StylusCodec.decode(Data(golden))
        XCTAssertEqual(decoded?.action, .move)
        XCTAssertEqual(decoded?.samples.count, 2)
        XCTAssertEqual(decoded?.samples[0].x, 16384 / StylusCodec.unitScale)
        XCTAssertEqual(decoded?.samples[0].y, 49151 / StylusCodec.unitScale)
        XCTAssertEqual(decoded?.samples[0].pressure, 1.0)
        XCTAssertEqual(decoded?.samples[1].x, 0.0)
        XCTAssertEqual(decoded?.samples[1].y, 1.0)
        XCTAssertEqual(decoded?.samples[1].pressure, 8192 / StylusCodec.unitScale)
    }

    /// The hover layout contract, mirrored by `encodesGoldenHoverBytes` in
    /// `AndroidClient/app/src/test/java/com/sidescreen/app/StylusWireTest.kt`. A
    /// hover sample is an ordinary sample at a real zero pressure — the pen is not
    /// touching, which is a measurement, not an absent value.
    func testGoldenHoverBytes() throws {
        let golden: [UInt8] = [
            0x0C, 0x04, 0x01, 0x01,
            0x40, 0x00, 0xBF, 0xFF, 0x00, 0x00
        ]
        XCTAssertEqual(Array(encode(.hover, [StylusSample(x: 0.25, y: 0.75, pressure: 0)])), golden)

        let decoded = try XCTUnwrap(StylusCodec.decode(Data(golden)))
        XCTAssertEqual(decoded.action, .hover)
        XCTAssertEqual(decoded.samples.count, 1)
        XCTAssertEqual(decoded.samples[0].x, 16384 / StylusCodec.unitScale)
        XCTAssertEqual(decoded.samples[0].y, 49151 / StylusCodec.unitScale)
        XCTAssertEqual(decoded.samples[0].pressure, 0)
    }

    /// The four contact codes are frozen: every golden vector taken before hover
    /// existed still decodes to the same action.
    func testContactActionCodesAreUnchangedByHover() {
        XCTAssertEqual(StylusAction.down.rawValue, 0)
        XCTAssertEqual(StylusAction.move.rawValue, 1)
        XCTAssertEqual(StylusAction.up.rawValue, 2)
        XCTAssertEqual(StylusAction.cancel.rawValue, 3)
        XCTAssertEqual(StylusAction.hover.rawValue, 4)
    }

    // MARK: - Round trips

    func testRoundTripsThreeSampleMove() throws {
        let samples = [
            StylusSample(x: 0.1234, y: 0.9876, pressure: 0.0153),
            StylusSample(x: 0.5, y: 0.5, pressure: 0.3481),
            StylusSample(x: 0.9999, y: 0.0001, pressure: 0.7)
        ]
        let message = try XCTUnwrap(StylusCodec.decode(encode(.move, samples)))
        XCTAssertEqual(message.action, .move)
        XCTAssertEqual(message.samples.count, 3)
        for (expected, actual) in zip(samples, message.samples) {
            XCTAssertEqual(actual.x, expected.x, accuracy: step)
            XCTAssertEqual(actual.y, expected.y, accuracy: step)
            XCTAssertEqual(actual.pressure, expected.pressure, accuracy: step)
        }
    }

    func testRoundTripsSingleSampleDown() throws {
        let sample = StylusSample(x: 0.4, y: 0.6, pressure: 0.2)
        let data = encode(.down, [sample])
        XCTAssertEqual(data.count, 10)
        let message = try XCTUnwrap(StylusCodec.decode(data))
        XCTAssertEqual(message.action, .down)
        XCTAssertEqual(message.samples.count, 1)
        XCTAssertEqual(message.samples[0].x, sample.x, accuracy: step)
        XCTAssertEqual(message.samples[0].y, sample.y, accuracy: step)
        XCTAssertEqual(message.samples[0].pressure, sample.pressure, accuracy: step)
    }

    func testRoundTripsSixtyFourSampleMove() throws {
        let samples = (0..<StylusCodec.maxSamples).map {
            StylusSample(x: Double($0) / 100, y: 1 - Double($0) / 100, pressure: Double($0) / 64)
        }
        let data = encode(.move, samples)
        XCTAssertEqual(data.count, 388)
        let message = try XCTUnwrap(StylusCodec.decode(data))
        XCTAssertEqual(message.samples.count, 64)
        for (expected, actual) in zip(samples, message.samples) {
            XCTAssertEqual(actual.x, expected.x, accuracy: step)
            XCTAssertEqual(actual.y, expected.y, accuracy: step)
            XCTAssertEqual(actual.pressure, expected.pressure, accuracy: step)
        }
    }

    func testPreservesSampleOrder() throws {
        let samples = [
            StylusSample(x: 0.1, y: 0.1, pressure: 0.1),
            StylusSample(x: 0.2, y: 0.2, pressure: 0.2),
            StylusSample(x: 0.3, y: 0.3, pressure: 0.3)
        ]
        let message = try XCTUnwrap(StylusCodec.decode(encode(.move, samples)))
        XCTAssertEqual(message.samples[0].x, 0.1, accuracy: step)
        XCTAssertEqual(message.samples[1].x, 0.2, accuracy: step)
        XCTAssertEqual(message.samples[2].x, 0.3, accuracy: step)
    }

    /// R9. The device reports pressure above 1.0 — 2.442 observed — so full
    /// scale on the wire decodes to exactly 1.0 and never wraps.
    func testFullScalePressureDecodesToOne() throws {
        let message = try XCTUnwrap(StylusCodec.decode(encode(.move, [StylusSample(x: 0.5, y: 0.5, pressure: 2.44)])))
        XCTAssertEqual(message.samples[0].pressure, 1.0)
    }

    /// R12. A zero on the wire is a real zero, never promoted to full scale —
    /// absence is resolved on the client before encoding.
    func testZeroPressureStaysZero() throws {
        let message = try XCTUnwrap(StylusCodec.decode(encode(.down, [StylusSample(x: 0.25, y: 0.25, pressure: 0)])))
        XCTAssertEqual(message.samples[0].pressure, 0.0)
    }

    func testDecodesEveryAction() throws {
        for action in [StylusAction.down, .move, .up, .cancel, .hover] {
            let message = try XCTUnwrap(StylusCodec.decode(encode(action, [StylusSample(x: 0, y: 0, pressure: 0)])))
            XCTAssertEqual(message.action, action)
        }
    }

    /// Hover rides the same stride and the same framing as a stroke — it is the
    /// core plan's message with new action values, not a second format (KTD1).
    func testRoundTripsBatchedHoverMove() throws {
        let samples = (0..<5).map { StylusSample(x: Double($0) / 10, y: 1 - Double($0) / 10, pressure: 0) }
        let data = encode(.hover, samples)
        XCTAssertEqual(StylusCodec.frame(data), .complete(length: 34))
        let message = try XCTUnwrap(StylusCodec.decode(data))
        XCTAssertEqual(message.action, .hover)
        for (expected, actual) in zip(samples, message.samples) {
            XCTAssertEqual(actual.x, expected.x, accuracy: step)
            XCTAssertEqual(actual.y, expected.y, accuracy: step)
            XCTAssertEqual(actual.pressure, 0)
        }
    }

    /// Decode works on a mid-buffer slice, which is what `processInputBuffer`
    /// hands it once earlier messages have been consumed.
    func testDecodesFromNonZeroBasedSlice() throws {
        let data = encode(.move, [StylusSample(x: 0.5, y: 0.5, pressure: 0.5)])
        var padded = Data([0xFF, 0xFF, 0xFF])
        padded.append(data)
        let message = try XCTUnwrap(StylusCodec.decode(padded[3...]))
        XCTAssertEqual(message.action, .move)
        XCTAssertEqual(message.samples.count, 1)
    }

    // MARK: - Decode rejection (R24)

    func testRejectsTruncatedMessage() {
        let data = encode(.move, [StylusSample(x: 0.5, y: 0.5, pressure: 0.5)])
        for prefix in 0..<data.count {
            XCTAssertNil(StylusCodec.decode(data.prefix(prefix)), "prefix of \(prefix) bytes decoded")
        }
    }

    func testRejectsZeroSampleCount() {
        XCTAssertNil(StylusCodec.decode(Data([0x0C, 0x01, 0x01, 0x00])))
    }

    func testRejectsSampleCountAboveMax() {
        var bytes: [UInt8] = [0x0C, 0x01, 0x01, 65]
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 65 * 6))
        XCTAssertNil(StylusCodec.decode(Data(bytes)))
    }

    func testRejectsCountDisagreeingWithLength() {
        var bytes: [UInt8] = [0x0C, 0x01, 0x01, 3]
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 2 * 6))
        XCTAssertNil(StylusCodec.decode(Data(bytes)))

        var overlong: [UInt8] = [0x0C, 0x01, 0x01, 2]
        overlong.append(contentsOf: [UInt8](repeating: 0, count: 3 * 6))
        XCTAssertNil(StylusCodec.decode(Data(overlong)))
    }

    /// Hover took 4, 5 and 6; anything above them is still unknown, and a client
    /// that invents one must not have it read as a draw action.
    func testRejectsUnknownAction() {
        for action: UInt8 in [7, 8, 0x7F, 0xFF] {
            var bytes: [UInt8] = [0x0C, action, 0x01, 1]
            bytes.append(contentsOf: [UInt8](repeating: 0, count: 6))
            XCTAssertNil(StylusCodec.decode(Data(bytes)), "action \(action) decoded")
        }
    }

    func testRejectsWrongMessageTypeOrFormat() {
        var wrongType: [UInt8] = [0x02, 0x01, 0x01, 1]
        wrongType.append(contentsOf: [UInt8](repeating: 0, count: 6))
        XCTAssertNil(StylusCodec.decode(Data(wrongType)))

        var wrongFormat: [UInt8] = [0x0C, 0x01, 0x02, 1]
        wrongFormat.append(contentsOf: [UInt8](repeating: 0, count: 6))
        XCTAssertNil(StylusCodec.decode(Data(wrongFormat)))
    }

    // MARK: - Framing (R24)

    func testFramingReportsIncompleteForEveryPrefixAndLengthOnTheLastByte() {
        let data = encode(.move, [
            StylusSample(x: 0.1, y: 0.2, pressure: 0.3),
            StylusSample(x: 0.4, y: 0.5, pressure: 0.6),
            StylusSample(x: 0.7, y: 0.8, pressure: 0.9)
        ])
        XCTAssertEqual(data.count, 22)
        for prefix in 0..<data.count {
            XCTAssertEqual(StylusCodec.frame(data.prefix(prefix)), .incomplete, "prefix of \(prefix) bytes")
        }
        XCTAssertEqual(StylusCodec.frame(data), .complete(length: 22))
    }

    /// A coalesced read must yield the stylus frame's length exactly, leaving the
    /// ping byte behind it untouched.
    func testFramingLeavesTrailingPingUnconsumed() {
        let samples = (0..<5).map { StylusSample(x: Double($0) / 10, y: 0.5, pressure: 0.5) }
        var data = encode(.move, samples)
        XCTAssertEqual(data.count, 34)
        data.append(4)  // WireMessage.ping
        XCTAssertEqual(StylusCodec.frame(data), .complete(length: 34))
    }

    func testFramingRejectsZeroCountDistinctFromIncomplete() {
        XCTAssertEqual(StylusCodec.frame(Data([0x0C, 0x01, 0x01, 0x00])), .invalidHeader)
    }

    func testFramingRejectsCountAboveMax() {
        XCTAssertEqual(StylusCodec.frame(Data([0x0C, 0x01, 0x01, 65])), .invalidHeader)
        XCTAssertEqual(StylusCodec.frame(Data([0x0C, 0x01, 0x01, 0xFF])), .invalidHeader)
    }

    func testFramingRejectsWrongTypeOrFormat() {
        XCTAssertEqual(StylusCodec.frame(Data([0x02, 0x01, 0x01, 0x01])), .invalidHeader)
        XCTAssertEqual(StylusCodec.frame(Data([0x02])), .invalidHeader)
        XCTAssertEqual(StylusCodec.frame(Data([0x0C, 0x01, 0x02, 0x01])), .invalidHeader)
    }

    func testFramingOnEmptyBufferIsIncomplete() {
        XCTAssertEqual(StylusCodec.frame(Data()), .incomplete)
    }

    /// An unknown action is a decode rejection, not a framing one — the frame is
    /// still consumed whole, so the messages behind it stay aligned.
    func testFramingAcceptsUnknownActionSoTheFrameIsConsumed() {
        var bytes: [UInt8] = [0x0C, 0x07, 0x01, 1]
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 6))
        XCTAssertEqual(StylusCodec.frame(Data(bytes)), .complete(length: 10))
        XCTAssertNil(StylusCodec.decode(Data(bytes)))
    }
}
