import AppKit
import MarkdownRender

/// Whether the two-finger swipe can afford to drag the *next* presentation in
/// under the fingers, for the document currently in front of the reader.
///
/// It is a question about this document on this machine, not a constant.
/// Source has to be rendered before it can be dragged, and that rebuild is
/// proportional to document length: measured on Apple silicon in release, a
/// hundred lines costs single-digit milliseconds and four thousand costs a
/// fifth of a second.  Below the budget the reader gets the real thing; above
/// it they get the page's give, which promises less and always answers.
///
/// Both are smooth.  What is never acceptable is the third option — engaging
/// the drag and then stalling — which is what the first version of this
/// gesture did, and what the budget exists to prevent.
@MainActor
enum PresentationSwitchBudget {
    /// Three frames at 60 Hz.  Past that, the hand notices that the surface
    /// has stopped answering, and a gesture that stops answering at the moment
    /// it catches is worse than one that never promised to.
    static let engagement: Double = 50

    /// What the drag pays regardless of document length: one half-resolution
    /// still of the outgoing page, and the layout pass the switch leaves
    /// behind.  Measured at ~3 ms and ~8 ms respectively, rounded up.
    static let fixedCost: Double = 14

    /// Seeded from a release-build sweep — ~0.03 ms per line of the document,
    /// consistent from four hundred lines to nine thousand — and refined by
    /// every switch the app actually performs, because a constant calibrated
    /// on one Mac is wrong on the next, and wrong in the direction that
    /// matters: a slower machine would otherwise keep promising a drag it
    /// cannot deliver.
    ///
    /// Lines here means lines of the file, which is what `lineStarts` counts —
    /// not paragraphs, and not the line count of some corpus the number was
    /// first measured against. Getting that wrong once already made this
    /// refuse documents it could comfortably have dragged.
    private(set) static var millisecondsPerLine: Double = 0.030

    /// Fold a real switch into the estimate.  Short documents are ignored:
    /// their cost is mostly the fixed overhead, so dividing it by a small line
    /// count produces a per-line figure that describes nothing.
    static func record(cost: Double, lines: Int) {
        guard lines >= 200, cost > 0, cost.isFinite else { return }
        let sample = cost / Double(lines)
        millisecondsPerLine = millisecondsPerLine * 0.7 + sample * 0.3
    }

    static func estimatedCost(lines: Int) -> Double {
        fixedCost + millisecondsPerLine * Double(max(0, lines))
    }

    static func allowsDrag(lines: Int) -> Bool {
        estimatedCost(lines: lines) <= engagement
    }

    /// Test seam: the estimate is process-wide state, so a test that pushes it
    /// has to be able to put it back.
    static func resetCalibrationForTesting(millisecondsPerLine value: Double = 0.030) {
        millisecondsPerLine = value
    }
}

// MARK: - One pane

/// One pane's drag: the presentation being left, as a still, travelling over
/// the live surface that has already become the presentation being entered.
///
/// Only one still, not two.  The incoming side does not need capturing because
/// it is the real text view — the mode change happens behind the still at the
/// top of the gesture, so by the time the reader has moved a finger the live
/// surface underneath is already showing what they are pulling in.
///
/// The still is captured at half resolution through `CALayer.render`, which
/// composites what is already rasterised rather than re-running TextKit:
/// 3 ms against 30 ms for a full-resolution `cacheDisplay`.  It is the page
/// *leaving* the screen, in motion, for a fifth of a second.
@MainActor
final class PaneDrag {
    private(set) weak var pane: MarkdownContainerView?
    private let still = CALayer()
    private let wasMasking: Bool
    let width: CGFloat

    /// Half.  A quarter measured barely faster and starts to show on text.
    private static let stillScale: CGFloat = 0.5

    init?(pane: MarkdownContainerView) {
        guard pane.bounds.width > 1, pane.bounds.height > 1 else { return nil }
        pane.wantsLayer = true
        pane.scrollView.wantsLayer = true
        guard let paneLayer = pane.layer,
              let scrollLayer = pane.scrollView.layer,
              let image = PaneDrag.still(of: pane.scrollView, scale: PaneDrag.stillScale)
        else { return nil }

        self.pane = pane
        width = pane.scrollView.bounds.width
        wasMasking = paneLayer.masksToBounds
        paneLayer.masksToBounds = true

        still.contents = image
        still.contentsGravity = .resize
        still.frame = pane.scrollView.frame
        // Opaque, because the live surface underneath has already changed mode
        // and must not show through the page that is still covering it.
        still.isOpaque = true
        still.backgroundColor = pane.styleSheet.background.cgColor
        still.zPosition = scrollLayer.zPosition + 1
        paneLayer.addSublayer(still)
    }

    /// `translation` is where the outgoing page has travelled; `direction` is
    /// its sign, so the incoming surface can be placed exactly one pane away
    /// and the two tile with no seam.
    func place(translation: CGFloat, direction: CGFloat) {
        guard let scrollLayer = pane?.scrollView.layer else { return }
        let travel = min(max(translation, -width), width)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        still.transform = CATransform3DMakeTranslation(travel, 0, 0)
        scrollLayer.transform = CATransform3DMakeTranslation(travel - direction * width, 0, 0)
        CATransaction.commit()
    }

    func release() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        still.removeFromSuperlayer()
        pane?.scrollView.layer?.transform = CATransform3DIdentity
        pane?.layer?.masksToBounds = wasMasking
        CATransaction.commit()
    }

    /// `NSGraphicsContext` rather than a bare `CGContext`: AppKit owns the
    /// flipped-geometry convention these layers were built under, and going
    /// through it is what keeps the still the right way up.
    private static func still(of view: NSView, scale: CGFloat) -> CGImage? {
        guard let layer = view.layer else { return nil }
        let pixelsWide = Int((view.bounds.width * scale).rounded())
        let pixelsHigh = Int((view.bounds.height * scale).rounded())
        guard pixelsWide > 1, pixelsHigh > 1,
              let representation = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: representation)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        layer.render(in: context.cgContext)
        return representation.cgImage
    }
}

// MARK: - Every pane

/// Every pane's drag at once, plus the spring that finishes it.
///
/// Mirrors `PaneGiveTrack` deliberately: the two are alternatives chosen by
/// budget, and a coordinator should be able to drive either without caring
/// which it got.
@MainActor
final class PaneDragTrack {
    private var surfaces: [PaneDrag] = []
    private var driver: Motion.SpringDriver?
    /// Critically damped.  An overshoot here does not read as bounce, it reads
    /// as a sliver of the wrong page arriving from the opposite edge.
    private var offset = Motion.SpringScalar(
        value: 0,
        perceptualDuration: Motion.springStandard
    )
    private var direction: CGFloat = 1
    private var landing: (() -> Void)?
    private var pendingLanding = false

    deinit { driver?.park() }

    private(set) var isSettling = false
    var isEngaged: Bool { !surfaces.isEmpty }

    /// The travel a completed drag ends on: the widest pane, so a narrower one
    /// clamps to its own edge rather than stopping short of it.
    private var completedTravel: CGFloat {
        direction * (surfaces.map(\.width).max() ?? 0)
    }

    /// Capture every pane and take hold.  Returns `false` if no pane could be
    /// captured, in which case the caller must fall back to the give — the
    /// stills are the whole mechanism and there is no drag without them.
    @discardableResult
    func engage(_ panes: [MarkdownContainerView], direction: CGFloat) -> Bool {
        release()
        self.direction = direction < 0 ? -1 : 1
        surfaces = panes.compactMap(PaneDrag.init(pane:))
        offset.snap(to: 0)
        return !surfaces.isEmpty
    }

    func place(_ value: CGFloat) {
        offset.snap(to: value)
        for surface in surfaces { surface.place(translation: value, direction: direction) }
    }

    /// Finish the drag: `committed` flies the outgoing page all the way off and
    /// leaves the live surface at rest, otherwise it comes home.  `completion`
    /// runs once the panes have arrived, and is where the caller undoes a mode
    /// change it made speculatively.
    func settle(committed: Bool, velocity: CGFloat, completion: @escaping () -> Void) {
        guard !surfaces.isEmpty else {
            completion()
            return
        }
        isSettling = true
        landing = completion
        let destination = committed ? completedTravel : 0
        offset.target(destination)
        // Carry the hand's speed, but only when it already points at the
        // destination: a kick the other way pushes even a critically damped
        // spring past its landing, and past the landing is the wrong page.
        let remaining = destination - offset.value
        if remaining != 0, (velocity < 0) == (remaining < 0) { offset.kick(velocity) }

        guard let anchor = surfaces.first?.pane, anchor.window != nil else {
            land(at: destination)
            return
        }
        let driver = self.driver ?? Motion.SpringDriver(
            view: anchor,
            advance: { [weak self] dt in self?.tick(dt: dt) ?? false },
            apply: { [weak self] in self?.apply() }
        )
        self.driver = driver
        if !driver.arm() { land(at: destination) }
    }

    func release() {
        isSettling = false
        pendingLanding = false
        landing = nil
        driver?.park()
        let finishing = surfaces
        surfaces = []
        for surface in finishing { surface.release() }
    }

    private func land(at destination: CGFloat) {
        offset.snap(to: destination)
        pendingLanding = false
        for surface in surfaces { surface.place(translation: destination, direction: direction) }
        finish()
    }

    private func tick(dt: CGFloat) -> Bool {
        let moving = offset.advance(dt: dt)
        if !moving { pendingLanding = true }
        return moving
    }

    private func apply() {
        for surface in surfaces { surface.place(translation: offset.value, direction: direction) }
        if pendingLanding {
            pendingLanding = false
            finish()
        }
    }

    private func finish() {
        isSettling = false
        driver?.park()
        let completion = landing
        landing = nil
        completion?()
    }
}
