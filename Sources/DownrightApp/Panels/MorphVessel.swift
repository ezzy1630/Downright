import AppKit
import MarkdownRender

/// A travelling glass body: the surface that carries a control's arrival
/// into a docked panel (Layer 2 + Layer 3 of the motion spec).
///
/// The vessel is *glass that travels*: on macOS 26 it is a real
/// `NSGlassEffectView` sampling the live window — never a snapshot — and
/// before that it wears the app's vibrancy material.  It morphs by *frame*,
/// never `transform.scale` (contents must reflow, not distort), its corner
/// radius and tint ride their own springs, and the destination content lands
/// through `Motion.MorphCut` windows so no reader ever watches two
/// full-resolution surfaces crossfade.
@MainActor
final class MorphVessel: Motion.SpringSurfaceView {
    /// The trip this vessel is flying right now.
    struct Trip {
        var from: Motion.MorphAnchor
        var to: Motion.MorphAnchor
        /// The destination's content — faded in through the incoming cut window.
        weak var incomingContent: NSView?
        /// The source's content — faded out through the outgoing cut window.
        weak var outgoingContent: NSView?
        /// Fired once, the frame progress crosses `Motion.MorphCut.handoff`:
        /// the outgoing content is gone and the vessel is empty glass, so the
        /// container may rearrange without any read text moving under the eye.
        var onHandoff: (() -> Void)?
        /// Fired once, on the frame the vessel settles.
        var onSettle: (() -> Void)?
    }

    private var trip: Trip?
    private var settled = false
    private var handedOff = false
    /// What `springTick` last reported, so `springApply` can settle on "every
    /// spring has stopped" rather than on progress alone.  Progress and
    /// geometry no longer co-settle — the geometry springs cap their settle
    /// band absolutely, so a long trip keeps moving after progress reads 1 —
    /// and landing on progress would tear the vessel out mid-glide.
    private var isMoving = false

    private var rect = Motion.SpringRect(perceptualDuration: Motion.springDeliberate)
    private var radius = Motion.SpringScalar(perceptualDuration: Motion.springDeliberate)
    private var tint = Motion.SpringColor(perceptualDuration: Motion.springDeliberate)
    /// 0 at the source, 1 at the destination.  The cut windows live on this
    /// one spring, so interruption only ever retargets a single clock.
    private var progress = Motion.SpringScalar(perceptualDuration: Motion.springDeliberate)

    private var materialView: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Material

    /// The glass underneath.  Created once per lifetime so the same body can
    /// sail out and back; the driver and the material are separate concerns.
    private func installMaterial() {
        guard materialView == nil else { return }
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 0
            glass.tintColor = nil
            addMaterial(glass)
        } else {
            let vibrancy = NSVisualEffectView()
            vibrancy.material = .sidebar
            vibrancy.blendingMode = .withinWindow
            vibrancy.state = .followsWindowActiveState
            addMaterial(vibrancy)
        }
    }

    private func addMaterial(_ material: NSView) {
        material.autoresizingMask = [.width, .height]
        material.frame = bounds
        addSubview(material)
        materialView = material
    }

    // MARK: - Sailing

    /// Launch from the source anchor toward the destination anchor.  Both are
    /// in *window space* — the vessel re-bases them into its own superview
    /// before the springs take them over.
    func fly(_ trip: Trip, window: NSWindow) {
        // A body already in the air must never restart from the new source:
        // toggling the panel twice quickly would teleport the glass to the
        // pane and then fly it home from there.  Interruption is retargeting.
        let wasFlying = self.trip != nil && springsAreRunning
        releaseContent(of: self.trip, excluding: trip)
        self.trip = trip
        installMaterial()

        let host = superview ?? window.contentView ?? self
        let fromRect = host.convert(trip.from.frame, from: nil)
        let toRect = host.convert(trip.to.frame, from: nil)

        if !wasFlying {
            rect.snap(to: fromRect)
            radius.snap(to: trip.from.cornerRadius)
            tint.snap(to: trip.from.tint ?? .clear)
        }
        // The cut clock restarts even on a reversal: the roles of the two
        // contents have swapped, so their windows have to start over.  Only
        // the geometry carries its state across.
        progress.snap(to: 0)

        rect.target(toRect)
        radius.target(trip.to.cornerRadius)
        tint.target(trip.to.tint ?? .clear)
        progress.target(1)

        settled = false
        handedOff = false
        isMoving = true
        // Apply the p = 0 cut *now*, not on the first tick.  The destination
        // panel is installed and laid out before the trip launches, so a frame
        // can be drawn between here and the display link's first callback —
        // and that frame would show the finished panel at full opacity, an
        // instant of the destination before the journey to it.
        applyContentCut(at: 0)
        // A trip that cannot be flown must still *arrive*.  `onHandoff` and
        // `onSettle` are not decoration — they are what gives the pane its
        // width back and hands the host its own transitions again — so a
        // vessel that never ticks would leave the inspector open forever with
        // the morph still nominally in charge.
        //
        // Having a window is not enough to be sure of a tick: a display link
        // is driven by a *screen*, so an offscreen or unordered window arms
        // happily and then never fires. Ask whether this window can actually
        // draw, not merely whether it exists.
        guard window.isVisible, window.screen != nil, armSprings() else {
            springsSettleImmediately()
            return
        }
    }

    /// Re-aim the destination mid-flight.  Interruption is retargeting: the
    /// body never stops and restarts, it just takes the new bearing.
    func retarget(to anchor: Motion.MorphAnchor, window: NSWindow) {
        let host = superview ?? window.contentView ?? self
        rect.target(host.convert(anchor.frame, from: nil))
        radius.target(anchor.cornerRadius)
        tint.target(anchor.tint ?? .clear)
    }

    // MARK: - SpringSurfaceView

    override func springTick(dt: CGFloat) -> Bool {
        let rectMoving = rect.advance(dt: dt)
        let radiusMoving = radius.advance(dt: dt)
        let tintMoving = tint.advance(dt: dt)
        let progressMoving = progress.advance(dt: dt)
        isMoving = rectMoving || radiusMoving || tintMoving || progressMoving
        return isMoving
    }

    override func springApply() {
        frame = rect.rect
        if let materialView {
            if #available(macOS 26.0, *) {
                (materialView as? NSGlassEffectView)?.cornerRadius = radius.value
                (materialView as? NSGlassEffectView)?.tintColor = tint.value
            } else {
                layer?.cornerRadius = radius.value
            }
        }

        guard trip != nil else { return }
        applyContentCut(at: progress.value)

        if !handedOff, progress.value >= Motion.MorphCut.handoff {
            handedOff = true
            trip?.onHandoff?()
        }
        // Land on "everything has stopped", never on progress alone.
        guard !settled, !isMoving else { return }
        settled = true
        let landing = trip
        trip = nil
        landing?.onSettle?()
        // The callback has just pulled the outgoing content out of the
        // hierarchy; give both views their opacity back so a surface that
        // travelled once is reusable by a path that never morphs.  Without
        // this a panel dismissed through the vessel stays at alpha 0 and
        // reopening it under Reduce Motion shows an empty pane.
        releaseContent(of: landing, excluding: nil)
    }

    /// A resize mid-flight ends the journey rather than pausing it.  A parked
    /// vessel would strand its trip: `onSettle` is what hands the pane back to
    /// its own transitions and tears the glass down, so never firing it leaves
    /// the panel half-faded and the host permanently in morph mode.
    override func springsSettleImmediately() {
        guard trip != nil else { return }
        rect.snap(to: rect.target)
        radius.snap(to: radius.target)
        progress.snap(to: 1)
        isMoving = false
        springApply()
    }

    private func applyContentCut(at p: CGFloat) {
        trip?.incomingContent?.alphaValue = Motion.MorphCut.incoming(p)
        trip?.outgoingContent?.alphaValue = Motion.MorphCut.outgoing(p)
    }

    /// Hand a finished (or abandoned) trip's views back at full opacity.
    /// Views that the replacement trip still uses are left alone — it owns
    /// their cut now.
    private func releaseContent(of trip: Trip?, excluding replacement: Trip?) {
        guard let trip else { return }
        for view in [trip.incomingContent, trip.outgoingContent].compactMap({ $0 }) {
            if view === replacement?.incomingContent || view === replacement?.outgoingContent {
                continue
            }
            view.alphaValue = 1
        }
    }
}