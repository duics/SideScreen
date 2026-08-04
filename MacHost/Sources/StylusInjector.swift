import CoreGraphics
import Foundation

/// Turns `StylusPlanner` steps into posted `CGEvent`s.
///
/// Every stylus event this app posts is built by `makeStylusEvent` below —
/// there is exactly one constructor so KTD7's ordering rule (mouse subtype
/// before any tablet field, or the tablet fields are ignored) is correct by
/// construction rather than by discipline at several call sites. Ordering is
/// not observable on a finished event, so it cannot be asserted by a test; the
/// single call site is what makes it reviewable.
///
/// Steps that are not events — abandoning the finger gesture, arming the
/// staleness timer — are handed back to the caller, which owns the gesture
/// machine and the run loop.
///
/// The post operation is a defaulted parameter, following the defaulted
/// dependencies in `WirelessAuth` and `PairedDeviceStore`, so a test can read
/// final field values back without Accessibility trust and without injecting
/// into the live session.
final class StylusInjector {
    /// `NX_SUBTYPE_TABLET_POINT` and `NX_SUBTYPE_TABLET_PROXIMITY` from IOKit's
    /// `IOLLEvent.h`, which has no Swift overlay.
    static let tabletPointSubtype: Int64 = 1
    static let tabletProximitySubtype: Int64 = 2
    /// `NX_TABLET_POINTER_PEN`.
    static let penPointerType: Int64 = 1
    /// `NX_TABLET_POINTER_ERASER`. Announced on the proximity event rather than
    /// mapped to a click: this is the mechanism drawing apps actually watch to
    /// switch to their eraser tool, and Side Screen has no canvas of its own to
    /// erase on.
    static let eraserPointerType: Int64 = 3
    /// One virtual pen, so a single stable non-zero id. Point and proximity
    /// events must agree on it or an app cannot match a stroke to the pen that
    /// entered proximity.
    static let deviceID: Int64 = 1
    /// Vendor and tablet identity. An all-zero identity reads as "no tablet
    /// here"; these are arbitrary but stable and non-zero, and deliberately not
    /// a real vendor's USB id — this is our virtual pen, not an emulation of
    /// someone's hardware. 0x5343 is "SC".
    static let vendorID: Int64 = 0x5343
    static let tabletID: Int64 = 1
    /// One pointer on that tablet. Zero is the "unknown pointer" value.
    static let pointerID: Int64 = 1
    /// `tabletProximityEventVendorPointerType` is vendor-defined. 0x0022 is the
    /// plain-stylus value in the numbering the field inherited from Wacom's
    /// tablets, which is what apps that switch on it compare against; it says
    /// "an ordinary pen", not an airbrush, puck, or eraser.
    static let vendorPointerTypeStylus: Int64 = 0x0022
    /// The eraser value in the same vendor numbering.
    static let vendorPointerTypeEraser: Int64 = 0x000A
    /// `NX_TABLET_CAPABILITY_*` from IOKit's `IOLLEvent.h`, which has no Swift
    /// overlay. Exactly the axes this injector writes on every point event —
    /// device id, absolute x and y, the button state, and pressure. Tilt,
    /// rotation, tangential pressure and absolute z are deliberately absent: the
    /// wire format carries no such axis (`StylusCodec`'s stride is x, y,
    /// pressure), and claiming one would have an app read a constant zero as a
    /// measurement.
    static let capabilityDeviceID: Int64 = 0x0001
    static let capabilityAbsX: Int64 = 0x0002
    static let capabilityAbsY: Int64 = 0x0004
    static let capabilityButtons: Int64 = 0x0040
    static let capabilityPressure: Int64 = 0x0400
    /// `NSEvent.capabilityMask` is how an app asks whether the pen reports
    /// pressure before it bothers reading any. Answering zero here and then
    /// sending pressure is why R10 could look like it was doing nothing.
    static let capabilityMask: Int64 = capabilityDeviceID | capabilityAbsX | capabilityAbsY
        | capabilityButtons | capabilityPressure
    /// Full scale of the tablet's absolute-position fields. The same 16-bit
    /// scale the wire format uses, so a sample maps across without a second
    /// quantization.
    static let tabletFullScale: Double = 65535

    typealias PostOperation = (CGEvent) -> Void

    private let eventSource: CGEventSource?
    private let post: PostOperation

    init(eventSource: CGEventSource?,
         post: @escaping PostOperation = { $0.post(tap: .cghidEventTap) }) {
        self.eventSource = eventSource
        self.post = post
    }

    /// Performs one planner step list. `bounds` is the virtual display's frame,
    /// used to turn normalized samples into screen points.
    /// `secondary` and `eraser` describe the contact these steps belong to, not
    /// any single step. They are passed alongside rather than carried on each
    /// mouse step for the same reason click count is decided once at the press:
    /// a press and its release that disagreed about which button they were would
    /// be exactly the malformed-click bug `76247b7` fixed.
    func perform(_ steps: [StylusStep],
                 in bounds: CGRect,
                 secondary: Bool = false,
                 eraser: Bool = false,
                 cancelHostGesture: () -> Void,
                 armStaleTimeout: (TimeInterval) -> Void) {
        let down: CGEventType = secondary ? .rightMouseDown : .leftMouseDown
        let dragged: CGEventType = secondary ? .rightMouseDragged : .leftMouseDragged
        let up: CGEventType = secondary ? .rightMouseUp : .leftMouseUp
        let button: CGMouseButton = secondary ? .right : .left
        for step in steps {
            switch step {
            case .cancelHostGesture:
                cancelHostGesture()
            case .proximityEnter:
                postProximity(entering: true, asEraser: eraser)
            case .proximityExit:
                postProximity(entering: false, asEraser: eraser)
            case .moveCursor(let sample):
                postStylus(.mouseMoved, sample, in: bounds, buttonDown: false, button: button)
            case .mouseDown(let sample, let clickCount):
                postStylus(down, sample, in: bounds, buttonDown: true, clickCount: clickCount, button: button)
            case .mouseDragged(let sample):
                postStylus(dragged, sample, in: bounds, buttonDown: true, button: button)
            case .mouseUp(let sample, let clickCount):
                postStylus(up, sample, in: bounds, buttonDown: false, clickCount: clickCount, button: button)
            case .armStaleTimeout(let delay):
                armStaleTimeout(delay)
            case .suppressFinger:
                // Nothing to post: suppression is the absence of a finger
                // event. The host reaches this step from its defensive guard on
                // the touch path, not from a stylus message.
                break
            }
        }
    }

    /// `clickCount` is zero for the events that are not a click — the cursor park
    /// and the drags — and the planner's declared count on the press and its
    /// matching release (R26).
    private func postStylus(_ type: CGEventType,
                            _ sample: StylusSample,
                            in bounds: CGRect,
                            buttonDown: Bool,
                            clickCount: Int = 0,
                            button: CGMouseButton = .left) {
        let point = CGPoint(
            x: bounds.origin.x + CGFloat(sample.x) * bounds.width,
            y: bounds.origin.y + CGFloat(sample.y) * bounds.height
        )
        guard let event = makeStylusEvent(type: type, at: point, button: button) else { return }

        // R26. A press posted without this reads as click 0, and a Mac control
        // that acts on mouse-up never fires.
        if clickCount > 0 {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        }
        event.setIntegerValueField(.tabletEventDeviceID, value: Self.deviceID)
        event.setIntegerValueField(.tabletEventPointButtons, value: buttonDown ? 1 : 0)
        event.setIntegerValueField(.tabletEventPointX,
                                   value: Int64(clampUnit(sample.x) * Self.tabletFullScale))
        event.setIntegerValueField(.tabletEventPointY,
                                   value: Int64(clampUnit(sample.y) * Self.tabletFullScale))

        // KTD12. Both pressure fields, on every event, always. They are
        // different widths — the tablet field carries the full 16 bits, the
        // mouse field is 8. Writing only the tablet field is a silent failure:
        // `NSEvent.pressure`, which ordinary Cocoa apps read, then reports a
        // constant 1.0 and pressure looks like it is working at full force.
        let pressure = clampUnit(sample.pressure)
        event.setDoubleValueField(.tabletEventPointPressure, value: pressure)
        event.setDoubleValueField(.mouseEventPressure, value: pressure)

        post(event)
    }

    /// R11. Proximity brackets the stroke. It is posted at the cursor's current
    /// location rather than at a sample: a proximity event is a mouse-moved
    /// event underneath, so giving it a made-up position would teleport the
    /// cursor there.
    private func postProximity(entering: Bool, asEraser: Bool = false) {
        let location = CGEvent(source: nil)?.location ?? .zero
        guard let event = makeStylusEvent(type: .mouseMoved,
                                          at: location,
                                          subtype: Self.tabletProximitySubtype) else { return }

        event.setIntegerValueField(.tabletProximityEventEnterProximity, value: entering ? 1 : 0)
        event.setIntegerValueField(.tabletProximityEventPointerType,
                                   value: asEraser ? Self.eraserPointerType : Self.penPointerType)
        event.setIntegerValueField(.tabletProximityEventDeviceID, value: Self.deviceID)
        event.setIntegerValueField(.tabletProximityEventSystemTabletID, value: Self.deviceID)
        // The identity an app reads off the proximity event to decide what it is
        // dealing with. Left at zero it describes a nameless device that reports
        // nothing — including, per `capabilityMask`, no pressure, immediately
        // before this injector starts sending pressure.
        event.setIntegerValueField(.tabletProximityEventVendorID, value: Self.vendorID)
        event.setIntegerValueField(.tabletProximityEventTabletID, value: Self.tabletID)
        event.setIntegerValueField(.tabletProximityEventPointerID, value: Self.pointerID)
        event.setIntegerValueField(.tabletProximityEventVendorPointerType,
                                   value: asEraser ? Self.vendorPointerTypeEraser : Self.vendorPointerTypeStylus)
        event.setIntegerValueField(.tabletProximityEventCapabilityMask, value: Self.capabilityMask)

        post(event)
    }

    /// The one place a stylus `CGEvent` is created.
    ///
    /// KTD7: the mouse subtype is the first field written, before any tablet
    /// field. KTD8: a fresh event per post — `CGEvent`'s fields live in a
    /// type-determined union and reuse is the documented cause of undefined
    /// behavior.
    private func makeStylusEvent(type: CGEventType,
                                 at point: CGPoint,
                                 subtype: Int64 = StylusInjector.tabletPointSubtype,
                                 button: CGMouseButton = .left) -> CGEvent? {
        guard let event = CGEvent(mouseEventSource: eventSource,
                                  mouseType: type,
                                  mouseCursorPosition: point,
                                  mouseButton: button) else { return nil }
        event.setIntegerValueField(.mouseEventSubtype, value: subtype)
        return event
    }

    /// The codec already guarantees 0...1, so this is defence against a future
    /// caller rather than against the wire.
    private func clampUnit(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
