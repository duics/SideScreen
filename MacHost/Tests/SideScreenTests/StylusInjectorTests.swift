import CoreGraphics
import XCTest
@testable import SideScreen

/// The injector is the only place the pressure a stroke carries can be lost, and
/// it is lost silently — a stroke with flat pressure looks exactly like a stroke
/// on an app that ignores pressure. These tests read the finished event's fields
/// back instead of posting, so they run without Accessibility trust; what an app
/// does with the posted event is device-verified in U6.
final class StylusInjectorTests: XCTestCase {
    /// One 16-bit step of the tablet pressure field.
    private let tabletStep = 1.0 / 65535.0
    /// One 8-bit step of the mouse pressure field.
    private let mouseStep = 1.0 / 255.0

    private let bounds = CGRect(x: 100, y: 200, width: 1000, height: 800)

    private func capture(_ steps: [StylusStep]) -> [CGEvent] {
        var posted: [CGEvent] = []
        let injector = StylusInjector(eventSource: CGEventSource(stateID: .hidSystemState),
                                      post: { posted.append($0) })
        injector.perform(steps, in: bounds, cancelHostGesture: {}, armStaleTimeout: { _ in })
        return posted
    }

    private func sample(_ x: Double, _ y: Double, _ pressure: Double) -> StylusSample {
        StylusSample(x: x, y: y, pressure: pressure)
    }

    // MARK: - R10, KTD12: pressure on both fields

    func testMouseDownCarriesTabletSubtypeAndBothPressureFields() {
        let posted = capture([.mouseDown(sample(0.5, 0.5, 0.5), clickCount: 1)])
        XCTAssertEqual(posted.count, 1)
        guard let event = posted.first else { return }

        XCTAssertEqual(event.type, .leftMouseDown)
        XCTAssertEqual(event.getIntegerValueField(.mouseEventSubtype),
                       StylusInjector.tabletPointSubtype)
        XCTAssertEqual(event.getDoubleValueField(.tabletEventPointPressure), 0.5,
                       accuracy: tabletStep)
        // Asserting only the tablet field would pass while every ordinary Cocoa app
        // read a flat 1.0 from `NSEvent.pressure`.
        XCTAssertEqual(event.getDoubleValueField(.mouseEventPressure), 0.5,
                       accuracy: mouseStep)
    }

    func testEveryStrokeEventTypeCarriesBothPressureFields() {
        let steps: [StylusStep] = [
            .moveCursor(sample(0.2, 0.2, 0.4)),
            .mouseDown(sample(0.2, 0.2, 0.4), clickCount: 1),
            .mouseDragged(sample(0.3, 0.3, 0.4)),
            .mouseUp(sample(0.4, 0.4, 0.4), clickCount: 1)
        ]
        let posted = capture(steps)
        XCTAssertEqual(posted.count, 4)
        for event in posted {
            XCTAssertEqual(event.getIntegerValueField(.mouseEventSubtype),
                           StylusInjector.tabletPointSubtype)
            XCTAssertEqual(event.getDoubleValueField(.tabletEventPointPressure), 0.4,
                           accuracy: tabletStep)
            XCTAssertEqual(event.getDoubleValueField(.mouseEventPressure), 0.4,
                           accuracy: mouseStep)
        }
    }

    // MARK: - R12: a zero is a real zero

    func testZeroPressureStaysZeroOnBothFields() {
        let posted = capture([.mouseUp(sample(0.5, 0.5, 0), clickCount: 1)])
        guard let event = posted.first else { return XCTFail("no event posted") }

        XCTAssertEqual(event.getDoubleValueField(.tabletEventPointPressure), 0)
        XCTAssertEqual(event.getDoubleValueField(.mouseEventPressure), 0)
    }

    // MARK: - KTD1: the 16-bit field is not narrowed in our own path

    func testTwentyFinelySpacedPressuresStayDistinct() {
        // 0.0001 apart — inside one step of an 8-bit field, so anything that routed
        // pressure through the mouse field would collapse these to one value.
        let steps = (0..<20).map { StylusStep.mouseDragged(sample(0.5, 0.5, 0.2 + Double($0) * 0.0001)) }
        let values = Set(capture(steps).map { $0.getDoubleValueField(.tabletEventPointPressure) })

        XCTAssertEqual(values.count, 20)
    }

    func testPressureAboveOneIsClampedRatherThanWrapped() {
        // The device reports up to 2.44; the codec clamps, and so does this.
        let posted = capture([.mouseDragged(StylusSample(x: 0.5, y: 0.5, pressure: 2.44))])
        guard let event = posted.first else { return XCTFail("no event posted") }

        XCTAssertEqual(event.getDoubleValueField(.tabletEventPointPressure), 1.0)
        XCTAssertEqual(event.getDoubleValueField(.mouseEventPressure), 1.0)
    }

    // MARK: - Geometry

    func testNormalizedSamplesMapOntoTheDisplayBounds() {
        let posted = capture([.mouseDragged(sample(0.25, 0.75, 0.5))])
        guard let event = posted.first else { return XCTFail("no event posted") }

        XCTAssertEqual(event.location.x, 100 + 0.25 * 1000, accuracy: 0.5)
        XCTAssertEqual(event.location.y, 200 + 0.75 * 800, accuracy: 0.5)
    }

    // MARK: - R11: proximity brackets the stroke

    func testProximityEventsUseTheProximitySubtypeAndFlagEnterAndExit() {
        let posted = capture([.proximityEnter, .proximityExit])
        XCTAssertEqual(posted.count, 2)
        guard posted.count == 2 else { return }

        for event in posted {
            XCTAssertEqual(event.getIntegerValueField(.mouseEventSubtype),
                           StylusInjector.tabletProximitySubtype)
            XCTAssertEqual(event.getIntegerValueField(.tabletProximityEventPointerType),
                           StylusInjector.penPointerType)
        }
        XCTAssertEqual(posted[0].getIntegerValueField(.tabletProximityEventEnterProximity), 1)
        XCTAssertEqual(posted[1].getIntegerValueField(.tabletProximityEventEnterProximity), 0)
    }

    // MARK: - The proximity event has to describe a real device

    func testProximityEnterAnnouncesANonZeroIdentityAndCapabilityMask() {
        guard let event = capture([.proximityEnter]).first else { return XCTFail("no event posted") }

        // All-zero here is a nameless device that reports nothing — including,
        // via the mask, no pressure, asked immediately before we send pressure.
        XCTAssertNotEqual(event.getIntegerValueField(.tabletProximityEventVendorID), 0)
        XCTAssertNotEqual(event.getIntegerValueField(.tabletProximityEventTabletID), 0)
        XCTAssertNotEqual(event.getIntegerValueField(.tabletProximityEventPointerID), 0)
        XCTAssertNotEqual(event.getIntegerValueField(.tabletProximityEventVendorPointerType), 0)
        XCTAssertNotEqual(event.getIntegerValueField(.tabletProximityEventCapabilityMask), 0)
    }

    func testCapabilityMaskClaimsPressureAndAbsoluteXYAndNothingWeDoNotSend() {
        guard let event = capture([.proximityEnter]).first else { return XCTFail("no event posted") }
        let mask = event.getIntegerValueField(.tabletProximityEventCapabilityMask)

        for claimed in [StylusInjector.capabilityPressure,
                        StylusInjector.capabilityAbsX,
                        StylusInjector.capabilityAbsY,
                        StylusInjector.capabilityDeviceID,
                        StylusInjector.capabilityButtons] {
            XCTAssertEqual(mask & claimed, claimed)
        }
        // Tilt, rotation, tangential pressure and absolute z: the six-byte wire
        // sample carries no such axis, so claiming one would have an app read a
        // constant zero as a measurement.
        for absent: Int64 in [0x0080, 0x0100, 0x0200, 0x0800, 0x1000, 0x2000] {
            XCTAssertEqual(mask & absent, 0)
        }
    }

    // MARK: - R26: a press and its release declare a matching click count

    func testPressAndReleaseCarryTheClickCountThePlannerDecided() {
        let posted = capture([
            .mouseDown(sample(0.5, 0.5, 0.4), clickCount: 2),
            .mouseUp(sample(0.5, 0.5, 0), clickCount: 2)
        ])

        XCTAssertEqual(posted.map { $0.getIntegerValueField(.mouseEventClickState) }, [2, 2])
    }

    func testASingleTapPostsClickStateOneRatherThanZero() {
        let posted = capture([
            .mouseDown(sample(0.5, 0.5, 0.4), clickCount: 1),
            .mouseUp(sample(0.5, 0.5, 0), clickCount: 1)
        ])

        // Zero here is the defect: a Mac control that acts on mouse-up never fires.
        XCTAssertEqual(posted.map { $0.getIntegerValueField(.mouseEventClickState) }, [1, 1])
    }

    // MARK: - Steps the injector does not own

    func testNonEventStepsAreHandedBackAndPostNothing() {
        var cancelled = 0
        var armed: [TimeInterval] = []
        var posted: [CGEvent] = []
        let injector = StylusInjector(eventSource: CGEventSource(stateID: .hidSystemState),
                                      post: { posted.append($0) })

        injector.perform([.cancelHostGesture, .suppressFinger, .armStaleTimeout(after: 0.5)],
                         in: bounds,
                         cancelHostGesture: { cancelled += 1 },
                         armStaleTimeout: { armed.append($0) })

        XCTAssertEqual(cancelled, 1)
        XCTAssertEqual(armed, [0.5])
        XCTAssertTrue(posted.isEmpty)
    }

    func testStepsArePerformedInOrder() {
        let posted = capture([
            .proximityEnter,
            .moveCursor(sample(0.1, 0.1, 0.3)),
            .mouseDown(sample(0.1, 0.1, 0.3), clickCount: 1),
            .mouseUp(sample(0.1, 0.1, 0), clickCount: 1),
            .proximityExit
        ])

        XCTAssertEqual(posted.map { $0.type },
                       [.mouseMoved, .mouseMoved, .leftMouseDown, .leftMouseUp, .mouseMoved])
        XCTAssertEqual(posted.map { $0.getIntegerValueField(.mouseEventSubtype) },
                       [StylusInjector.tabletProximitySubtype,
                        StylusInjector.tabletPointSubtype,
                        StylusInjector.tabletPointSubtype,
                        StylusInjector.tabletPointSubtype,
                        StylusInjector.tabletProximitySubtype])
    }

    func testButtonStateIsSetOnlyWhileTheNibIsDown() {
        let posted = capture([
            .moveCursor(sample(0.1, 0.1, 0.3)),
            .mouseDown(sample(0.1, 0.1, 0.3), clickCount: 1),
            .mouseDragged(sample(0.2, 0.2, 0.3)),
            .mouseUp(sample(0.2, 0.2, 0), clickCount: 1)
        ])

        XCTAssertEqual(posted.map { $0.getIntegerValueField(.tabletEventPointButtons) },
                       [0, 1, 1, 0])
    }
}
