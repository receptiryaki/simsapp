import Foundation

/// The simulator's input surface. The infrastructure adapter translates
/// these into private SimulatorKit calls; future tests can substitute
/// a fake.
protocol Input: Sendable {
    /// One-shot tap at a point — down, hold for `duration` (seconds;
    /// 0 picks an infra default of ~50ms), up.
    @discardableResult
    func tap(at point: Point, size: Size, duration: Double) -> Bool

    /// Streaming single-finger touch: caller drives `.down` →
    /// many `.move`s → `.up`. The infra adapter keeps a sticky touch
    /// identifier across the sequence so iOS sees one continuous touch.
    @discardableResult
    func touch1(phase: GesturePhase, at point: Point, size: Size) -> Bool

    /// Two-axis scroll-wheel input. `deltaX` / `deltaY` are in the same
    /// units AppKit gives in `NSEvent.scrollingDeltaX/Y` (logical lines
    /// or pixels depending on the event). Positive `deltaY` scrolls
    /// up (Apple's natural-scrolling convention).
    @discardableResult
    func scroll(deltaX: Double, deltaY: Double) -> Bool

    /// One keystroke with `modifiers` held for the duration of the
    /// keystroke. `duration` is the hold time in seconds; 0 picks an
    /// infra default (~100ms). The adapter brackets: modifiers down
    /// → key down → hold → key up → modifiers up.
    @discardableResult
    func key(_ key: KeyboardKey, modifiers: Set<KeyModifier>, duration: Double) -> Bool

    /// Press-and-release a hardware button. `duration` is the hold
    /// time in seconds (0 → infra default ~100ms). The adapter routes
    /// per case: home goes through the digitizer swipe-from-bottom
    /// recipe; volumeUp / volumeDown go through arbitrary-HID
    /// (page 12).
    @discardableResult
    func button(_ button: DeviceButton, duration: Double) -> Bool
}
