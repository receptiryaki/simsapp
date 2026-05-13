import Cocoa
import IOSurface

/// Layer-backed view whose `CALayer.contents` IS the simulator's
/// `IOSurface`. Captures mouse / scroll / key events and forwards them
/// to the attached `Input`. Must be touched on the main thread; the
/// HID dispatch itself hops to a private serial queue so a slow
/// SimDeviceLegacyHIDClient warmup doesn't lag the main run loop.
@MainActor
final class StreamView: NSView {

    /// Background-priority serial queue for HID dispatch. Serial so
    /// down→move→up reach iOS in order; async so blocking syscalls in
    /// the HID adapter (dlopen, usleep) don't stall the event loop.
    private let inputQueue = DispatchQueue(label: "sims.input", qos: .userInteractive)
    private var input: (any Input)?

    /// Dimensions of the most recent IOSurface we received. Drives the
    /// letterbox-aware tap normalisation in `mapToImage(local:)`. In
    /// pixels (IOSurfaceGetWidth/Height), but only the aspect ratio
    /// matters for the math.
    private var lastSurfaceSize: CGSize = .zero

    /// Tracks whether the current mouse-down began on top of the image.
    /// `.move` / `.up` only fire when a sequence is active, so clicks in
    /// the letterbox bars don't produce orphan touches inside iOS.
    private var inSequence = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func commonInit() {
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        if let layer = self.layer {
            layer.contentsGravity = .resizeAspect      // letterbox/pillar as needed
            // Dark gray (not pure black) so the letterbox bars stay
            // clearly distinguishable from iOS content that itself
            // often uses black status-bar / safe-area regions.
            layer.backgroundColor = NSColor(white: 0.18, alpha: 1.0).cgColor
            layer.masksToBounds = true
        }
    }

    /// Top-left origin matches iOS conventions; AppKit defaults to
    /// bottom-left, so flipping here saves a y-flip at every event.
    override var isFlipped: Bool { true }

    /// True so the view can receive keyDown / keyUp.
    override var acceptsFirstResponder: Bool { true }

    func attachInput(_ input: any Input) {
        self.input = input
    }

    func display(_ surface: IOSurface) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = surface
        CATransaction.commit()
        // Cache the surface dimensions for the tap-coord math.
        lastSurfaceSize = CGSize(
            width: CGFloat(IOSurfaceGetWidth(surface)),
            height: CGFloat(IOSurfaceGetHeight(surface))
        )
    }

    // MARK: mouse → touch1

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dispatchTouch(event: event, phase: .down)
    }

    override func mouseDragged(with event: NSEvent) {
        dispatchTouch(event: event, phase: .move)
    }

    override func mouseUp(with event: NSEvent) {
        dispatchTouch(event: event, phase: .up)
    }

    private func dispatchTouch(event: NSEvent, phase: GesturePhase) {
        guard let input else { return }
        let local = convert(event.locationInWindow, from: nil)
        let (point, size, withinImage) = mapToImage(local: local)

        switch phase {
        case .down:
            // Drop clicks that started in a letterbox bar — iOS sees no
            // touch begin, so subsequent moves / ups are also dropped.
            guard withinImage else { return }
            inSequence = true
        case .move, .up:
            // Forward only if a `.down` was previously accepted. A drag
            // that ends outside the image still terminates correctly
            // because `mapToImage` clamps the point to the image edge.
            guard inSequence else { return }
        }
        if phase == .up { inSequence = false }

        inputQueue.async {
            _ = input.touch1(phase: phase, at: point, size: size)
        }
    }

    /// Project a view-local point into image-local coordinates, given
    /// the IOSurface's aspect-fit rect inside `bounds`. Returns the
    /// point + image size + whether the original point was inside the
    /// image rect (false → letterbox/pillarbox bar). The point itself
    /// is clamped to the image rect so `.move`/`.up` events that drift
    /// off the image still complete the touch at the nearest edge.
    private func mapToImage(local: CGPoint) -> (Point, Size, Bool) {
        // No frame yet — fall back to view-bounds normalisation so the
        // first events on a fresh stream don't disappear if we beat the
        // framebuffer callback.
        guard lastSurfaceSize.width > 0, lastSurfaceSize.height > 0 else {
            return (
                Point(x: Double(local.x), y: Double(local.y)),
                Size(width: Double(bounds.width), height: Double(bounds.height)),
                true
            )
        }

        let scale = min(
            bounds.width / lastSurfaceSize.width,
            bounds.height / lastSurfaceSize.height
        )
        let dispW = lastSurfaceSize.width * scale
        let dispH = lastSurfaceSize.height * scale
        let dispX = (bounds.width - dispW) / 2
        let dispY = (bounds.height - dispH) / 2

        let rx = local.x - dispX
        let ry = local.y - dispY
        let inside = rx >= 0 && rx <= dispW && ry >= 0 && ry <= dispH
        let cx = min(max(rx, 0), dispW)
        let cy = min(max(ry, 0), dispH)
        return (
            Point(x: Double(cx), y: Double(cy)),
            Size(width: Double(dispW), height: Double(dispH)),
            inside
        )
    }

    // MARK: scroll wheel

    override func scrollWheel(with event: NSEvent) {
        guard let input else { return }
        // `scrollingDeltaX/Y` is what iOS scrollers expect — already
        // accounts for natural-scrolling direction.
        let dx = Double(event.scrollingDeltaX)
        let dy = Double(event.scrollingDeltaY)
        inputQueue.async {
            _ = input.scroll(deltaX: dx, deltaY: dy)
        }
    }

    // MARK: keyboard

    override func keyDown(with event: NSEvent) {
        guard let input,
              let key = KeyboardKey.fromNSEvent(event)
        else {
            super.keyDown(with: event)
            return
        }
        let modifiers = Set<KeyModifier>.fromNSEventFlags(event.modifierFlags)
        inputQueue.async {
            _ = input.key(key, modifiers: modifiers, duration: 0)
        }
    }

    /// Suppress AppKit's funk beep when the view doesn't itself act
    /// on a keystroke — every keystroke goes through `keyDown`, which
    /// either dispatches into the simulator or falls through to
    /// `super.keyDown`. We never want the beep.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Only swallow plain text keys; let menu shortcuts (Cmd-Q,
        // Cmd-W, etc.) flow through to the responder chain.
        if event.modifierFlags.intersection([.command]).isEmpty == false {
            return false
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - NSEvent → Domain translation

private extension KeyboardKey {
    static func fromNSEvent(_ event: NSEvent) -> KeyboardKey? {
        // Special keys keyed by virtual keycode (stable across layouts).
        // Values are Apple's kVK_* — `kVK_Return`, `kVK_Delete`, etc.
        switch Int(event.keyCode) {
        case 0x24: return .return
        case 0x33: return .backspace
        case 0x30: return .tab
        case 0x31: return .space
        case 0x35: return .escape
        case 0x7B: return .arrowLeft
        case 0x7C: return .arrowRight
        case 0x7D: return .arrowDown
        case 0x7E: return .arrowUp
        default: break
        }
        // Printable keys by character. Lowercased so Shift+A still
        // maps to .keyA (the modifier rides separately through
        // `fromNSEventFlags`). US-layout assumption.
        guard let chars = event.charactersIgnoringModifiers?.lowercased(),
              let first = chars.first else { return nil }
        switch first {
        case "a": return .keyA;  case "b": return .keyB;  case "c": return .keyC
        case "d": return .keyD;  case "e": return .keyE;  case "f": return .keyF
        case "g": return .keyG;  case "h": return .keyH;  case "i": return .keyI
        case "j": return .keyJ;  case "k": return .keyK;  case "l": return .keyL
        case "m": return .keyM;  case "n": return .keyN;  case "o": return .keyO
        case "p": return .keyP;  case "q": return .keyQ;  case "r": return .keyR
        case "s": return .keyS;  case "t": return .keyT;  case "u": return .keyU
        case "v": return .keyV;  case "w": return .keyW;  case "x": return .keyX
        case "y": return .keyY;  case "z": return .keyZ
        case "0": return .digit0; case "1": return .digit1; case "2": return .digit2
        case "3": return .digit3; case "4": return .digit4; case "5": return .digit5
        case "6": return .digit6; case "7": return .digit7; case "8": return .digit8
        case "9": return .digit9
        case "-":  return .minus
        case "=":  return .equal
        case "[":  return .bracketLeft
        case "]":  return .bracketRight
        case "\\": return .backslash
        case ";":  return .semicolon
        case "'":  return .quote
        case "`":  return .backquote
        case ",":  return .comma
        case ".":  return .period
        case "/":  return .slash
        default: return nil
        }
    }
}

private extension Set where Element == KeyModifier {
    static func fromNSEventFlags(_ flags: NSEvent.ModifierFlags) -> Set<KeyModifier> {
        var set: Set<KeyModifier> = []
        if flags.contains(.shift)   { set.insert(.shift) }
        if flags.contains(.control) { set.insert(.control) }
        if flags.contains(.option)  { set.insert(.option) }
        if flags.contains(.command) { set.insert(.command) }
        return set
    }
}
