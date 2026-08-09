import AppKit
import MarkdownCore

@MainActor
public protocol DensityGutterDelegate: AnyObject {
    func densityGutter(_ gutter: DensityGutterView, didRequestScrollToFraction fraction: CGFloat)
    /// Return a semantic section preview and useful jump context.
    func densityGutter(
        _ gutter: DensityGutterView, previewAtFraction fraction: CGFloat
    ) -> (title: String, snippet: String, context: String)?
}

public struct DensityBand {
    public enum Kind {
        case heading(level: Int), codeBlock, table, math, taskList
        case change(ChangeKind), searchHit, image, callout
    }

    public var kind: Kind
    /// 0…1 through the document.
    public var startFraction: CGFloat
    public var endFraction: CGFloat

    public init(kind: Kind, startFraction: CGFloat, endFraction: CGFloat) {
        self.kind = kind
        self.startFraction = startFraction
        self.endFraction = endFraction
    }
}

/// Density gutter (§8.6) — the scrollbar's replacement.
///
/// A scrollbar tells you how much is left; this tells you *where the sections
/// are*, and which of them hold something worth going to.
///
/// Not "the whole shape of the document at a glance", which is what this said
/// while every resting mark was drawing at one length (see `headingMarkWidth`)
/// — at rest the stack is a column of identical ticks, and shape is what the
/// hover outline is for.  The honest claim is smaller and is the one the
/// control delivers: a section index you can scan, with review state hanging
/// off it.
///
/// The stack is an index of *sections*: one mark per drawn heading, thinned by
/// depth when the track cannot hold them all, spaced by a pitch derived from
/// the track rather than a fixed gap.  Changed regions are the band that
/// matters most (§8.1), so they hang off the mark for the section they fall in
/// as a leading-edge pip — they can neither be occluded by a heading tick nor,
/// as when thinning ran over the merged band list, thinned away by it.
///
/// The band palette is deliberately narrow.  A theme only guarantees *semantic*
/// colours (§11.2), so inventing six hues here would break the moment someone
/// loads a monochrome theme — kinds are separated by width and weight instead,
/// with the tooltip carrying the specifics on hover.
public final class DensityGutterView: Motion.SpringSurfaceView {
    public weak var delegate: DensityGutterDelegate?

    public var styleSheet: StyleSheet {
        didSet {
            preview.styleSheet = styleSheet
            outline.styleSheet = styleSheet
            updateMarkLayers(animated: false)
        }
    }

    public var bands: [DensityBand] = [] {
        didSet {
            hoveredBandIndex = nil
            // The stack is derived from these, and the current mark is derived
            // from the stack — both caches are stale the moment bands change.
            bandsRevision &+= 1
            previousCurrentFraction = nil
            updateMarkLayers(animated: false)
        }
    }

    public var outlineEntries: [DensityOutlineEntry] = [] {
        didSet { outline.entries = outlineEntries }
    }

    /// Visible viewport, used to style the active prompt mark. The mark group
    /// stays centred in the viewport so scrolling never moves the rail itself.
    ///
    /// Scroll updates call this with `animated: false` — position changes
    /// during momentum scrolling do not need CA animation setup on every mark.
    /// Pointer-interaction code calls it with `animated: true` so the current
    /// heading glow and hovered mark transitions stay smooth.
    public var visibleRange: ClosedRange<CGFloat> = 0...1 {
        didSet {
            // Hosts drive this from a scroll observer, which fires far more
            // often than the value actually moves.
            guard visibleRange != oldValue else { return }
            // Only animate if the *current* heading changed (user landed on a
            // new section); a simple scroll-by never animates so momentum
            // scrolling does not create CA animation objects per mark.
            let currentNow = currentHeadingFraction()
            let currentChanged = currentNow != previousCurrentFraction
            updateMarkLayers(animated: currentChanged)
        }
    }

    /// How far the reader has got. Read state changes only the compact marks;
    /// it never draws a vertical track behind them.
    public var readProgress: CGFloat = 0 {
        didSet {
            // Hosts assign this as `max(current, …)` on every scroll event, so
            // most assignments are a no-op; without this guard scrolling up
            // relaid the whole stack at frame rate for no change.
            guard readProgress != oldValue else { return }
            setAccessibilityValueDescription("\(Int((readProgress * 100).rounded())) percent read")
            updateMarkLayers(animated: false)
        }
    }

    /// Document word count, character count and read time (§9.6).  Shown as a
    /// footer line in the hover tooltip, "rather than as permanent chrome" —
    /// the gutter is where that information lives in this app.
    public var metricsSummary: String = ""

    public var preferredWidth: CGFloat { DensityGutterView.width }

    /// Narrower than this and the rail is noise rather than signal, so hosts
    /// whose width varies — the Quick Look panel especially (§10, "density
    /// gutter shown if the panel is wide enough") — leave it out.
    /// Rail width. Lives here rather than in the app's panel metrics so the
    /// Quick Look extension gets the same rail without importing the app.
    public static let width: CGFloat = 72

    /// Scrub preview appears almost immediately; outline bloom waits longer.
    public static let hoverDwell: TimeInterval = 0.02
    /// Passive hover may begin before the pointer reaches a mark, but it must
    /// never activate from an arbitrary point in the rail.
    static let hoverActivationSlop: CGFloat = 22
    /// Once a mark owns the hover, leaving its row dismisses chrome.
    static let hoverDismissalSlop: CGFloat = 4
    /// Small bridge only for the physical gap between a mark and its preview.
    static let previewExitDelay: TimeInterval = 0.06
    /// Distance over which mark size / brightness fall off from the pointer.
    static let proximityRadius: CGFloat = 36
    /// Maximum magnetic pull of a mark toward the pointer (points).
    static let magneticPull: CGFloat = 1.5
    /// Extra magnetic pull scaled by scrub velocity (points at full influence).
    static let scrubVelocityPull: CGFloat = 2.0
    /// Pointer speed (pt/s) that saturates velocity pull.
    static let scrubVelocityScale: CGFloat = 900
    /// Maximum fractional compression of the centred stack near the pointer.
    static let stackCompression: CGFloat = 0.08
    /// Whole-rail width scale while the pointer is inside.
    static let breatheScale: CGFloat = 1.08
    /// Alpha multiplier for marks outside the hovered neighbourhood.
    static let neighborhoodDim: CGFloat = 0.82
    /// Marks within this index distance stay slightly lifted under hover.
    static let neighborhoodLiftRadius: Int = 2

    // Stack sizing.  Every one of these is a *rate*, not a length: the cluster
    // is derived from the track it sits in, so the same document reads the same
    // way in a Quick Look panel and on a full-screen display.  Absolute mark
    // counts and gaps were the bug — 15 marks at a 10pt gap is 10% of a tall
    // window (a sparse huddle) and a solid bar in a short one.
    //
    /// Closest two marks may sit.  Below this the stack stops reading as
    /// separate ticks and becomes a bar, so it caps the capacity instead.
    static let minPitch: CGFloat = 7
    /// Furthest two marks may sit.  The stack is one condensed object: beyond
    /// this pitch the marks scatter into a list instead of reading as a cluster.
    static let maxPitch: CGFloat = 11
    /// Share of the track the cluster may span.  The stack is a prompt index,
    /// so it must never grow to full height and become a second scrollbar.
    static let maxSpanFraction: CGFloat = 0.5
    /// Upper bound on marks however tall the window is — past this the rail is
    /// asking to be read rather than scanned, and the hover outline is the
    /// place for detail.  Rises as the pitch tightens, so a full stack still
    /// spans the same share of a tall window.
    static let stackCapacityCeiling: Int = 18
    /// Below this the document has no shape worth indexing, so the rail draws
    /// the quiet spine instead of a stack pretending to be one.
    static let minimumStackMarks: Int = 3

    /// Overlay dot on a mark's leading edge (§2.3 "coloured pips").
    static let pipDiameter: CGFloat = 3.5
    /// Gap from the resting mark's leading edge to the first pip.
    static let pipLeadingGap: CGFloat = 5

    /// Optical boost on click / scrub release (points of extra width).
    static let jumpPunchBoost: CGFloat = 4
    /// Current-mark glow (same hue, very low opacity).
    static let currentGlowRadius: CGFloat = 10
    static let currentGlowOpacity: Float = 0.12

    private let preview: DensityGutterPreviewWindow
    private let outline: DensityOutlineWindow
    public private(set) var isScrubbing = false
    private var trackingArea: NSTrackingArea?
    private var previewWorkItem: DispatchWorkItem?
    private var previewHideWorkItem: DispatchWorkItem?
    private var outlineWorkItem: DispatchWorkItem?
    private var outlineHideWorkItem: DispatchWorkItem?
    private var pointerLocation: NSPoint?
    private var pointerIsInPreview = false
    private var pointerIsInOutline = false
    private var lastPointerSample: (y: CGFloat, time: CFTimeInterval)?
    private var pointerVelocityY: CGFloat = 0
    private var previousCurrentFraction: CGFloat?
    private var progressWashLayer: CALayer?
    private var spineLayer: CALayer?

    // MARK: Rail motion

    /// The rail's motion is one physics channel, not a pile of cached CA
    /// animations: marks, pips and the whole-rail breathe all chase their
    /// targets through `Motion.SpringScalar` integrators driven by a single
    /// display link.  Velocity is state, so an interrupted trip resumes at
    /// its own speed and a mark that was charging at the pointer keeps the
    /// momentum it had — the quality a fixed-duration bezier cannot express.
    ///
    /// Position *and* velocity are what is animated; the trip takes however
    /// long physics says, and the display link parks the moment everything
    /// settles.  The old grow/shrink asymmetry (`hoverGrow` / `hoverShrink`)
    /// is gone: a spring is symmetric, so the perceived difference between
    /// growing and shrinking now comes from the pointer's own speed, which is
    /// the difference that reads as liquid.
    private var breatheSpring = Motion.SpringScalar(
        value: 1,
        perceptualDuration: Motion.springQuick
    )

    /// One mark's complete visual state — geometry, tint and glow — all
    /// integrated from the same clock so the mark moves as one body even
    /// though it is four springs.
    private struct MarkSimulation {
        var frame: Motion.SpringRect
        var color: Motion.SpringColor
        var glow: Motion.SpringScalar
        /// Whether the next event asked this mark to settle like the current
        /// heading; flips the pace between pointer-quick and structural.
        var wantsSettle: Bool

        init(frame: CGRect, color: CGColor, glow: CGFloat) {
            self.frame = Motion.SpringRect(rect: frame, perceptualDuration: Motion.springQuick)
            self.color = Motion.SpringColor(
                value: Self.foreground(of: color),
                perceptualDuration: Motion.springQuick
            )
            self.glow = Motion.SpringScalar(value: glow, perceptualDuration: Motion.springQuick)
            wantsSettle = false
        }

        static func foreground(of color: CGColor) -> NSColor {
            // `CGColor.components` is in the *source* colour space — a theme
            // grey arrives as a 2-channel GenericGray2.2 and would read as
            // opaque black — so normalise to sRGB first; the springs cluster
            // around colours, which are numbers in one agreed space.
            let normalized = NSColor(cgColor: color)?.usingColorSpace(.sRGB)
            guard let components = normalized?.cgColor.components, components.count >= 3 else {
                return .init(srgbRed: 0, green: 0, blue: 0, alpha: 1)
            }
            return NSColor(
                srgbRed: components[0],
                green: components[1],
                blue: components[2],
                alpha: components.count >= 4 ? components[3] : 1
            )
        }

        mutating func retarget(frame: CGRect, color: CGColor, glow: CGFloat, settle: Bool) {
            if settle != wantsSettle {
                wantsSettle = settle
                let pace = settle ? Motion.springStandard : Motion.springQuick
                self.frame.retune(perceptualDuration: pace)
                // A heading change moves the mark *and* re-tints it as one
                // body; the colour springs ride the same pace as the geometry.
                self.color.retune(perceptualDuration: pace)
                self.glow.retune(perceptualDuration: pace)
            }
            self.frame.target(frame)
            self.color.target(Self.foreground(of: color))
            self.glow.target(glow)
        }

        mutating func snap(frame: CGRect, color: CGColor, glow: CGFloat) {
            self.frame.snap(to: frame)
            self.color.snap(to: Self.foreground(of: color))
            self.glow.snap(to: glow)
            // A snap is the end of one scaffold; the next retarget must start
            // from the pointer pace again, so re-launch every spring the
            // settle had slowed and forget the structural pace.
            guard wantsSettle else { return }
            wantsSettle = false
            self.frame.retune(perceptualDuration: Motion.springQuick)
            self.color.retune(perceptualDuration: Motion.springQuick)
            self.glow.retune(perceptualDuration: Motion.springQuick)
        }

        mutating func advance(dt: CGFloat) -> Bool {
            var moving = false
            moving = frame.advance(dt: dt) || moving
            moving = color.advance(dt: dt) || moving
            moving = glow.advance(dt: dt) || moving
            return moving
        }

        var viewFrame: CGRect {
            let size = frame.size.value
            let centre = frame.centre.value
            return CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2, width: size.width, height: size.height)
        }
    }

    /// A review pip — the small dots on a mark's leading edge.  They hold the
    /// mark's fraction but spring independently so a pip can *cascade* in
    /// behind the band it belongs to (Motion.previewStagger per step).
    ///
    /// Internal rather than private only so the rail's own tests can drive the
    /// cascade a frame at a time: the release schedule is the one part of this
    /// that can fail silently — by never releasing — and a bug that shows up
    /// as "an invisible dot and a busy display link" is not one to leave to
    /// the eye.
    struct PipSimulation {
        var centre: Motion.SpringPoint
        var diameter: Motion.SpringScalar
        var color: Motion.SpringColor
        /// Seconds still to wait before this pip joins the cascade.
        ///
        /// Counted down by `advance` rather than compared against a wall
        /// clock, because the driver is the only thing that knows time is
        /// passing.  A release *deadline* could only be crossed by an event,
        /// and a cascade is precisely the case where no further event is
        /// coming: the pips beyond the first would sit unengaged for ever,
        /// invisible, while `advance` kept reporting them as moving and the
        /// display link spun at full refresh on an idle window.
        var delayRemaining: CGFloat = 0
        var engaged = false

        init(centre: CGPoint, diameter: CGFloat, color: CGColor) {
            let quick = Motion.springQuick
            self.centre = .init(value: centre, perceptualDuration: quick)
            self.diameter = .init(value: diameter, perceptualDuration: quick)
            // The pip's alpha is its cascade: it starts invisible, targets the
            // colour's alpha and takes a velocity kick on release, so it lands
            // with a swell rather than appearing.
            self.color = Motion.SpringColor(
                value: MarkSimulation.foreground(of: color).withAlphaComponent(0),
                perceptualDuration: quick
            )
        }

        mutating func retarget(centre: CGPoint, diameter: CGFloat, color: CGColor, delay: CGFloat, releaseNow: Bool) {
            self.centre.target(centre)
            self.diameter.target(diameter)
            self.color.target(MarkSimulation.foreground(of: color))
            if engaged { return }
            if releaseNow || delay <= 0 {
                engage()
            } else {
                delayRemaining = delay
            }
        }

        mutating func snap(centre: CGPoint, diameter: CGFloat, color: CGColor) {
            self.centre.snap(to: centre)
            self.diameter.snap(to: diameter)
            self.color.snap(to: MarkSimulation.foreground(of: color))
            delayRemaining = 0
            engaged = true
        }

        /// Join the cascade: the alpha spring takes a velocity kick so the pip
        /// swells into place rather than merely appearing.
        private mutating func engage() {
            engaged = true
            delayRemaining = 0
            color.kickAlpha(18)
        }

        mutating func advance(dt: CGFloat) -> Bool {
            if !engaged {
                delayRemaining -= dt
                // Still waiting its turn: moving, in the sense the driver
                // cares about — there is more to draw after this frame.
                guard delayRemaining <= 0 else { return true }
                engage()
            }
            var moving = false
            moving = centre.advance(dt: dt) || moving
            moving = diameter.advance(dt: dt) || moving
            moving = color.advance(dt: dt) || moving
            return moving
        }

        var position: CGPoint { centre.value }
        var currentColor: NSColor { color.value }
    }

    private var markSimulations: [MarkSimulation] = []
    private var pipSimulations: [PipSimulation] = []

    /// Bumped on every `bands` assignment so the selection cache can be keyed
    /// without comparing the array itself (which can hold thousands of search
    /// hits and is rebuilt wholesale on every reparse).
    private var bandsRevision: Int = 0
    private var cachedSelection: Selection?
    private var cachedSelectionKey: SelectionKey?

    /// Marks sit in a generous invisible hit lane. Only the compact mark stack
    /// is drawn; a viewport-height rule looks like a second scrollbar.
    private let horizontalMargin: CGFloat = 16
    private let trackInset: CGFloat = 28
    private var markLayers: [CALayer] = []
    private var pipLayers: [CALayer] = []
    private var hoveredBandIndex: Int?
    private var didDrag = false

    // MARK: - Init

    /// Hosts build panels before they have a theme in hand and assign
    /// `styleSheet` immediately afterwards.
    public convenience init() { self.init(styleSheet: .current) }

    public init(styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        self.preview = DensityGutterPreviewWindow(styleSheet: styleSheet)
        self.outline = DensityOutlineWindow(styleSheet: styleSheet)
        super.init(frame: NSRect(x: 0, y: 0, width: DensityGutterView.width, height: 100))

        wantsLayer = true

        preview.onPointerPresence = { [weak self] isInside in
            guard let self else { return }
            self.pointerIsInPreview = isInside
            if isInside {
                self.cancelPreviewHide()
                self.preview.cancelHideAnimation()
            } else if !self.isScrubbing {
                self.schedulePreviewHide()
            }
        }

        outline.onSelect = { [weak self] fraction in
            guard let self else { return }
            self.delegate?.densityGutter(self, didRequestScrollToFraction: fraction)
        }
        outline.onPointerPresence = { [weak self] isInside in
            guard let self else { return }
            self.pointerIsInOutline = isInside
            if isInside {
                self.cancelOutlineHide()
                self.outline.cancelDismissAnimation()
            } else if !self.isScrubbing {
                self.scheduleOutlineHide()
            }
        }

        // Fully custom-drawn with no accessible subviews, so it has to declare
        // itself an element or VoiceOver never sees it (§11.4).
        setAccessibilityElement(true)
        setAccessibilityRole(.scrollBar)
        setAccessibilityLabel("Document map")
        setAccessibilityValueDescription("0 percent read")
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Show document outline") { [weak self] in
                guard let self, self.window != nil, !self.outlineEntries.isEmpty else { return false }
                self.presentOutlineForKeyboard()
                return true
            },
        ])
        updateMarkLayers(animated: false)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Fractions run top-to-bottom through the document, so the view does too.
    public override var isFlipped: Bool { true }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: DensityGutterView.width, height: NSView.noIntrinsicMetric)
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateMarkLayers(animated: false)
    }

    // MARK: - Drawing

    // MARK: - Stack model

    /// One drawn mark: a heading, plus the review overlays that fall inside its
    /// section.
    struct ResolvedMark {
        var band: DensityBand
        var y: CGFloat
        var pip: Pip
    }

    /// Overlays no longer compete with headings for a slot in the stack — they
    /// attach to the section they fall in and draw as dots on the mark's
    /// leading edge (§2.3).  Before this, thinning ran over the merged band
    /// list, so a Find with two hundred matches could replace the entire
    /// outline with search pips, and a change at the top of a heading drew a
    /// second tick that read as a second section.
    struct Pip: Equatable {
        var change: ChangeKind?
        var searchHit: Bool = false

        var isEmpty: Bool { change == nil && !searchHit }
    }

    /// Which bands the rail draws, and what hangs off each of them.  Depends
    /// only on the bands and the capacity, so it survives pointer movement.
    struct Selection {
        var marks: [DensityBand]
        var pips: [Pip]
    }

    private struct SelectionKey: Equatable {
        var revision: Int
        var capacity: Int
    }

    private func currentHeadingFraction() -> CGFloat? {
        // Derived from the *drawn* marks rather than from every heading: a
        // current fraction that no drawn mark carries highlights nothing.
        Self.currentHeadingFraction(
            in: selection(height: bounds.height).marks, at: visibleRange
        )
    }

    static func currentHeadingFraction(
        in bands: [DensityBand], at visibleRange: ClosedRange<CGFloat>
    ) -> CGFloat? {
        let headings = bands.filter {
            if case .heading = $0.kind { return true }
            return false
        }
        return headings.last(where: { $0.startFraction <= visibleRange.lowerBound })?.startFraction
            ?? headings.first?.startFraction
    }

    /// The usable span of the rail, inset from both ends.
    static func trackRange(
        height: CGFloat, trackInset: CGFloat = 28
    ) -> (top: CGFloat, bottom: CGFloat) {
        let top = min(trackInset, max(0, height / 2))
        return (top, max(top, height - trackInset))
    }

    /// How many marks this track can hold at a legible pitch.
    ///
    /// Derived from the track, so a Quick Look panel thins harder and a tall
    /// window shows more.  A fixed cap could not do both: the count that kept
    /// a 1400pt window from becoming a solid bar left it a 140pt huddle in an
    /// otherwise empty column, and still collapsed to a bar in a short one.
    static func stackCapacity(track: CGFloat) -> Int {
        guard track > 0 else { return 0 }
        let fit = Int((track * maxSpanFraction / minPitch).rounded(.down)) + 1
        return max(0, min(stackCapacityCeiling, fit))
    }

    /// Spread `count` marks across the allowed share of the track, then clamp.
    /// Legibility (`minPitch`) wins over the span target; cohesion (`maxPitch`)
    /// caps how far a small stack may spread.
    static func markPitch(track: CGFloat, count: Int) -> CGFloat {
        guard count > 1 else { return maxPitch }
        let ideal = track * maxSpanFraction / CGFloat(count - 1)
        return min(maxPitch, max(minPitch, ideal))
    }

    /// Calculate a centered stack for the visible document marks. This is a
    /// prompt index, not a miniature scrollbar: the marks stay easy to scan
    /// while the active heading changes by appearance rather than movement.
    static func centeredBandYPositions(
        height: CGFloat,
        count: Int,
        trackInset: CGFloat = 28,
        markGap: CGFloat = DensityGutterView.maxPitch,
        pointerY: CGFloat? = nil,
        compression: CGFloat = DensityGutterView.stackCompression,
        proximityRadius: CGFloat = DensityGutterView.proximityRadius
    ) -> [CGFloat] {
        guard count > 0 else { return [] }

        let track = trackRange(height: height, trackInset: trackInset)
        let trackHeight = max(1, track.bottom - track.top)
        let gap = min(markGap, trackHeight / CGFloat(max(1, count - 1)))
        let groupHeight = CGFloat(max(0, count - 1)) * gap
        let start = track.top + max(0, (trackHeight - groupHeight) / 2)
        let base = (0..<count).map { start + CGFloat($0) * gap }

        guard let pointerY, count > 1, compression > 0 else { return base }

        // Soft Dock-like compression: gaps near the pointer shrink a little so
        // the stack feels magnetic without rearranging reading order.
        var compressed: [CGFloat] = [base[0]]
        for index in 1..<count {
            let mid = (base[index - 1] + base[index]) / 2
            let influence = proximityInfluence(
                distance: abs(mid - pointerY),
                radius: proximityRadius
            )
            let localGap = gap * (1 - compression * influence)
            compressed.append(compressed[index - 1] + localGap)
        }
        let compressedSpan = (compressed.last ?? 0) - compressed[0]
        let recenter = start + max(0, (groupHeight - compressedSpan) / 2) - compressed[0]
        return compressed.map { $0 + recenter }
    }

    /// Ease-out falloff in 0…1 for pointer distance.
    static func proximityInfluence(distance: CGFloat, radius: CGFloat = proximityRadius) -> CGFloat {
        guard radius > 0 else { return distance <= 0 ? 1 : 0 }
        let t = min(1, max(0, 1 - distance / radius))
        return t * t * (3 - 2 * t) // smoothstep
    }

    /// Every resting heading uses one length. The old level-encoded staircase
    /// made a short outline look like randomly broken rules; heading depth is
    /// already explicit in the hover outline. Current / hover state grows the
    /// mark without moving its shared centre line.
    static func headingMarkWidth(level: Int, emphasized: Bool = false) -> CGFloat {
        _ = level
        return emphasized ? 32 : 26
    }

    /// Cached because pointer movement must not re-derive it: the selection
    /// depends only on the bands and on how many the track can hold, and
    /// attaching pips is linear in the overlay count — which, with Find active
    /// on a large document, is thousands.
    private func selection(height: CGFloat) -> Selection {
        let track = Self.trackRange(height: height, trackInset: trackInset)
        let capacity = Self.stackCapacity(track: track.bottom - track.top)
        let key = SelectionKey(revision: bandsRevision, capacity: capacity)
        if key == cachedSelectionKey, let cachedSelection { return cachedSelection }
        let resolved = Self.selection(for: bands, capacity: capacity)
        cachedSelection = resolved
        cachedSelectionKey = key
        return resolved
    }

    static func selection(for bands: [DensityBand], capacity: Int) -> Selection {
        let headings = bands
            .filter { if case .heading = $0.kind { return true } else { return false } }
            .sorted { $0.startFraction < $1.startFraction }
        let overlays = bands
            .filter { isOverlay($0.kind) }
            .sorted { $0.startFraction < $1.startFraction }

        // A document with no headings has no sections to index, so the review
        // overlays become the stack rather than vanishing along with it.
        guard !headings.isEmpty else {
            let marks = strideSampled(overlays, limit: capacity)
            guard marks.count >= minimumStackMarks else { return Selection(marks: [], pips: []) }
            return Selection(marks: marks, pips: Array(repeating: Pip(), count: marks.count))
        }

        let marks = selectHeadings(headings, capacity: capacity)
        guard marks.count >= minimumStackMarks else { return Selection(marks: [], pips: []) }
        return Selection(marks: marks, pips: pips(for: overlays, on: marks))
    }

    /// Thins by *depth* before it thins by position, so detail is lost the way
    /// a table of contents loses it and never structure.  Index-stride sampling
    /// over the whole list could drop an H1 while keeping one of its H3
    /// children, which left the rail describing a shape the document has not
    /// got.
    static func selectHeadings(_ headings: [DensityBand], capacity: Int) -> [DensityBand] {
        guard capacity > 0 else { return [] }
        guard headings.count > capacity else { return headings }

        let present = Set(headings.map(headingLevel)).sorted()
        var chosen: [DensityBand] = []
        var fillIndex = present.count
        for (index, depth) in present.enumerated() {
            let candidates = headings.filter { headingLevel($0) <= depth }
            if candidates.count > capacity {
                fillIndex = index
                break
            }
            chosen = candidates
        }

        // Spare slots go to the next depth down, evenly sampled.  Without this
        // a document with one H1 and forty H2s drew a single tick, because the
        // deepest depth that fits whole is the H1 on its own.
        let remaining = capacity - chosen.count
        guard remaining > 0, fillIndex < present.count else { return chosen }
        let fillLevel = present[fillIndex]
        let picked = strideSampled(
            headings.filter { headingLevel($0) == fillLevel }, limit: remaining
        )
        return (chosen + picked).sorted { $0.startFraction < $1.startFraction }
    }

    private static func headingLevel(_ band: DensityBand) -> Int {
        if case .heading(let level) = band.kind { return level }
        return .max
    }

    /// Evenly thins to `limit`, always keeping the first and last so the result
    /// still spans what it stands for.  Scanning is what this control is for;
    /// an exact count is what the hover outline is for.
    static func strideSampled(_ bands: [DensityBand], limit: Int) -> [DensityBand] {
        guard limit > 0 else { return [] }
        guard bands.count > limit else { return bands }
        // `bands.count > limit >= 1` here, so the array is never empty.
        guard limit > 1 else { return [bands[0]] }
        let last = bands.count - 1
        let step = Double(last) / Double(limit - 1)
        var picked: [DensityBand] = []
        picked.reserveCapacity(limit)
        var previousIndex = -1
        for slot in 0..<limit {
            let index = min(last, Int((Double(slot) * step).rounded()))
            guard index != previousIndex else { continue }
            picked.append(bands[index])
            previousIndex = index
        }
        return picked
    }

    /// An overlay belongs to the section it falls in, so it attaches to the
    /// last mark at or before it — not to the nearest one, which would hang a
    /// change made at the top of a section off the previous heading.
    static func pips(for overlays: [DensityBand], on marks: [DensityBand]) -> [Pip] {
        var result = [Pip](repeating: Pip(), count: marks.count)
        guard !marks.isEmpty else { return result }
        let fractions = marks.map(\.startFraction)
        for overlay in overlays {
            let index = sectionIndex(for: overlay.startFraction, in: fractions)
            switch overlay.kind {
            case .searchHit:
                result[index].searchHit = true
            case .change(let kind):
                // Mixed kinds in one section report as "changed" rather than
                // claiming whichever happened to be enumerated last.
                result[index].change = result[index].change.map { $0 == kind ? kind : .modified }
                    ?? kind
            default:
                break
            }
        }
        return result
    }

    /// Last index whose fraction is at or before `fraction`, or 0 for anything
    /// above the first mark — front matter, or an edit made before any heading.
    static func sectionIndex(for fraction: CGFloat, in fractions: [CGFloat]) -> Int {
        var low = 0
        var high = fractions.count - 1
        var result = 0
        while low <= high {
            let mid = (low + high) / 2
            if fractions[mid] <= fraction {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }

    /// At rest the rail carries navigation and review signals only: headings
    /// become marks, changes and search hits become pips on them.  Body-shape
    /// bands stay in the data for the hover preview, but never become a
    /// minimap of code, tables, or other large blocks.
    static func isOverlay(_ kind: DensityBand.Kind) -> Bool {
        switch kind {
        case .change, .searchHit: return true
        case .heading, .codeBlock, .table, .math, .taskList, .image, .callout: return false
        }
    }

    private func resolvedStack(height: CGFloat) -> [ResolvedMark] {
        let selected = selection(height: height)
        guard !selected.marks.isEmpty else { return [] }
        let track = Self.trackRange(height: height, trackInset: trackInset)
        let positions = Self.centeredBandYPositions(
            height: height,
            count: selected.marks.count,
            trackInset: trackInset,
            markGap: Self.markPitch(
                track: track.bottom - track.top, count: selected.marks.count
            ),
            pointerY: pointerLocation?.y
        )
        return selected.marks.enumerated().map { index, band in
            ResolvedMark(band: band, y: positions[index], pip: selected.pips[index])
        }
    }

    private struct BandStyle {
        var widthPoints: CGFloat
        var minHeight: CGFloat
        var color: NSColor
    }

    private func style(for kind: DensityBand.Kind, contrast: Bool, emphasized: Bool = false) -> BandStyle {
        let maxWidth = max(2, bounds.width - horizontalMargin * 2)
        switch kind {
        case .heading(let level):
            return BandStyle(
                widthPoints: min(Self.headingMarkWidth(level: level, emphasized: emphasized), maxWidth),
                minHeight: 2.5,
                color: styleSheet.railTick
            )
        case .searchHit:
            // Rare sparks: a touch wider / brighter than heading ticks.
            return BandStyle(
                widthPoints: min(14, maxWidth),
                minHeight: 2.5,
                color: styleSheet.searchHit.withAlphaComponent(contrast ? 1 : 0.92)
            )
        case .change(let changeKind):
            let geometry: (width: CGFloat, height: CGFloat) = switch changeKind {
            case .inserted: (16, 3)
            case .modified: (12, 5)
            case .deleted: (6, 6)
            }
            return BandStyle(
                widthPoints: min(geometry.width, maxWidth),
                minHeight: geometry.height,
                color: styleSheet.changeColor(changeKind).withAlphaComponent(contrast ? 1 : 0.95)
            )
        case .codeBlock, .table, .math, .taskList, .image, .callout:
            // Body-shape bands stay in the data model but are not drawn at rest.
            return BandStyle(
                widthPoints: min(8, maxWidth),
                minHeight: 2,
                color: styleSheet.textSecondary.panelAlpha(0.4, increaseContrast: contrast)
            )
        }
    }

    /// Renders one small layer per visible document mark. Every mark shares the
    /// same optical spine so the rail reads as one centred stick; proximity
    /// only changes length, weight, and brightness.
    private func updateMarkLayers(animated: Bool) {
        guard bounds.height > 0 else { return }
        let entries = resolvedStack(height: bounds.height)
        let current = currentHeadingFraction()
        let currentChanged = current != previousCurrentFraction
        previousCurrentFraction = current
        let available = max(1, bounds.width - horizontalMargin * 2)
        let pointerY = pointerLocation?.y
        let velocityInfluence = min(1, abs(pointerVelocityY) / Self.scrubVelocityScale)
        let velocityPull = isScrubbing
            ? Self.scrubVelocityPull * velocityInfluence
            : 0
        let magneticCap = Self.magneticPull + velocityPull
        let reduceMotion = styleSheet.reduceMotion

        while markLayers.count < entries.count {
            let mark = CALayer()
            mark.cornerCurve = .continuous
            mark.masksToBounds = false
            layer?.addSublayer(mark)
            markLayers.append(mark)
        }
        if markSimulations.count > entries.count {
            markSimulations.removeLast(markSimulations.count - entries.count)
        }
        while markSimulations.count < entries.count {
            markSimulations.append(
                MarkSimulation(frame: .zero, color: .clear, glow: 0)
            )
        }

        for (index, entry) in entries.enumerated() {
            let isCurrent: Bool = {
                guard let current else { return false }
                if case .heading = entry.band.kind {
                    return entry.band.startFraction == current
                }
                return false
            }()
            let isPrimary = index == hoveredBandIndex
            let emphasized = isCurrent || isPrimary
            var bandStyle = style(
                for: entry.band.kind,
                contrast: styleSheet.increaseContrast,
                emphasized: emphasized
            )
            let distance = pointerY.map { abs(entry.y - $0) }
            let influence = distance.map {
                Self.proximityInfluence(distance: $0, radius: Self.proximityRadius)
            } ?? 0
            let focus = isPrimary ? max(influence, 0.78) : influence * 0.72
            let neighborhood = Self.neighborhoodFactor(
                index: index,
                hoveredIndex: hoveredBandIndex
            )

            if isCurrent {
                bandStyle.color = styleSheet.railTickCurrent.withAlphaComponent(0.92)
                bandStyle.minHeight = max(bandStyle.minHeight, 3)
            } else if case .heading = entry.band.kind {
                // Every mark stays a solid line.  The deeply faded unread
                // ticks (0.28) read as useless mini-lines next to the brighter
                // ones, so read state is only a quiet alpha step here.
                bandStyle.color = styleSheet.railTick.withAlphaComponent(
                    entry.band.startFraction <= readProgress ? 0.56 : 0.44
                )
            }

            if focus > 0.02 {
                switch entry.band.kind {
                case .heading:
                    let alpha = (isCurrent ? 0.92 : 0.52) + focus * (isCurrent ? 0.06 : 0.42)
                    bandStyle.color = styleSheet.railTickCurrent.withAlphaComponent(min(0.98, alpha))
                case .searchHit, .change:
                    bandStyle.color = bandStyle.color.withAlphaComponent(min(1, 0.88 + focus * 0.12))
                default:
                    break
                }
            }

            if neighborhood < 1, !isPrimary {
                bandStyle.color = bandStyle.color.withAlphaComponent(
                    bandStyle.color.alphaComponent * neighborhood
                )
            }

            let markWidth = min(available, bandStyle.widthPoints + focus * 12)
            let markHeight = bandStyle.minHeight + focus * 2.2
            let magnetic = (pointerY.map { ($0 - entry.y) } ?? 0)
                * focus * (magneticCap / max(1, Self.proximityRadius))
            let markY = entry.y + max(-magneticCap, min(magneticCap, magnetic))
            // One optical spine: every mark grows symmetrically from midX.
            let markX = bounds.midX - markWidth / 2
            let frame = CGRect(
                x: markX,
                y: markY - markHeight / 2,
                width: markWidth,
                height: markHeight
            )
            let glow: CGFloat = (!isCurrent || reduceMotion) ? 0 : CGFloat(Self.currentGlowOpacity)
            let mark = markLayers[index]
            if isCurrent { mark.shadowColor = styleSheet.railTickCurrent.cgColor }

            if animated && !reduceMotion {
                markSimulations[index].retarget(
                    frame: frame,
                    color: bandStyle.color.cgColor,
                    glow: glow,
                    settle: isCurrent && currentChanged
                )
            } else {
                markSimulations[index].snap(
                    frame: frame,
                    color: bandStyle.color.cgColor,
                    glow: glow
                )
            }
        }

        for mark in markLayers.dropFirst(entries.count) {
            mark.removeAllAnimations()
            mark.shadowOpacity = 0
            mark.isHidden = true
        }

        updatePipLayers(entries: entries, animated: animated)
        if animated && !reduceMotion {
            armRailDriver()
        } else {
            applySimulations()
        }
    }

    /// Review overlays sit on a fixed leading offset from the *resting* mark
    /// width, so hovering a mark grows the tick without shoving its pips
    /// sideways.
    private func updatePipLayers(entries: [ResolvedMark], animated: Bool) {
        let contrast = styleSheet.increaseContrast
        var wanted: [(x: CGFloat, y: CGFloat, color: NSColor)] = []
        let diameter = Self.pipDiameter
        let restingHalf = Self.headingMarkWidth(level: 1) / 2

        for entry in entries where !entry.pip.isEmpty {
            var trailingEdge = bounds.midX - restingHalf - Self.pipLeadingGap
            var colors: [NSColor] = []
            if let change = entry.pip.change {
                colors.append(styleSheet.changeColor(change).withAlphaComponent(contrast ? 1 : 0.95))
            }
            if entry.pip.searchHit {
                colors.append(styleSheet.searchHit.withAlphaComponent(contrast ? 1 : 0.92))
            }
            for color in colors {
                wanted.append((
                    x: trailingEdge - diameter,
                    y: entry.y - diameter / 2,
                    color: color
                ))
                trailingEdge -= diameter + 2.5
            }
        }

        while pipLayers.count < wanted.count {
            let pip = CALayer()
            pip.cornerCurve = .continuous
            layer?.addSublayer(pip)
            pipLayers.append(pip)
        }
        if pipSimulations.count > wanted.count {
            pipSimulations.removeLast(pipSimulations.count - wanted.count)
        }
        for pip in pipLayers.dropFirst(wanted.count) {
            pip.isHidden = true
        }

        let releaseNow = !animated || styleSheet.reduceMotion
        for (index, target) in wanted.enumerated() {
            if index >= pipSimulations.count {
                pipSimulations.append(
                    PipSimulation(
                        centre: CGPoint(x: target.x, y: target.y),
                        diameter: diameter,
                        color: target.color.cgColor
                    )
                )
            }
            if releaseNow {
                pipSimulations[index].snap(
                    centre: CGPoint(x: target.x, y: target.y),
                    diameter: diameter,
                    color: target.color.cgColor
                )
            } else {
                pipSimulations[index].retarget(
                    centre: CGPoint(x: target.x, y: target.y),
                    diameter: diameter,
                    color: target.color.cgColor,
                    delay: Motion.previewStagger * CGFloat(index),
                    releaseNow: false
                )
            }
        }
    }

    // MARK: - Rail driver

    /// Every spring in the rail steps on the same clock.  Arming the driver is
    /// cheap — the link parks itself the frame everything settles — so events
    /// can call `armSprings()` freely and the driver decides whether a frame
    /// is even worth taking.
    private func armRailDriver() {
        guard window != nil, !styleSheet.reduceMotion else { return }
        armSprings()
    }

    /// One tick of the rail's whole physics channel.  `SpringSurfaceView` owns
    /// the driver lifecycle (window teardown, `deinit`); this file owns only
    /// what the springs do.
    public override func springTick(dt: CGFloat) -> Bool {
        var moving = breatheSpring.advance(dt: dt)
        for index in markSimulations.indices {
            moving = markSimulations[index].advance(dt: dt) || moving
        }
        for index in pipSimulations.indices {
            moving = pipSimulations[index].advance(dt: dt) || moving
        }
        return moving
    }

    public override func springApply() {
        applySimulations()
    }

    /// Live resize: the rail's marks are laid out against `bounds.height`, so
    /// a drag retargets every one of them on every AppKit frame.  Rebuilding
    /// unanimated puts each mark on its new seat immediately, which is what
    /// the reader dragging the window edge is asking for.
    public override func springsSettleImmediately() {
        updateMarkLayers(animated: false)
    }

    /// Draw what the springs currently say, in one transaction — the display
    /// link's per-frame snapshot. Breathe multiplies the resting width so the
    /// whole rail swells and relaxes as one body without touching the marks'
    /// own springs.
    private func applySimulations() {
        let breathe = breatheSpring.value
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, mark) in markLayers.enumerated() {
            guard index < markSimulations.count else { continue }
            let sim = markSimulations[index]
            let stateless = sim.viewFrame
            let width = stateless.width * breathe
            mark.frame = CGRect(
                x: stateless.midX - width / 2,
                y: stateless.minY,
                width: width,
                height: stateless.height
            )
            mark.cornerRadius = stateless.height / 2
            mark.backgroundColor = sim.color.value.cgColor
            mark.isHidden = false
            let glow = sim.glow.value
            if glow > 0.01 {
                mark.shadowColor = styleSheet.railTickCurrent.cgColor
                mark.shadowOpacity = Float(glow)
                mark.shadowRadius = Self.currentGlowRadius
                mark.shadowOffset = .zero
            } else {
                mark.shadowOpacity = 0
                mark.shadowRadius = 0
            }
        }
        for (index, pip) in pipSimulations.enumerated() {
            guard index < pipLayers.count else { continue }
            let layer = pipLayers[index]
            let d = pip.diameter.value * breathe
            let position = pip.position
            layer.frame = CGRect(
                x: position.x - d / 2,
                y: position.y - d / 2,
                width: d,
                height: d
            )
            layer.cornerRadius = d / 2
            layer.backgroundColor = pip.currentColor.cgColor
            layer.isHidden = pip.currentColor.alphaComponent < 0.01
        }
        CATransaction.commit()
    }

    static func neighborhoodFactor(index: Int, hoveredIndex: Int?) -> CGFloat {
        guard let hoveredIndex else { return 1 }
        let distance = abs(index - hoveredIndex)
        if distance == 0 { return 1 }
        if distance <= neighborhoodLiftRadius { return 0.92 }
        return neighborhoodDim
    }

    public override func layout() {
        super.layout()
        updateMarkLayers(animated: false)
    }


    // MARK: - Pointer (§7.1 "click to jump, drag to scrub")

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        refreshTrackingArea(
            &trackingArea,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect]
        )
    }

    /// The rail has exactly one coordinate system: the marks.
    ///
    /// A point inside the cluster resolves to the mark it is on; a point
    /// between two marks interpolates between their fractions; a point beyond
    /// either end clamps to the first or last mark.  It used to fall back to a
    /// linear read of the whole track whenever no mark was within slop — and
    /// since the cluster occupied a small share of a tall rail, most of a
    /// full-height, 72pt-wide hit area jumped to a position the rail had never
    /// depicted.
    private func fraction(at point: NSPoint) -> CGFloat {
        guard bounds.height > 0 else { return 0 }
        let entries = resolvedStack(height: bounds.height)
        guard let first = entries.first, let last = entries.last else {
            // No stack: the track is all there is to read.
            let track = Self.trackRange(height: bounds.height, trackInset: trackInset)
            return min(1, max(0, (point.y - track.top) / max(1, track.bottom - track.top)))
        }
        if point.y <= first.y { return first.band.startFraction }
        if point.y >= last.y { return last.band.startFraction }
        if let nearest = entries.min(by: {
            abs($0.y - point.y) < abs($1.y - point.y)
        }), abs(nearest.y - point.y) <= Self.hoverActivationSlop {
            return nearest.band.startFraction
        }
        guard let upper = entries.firstIndex(where: { $0.y > point.y }), upper > 0 else {
            return last.band.startFraction
        }
        let low = entries[upper - 1]
        let high = entries[upper]
        let t = (point.y - low.y) / max(1, high.y - low.y)
        return low.band.startFraction
            + (high.band.startFraction - low.band.startFraction) * t
    }

    /// Scrub release always settles on the nearest mark so the stick feels physical.
    private func snapFraction(at point: NSPoint) -> CGFloat {
        let entries = resolvedStack(height: bounds.height)
        if let nearest = entries.min(by: { abs($0.y - point.y) < abs($1.y - point.y) }) {
            return nearest.band.startFraction
        }
        return fraction(at: point)
    }

    private func samplePointerVelocity(at y: CGFloat) {
        let now = CACurrentMediaTime()
        if let last = lastPointerSample {
            let dt = now - last.time
            if dt > 0.001 && dt < 0.25 {
                let raw = (y - last.y) / CGFloat(dt)
                pointerVelocityY = pointerVelocityY * 0.35 + raw * 0.65
            }
        }
        lastPointerSample = (y, now)
    }

    private func setRailBreathe(_ target: CGFloat, animated: Bool) {
        guard abs(breatheSpring.value - target) > 0.001 else { return }
        if animated && !styleSheet.reduceMotion {
            breatheSpring.target(target)
            armRailDriver()
        } else {
            breatheSpring.snap(to: target)
            applySimulations()
        }
    }

    /// The landing punch is a velocity kick on the mark's own width spring:
    /// the swell and its settle come out of the same physics as everything
    /// else, so a jump never announces itself with a distinct easing.
    private func performJumpPunch(at index: Int?) {
        guard let index, index < markSimulations.count else { return }
        markSimulations[index].frame.size.width.kick(Motion.jumpPunchKick)
        markSimulations[index].frame.size.height.kick(Motion.jumpPunchKick * 0.5)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        armRailDriver()
    }

    private func updateHoveredBand(at point: NSPoint?, animated: Bool) {
        let nextIndex: Int?
        if let point, bounds.height > 0 {
            let positions = resolvedStack(height: bounds.height).map(\.y)
            nextIndex = Self.nextHoveredBandIndex(
                at: point.y,
                positions: positions,
                currentIndex: hoveredBandIndex,
                activationSlop: Self.hoverActivationSlop,
                dismissalSlop: Self.dismissalSlop(for: positions)
            )
        } else {
            nextIndex = nil
        }

        let indexChanged = nextIndex != hoveredBandIndex
        hoveredBandIndex = nextIndex
        // The springs *are* the smoothing: retarget on every pointer move and
        // let the display link carry the motion.  With CA, only index changes
        // had to animate (everything else "tracked" via frame-rate snapping);
        // under the spring driver, avoid-a-frame is the same as teleporting.
        if indexChanged || point != nil || pointerLocation != nil {
            updateMarkLayers(animated: animated)
        }
    }

    /// A mark's hover row is half the gap to its neighbour, so the pointer
    /// hands over from one mark to the next with no dead band between them.
    ///
    /// The fixed 4pt row only worked while the pitch was fixed at 10pt: at the
    /// wider pitches an adaptive stack uses, everything from 4pt away to the
    /// neighbour's activation range resolved to "no mark", and the preview
    /// blinked out and back on every crossing.
    static func dismissalSlop(for positions: [CGFloat]) -> CGFloat {
        guard positions.count > 1 else { return hoverDismissalSlop }
        let smallestGap = zip(positions, positions.dropFirst())
            .map { $1 - $0 }
            .min() ?? hoverDismissalSlop
        return max(hoverDismissalSlop, smallestGap / 2)
    }

    static func nextHoveredBandIndex(
        at y: CGFloat,
        positions: [CGFloat],
        currentIndex: Int?,
        activationSlop: CGFloat,
        dismissalSlop: CGFloat
    ) -> Int? {
        guard let nearest = positions.indices.min(by: {
            abs(positions[$0] - y) < abs(positions[$1] - y)
        }) else { return nil }

        if let currentIndex,
           positions.indices.contains(currentIndex) {
            let currentDistance = abs(positions[currentIndex] - y)
            if currentDistance <= dismissalSlop { return currentIndex }
            if nearest == currentIndex { return nil }
        }
        return abs(positions[nearest] - y) <= activationSlop ? nearest : nil
    }

    public override func mouseDown(with event: NSEvent) {
        cancelPreviewHide()
        cancelOutlineShow()
        cancelOutlineHide()
        pointerIsInPreview = false
        pointerIsInOutline = false
        outline.dismiss()
        didDrag = false
        isScrubbing = false
        pointerVelocityY = 0
        lastPointerSample = nil
        let point = convert(event.locationInWindow, from: nil)
        pointerLocation = point
        samplePointerVelocity(at: point.y)
        scrub(to: event, showsSnippet: true, interactive: false)
    }

    public override func mouseDragged(with event: NSEvent) {
        cancelPreviewHide()
        cancelOutlineShow()
        pointerIsInPreview = false
        pointerIsInOutline = false
        if outline.isVisible { outline.dismiss() }
        didDrag = true
        isScrubbing = true
        let point = convert(event.locationInWindow, from: nil)
        pointerLocation = point
        samplePointerVelocity(at: point.y)
        scrub(to: event, showsSnippet: true, interactive: false)
    }

    public override func mouseUp(with event: NSEvent) {
        let wasDragging = didDrag
        isScrubbing = false
        didDrag = false
        let point = convert(event.locationInWindow, from: nil)
        pointerLocation = point
        updateHoveredBand(at: point, animated: true)
        let target = wasDragging ? snapFraction(at: point) : fraction(at: point)
        delegate?.densityGutter(self, didRequestScrollToFraction: target)
        let punchIndex = resolvedStack(height: bounds.height).firstIndex {
            abs($0.band.startFraction - target) < 0.000_1
        } ?? hoveredBandIndex
        performJumpPunch(at: punchIndex)
        pointerVelocityY = 0
        lastPointerSample = nil
        if bounds.contains(point), hoveredBandIndex != nil {
            showPreview(at: point, showsSnippet: true)
        } else {
            cancelPreviewHide()
            preview.hide()
            updateHoveredBand(at: nil, animated: true)
            pointerLocation = nil
        }
        if wasDragging { needsDisplay = true }
    }

    public override func mouseMoved(with event: NSEvent) {
        guard !isScrubbing else { return }
        let point = convert(event.locationInWindow, from: nil)
        cancelPreviewHide()
        pointerIsInPreview = false
        pointerLocation = point
        samplePointerVelocity(at: point.y)
        updateHoveredBand(at: point, animated: true)
        guard hoveredBandIndex != nil else {
            previewWorkItem?.cancel()
            previewWorkItem = nil
            preview.hide()
            return
        }
        if preview.isVisible {
            showPreview(at: point, showsSnippet: true)
        } else {
            schedulePreview(at: point)
        }
    }

    public override func mouseEntered(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        cancelPreviewHide()
        pointerIsInPreview = false
        pointerLocation = point
        setRailBreathe(Self.breatheScale, animated: true)
        // Entering springs like every other pointer move.  Snapping here made
        // the marks teleport into their hovered state while the whole-rail
        // breathe sprang around them — two different motions for one gesture.
        updateHoveredBand(at: point, animated: true)
        if hoveredBandIndex != nil {
            schedulePreview(at: point)
        }
    }

    public override func mouseExited(with event: NSEvent) {
        guard !isScrubbing else { return }
        previewWorkItem?.cancel()
        previewWorkItem = nil
        pointerLocation = nil
        pointerVelocityY = 0
        lastPointerSample = nil
        setRailBreathe(1, animated: true)
        updateMarkLayers(animated: true)
        guard preview.isVisible else {
            updateHoveredBand(at: nil, animated: true)
            return
        }
        schedulePreviewHide()
    }

    public func presentOutlineForKeyboard() {
        guard let window else { return }
        cancelPreviewHide()
        cancelOutlineShow()
        pointerIsInPreview = false
        preview.hide()
        outline.entries = outlineEntries
        outline.show(rightOf: self, over: window, keyboard: true)
    }

    private func schedulePreview(at point: NSPoint) {
        previewWorkItem?.cancel()
        cancelPreviewHide()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.window != nil else { return }
            guard self.pointerLocation == point else { return }
            guard self.bounds.contains(point), !self.bands.isEmpty,
                  self.hoveredBandIndex != nil else {
                self.preview.hide()
                return
            }
            self.showPreview(at: point, showsSnippet: true)
        }
        previewWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverDwell, execute: work)
    }

    private func cancelOutlineShow() {
        outlineWorkItem?.cancel()
        outlineWorkItem = nil
    }

    private func schedulePreviewHide() {
        previewHideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.pointerIsInPreview else { return }
            self.preview.hide()
            self.updateHoveredBand(at: nil, animated: true)
            self.pointerLocation = nil
        }
        previewHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.previewExitDelay, execute: work)
    }

    private func cancelPreviewHide() {
        previewHideWorkItem?.cancel()
        previewHideWorkItem = nil
    }

    private func scheduleOutlineHide() {
        outlineHideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.pointerIsInOutline else { return }
            self.outline.dismiss()
        }
        outlineHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + DensityOutlineWindow.hideDelay, execute: work)
    }

    private func cancelOutlineHide() {
        outlineHideWorkItem?.cancel()
        outlineHideWorkItem = nil
    }

    private func scrub(to event: NSEvent, showsSnippet: Bool, interactive: Bool) {
        let point = convert(event.locationInWindow, from: nil)
        updateHoveredBand(at: point, animated: true)
        delegate?.densityGutter(self, didRequestScrollToFraction: fraction(at: point))
        showPreview(at: point, showsSnippet: showsSnippet, interactive: interactive)
    }

    private func showPreview(
        at point: NSPoint,
        showsSnippet: Bool,
        interactive: Bool = true
    ) {
        guard isScrubbing || hoveredBandIndex != nil else {
            preview.hide()
            return
        }
        guard let window, let content = delegate?.densityGutter(self, previewAtFraction: fraction(at: point)) else {
            preview.hide()
            return
        }
        let anchor = window.convertPoint(toScreen: convert(NSPoint(x: bounds.width, y: point.y), to: nil))
        let maximumTrailingX: CGFloat? = {
            guard let container = superview as? MarkdownContainerView,
                  container.leadingAccessory === self else { return nil }
            let textOrigin = container.scrollView.frame.minX
                + container.scrollView.contentInsets.left
                + RenderMetrics.revealSlack
            let boundary = container.convert(
                NSPoint(x: textOrigin - 12, y: container.bounds.minY),
                to: nil
            )
            return window.convertPoint(toScreen: boundary).x
        }()
        preview.show(
            title: content.title,
            snippet: showsSnippet ? content.snippet : "",
            footer: content.context.isEmpty ? metricsSummary : content.context,
            rightOf: anchor,
            over: window,
            maximumTrailingX: maximumTrailingX,
            reduceMotion: styleSheet.reduceMotion,
            interactive: interactive
        )
    }

    /// A child-window preview does not participate in AppKit view layout.
    /// Re-resolve it when its container moves or resizes so a card that was
    /// valid in the old margin cannot remain over prose in the new geometry.
    func containerGeometryDidChange() {
        guard preview.isVisible else { return }
        guard let point = pointerLocation, bounds.contains(point), hoveredBandIndex != nil else {
            preview.hide()
            return
        }
        showPreview(at: point, showsSnippet: true)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            previewWorkItem?.cancel()
            previewWorkItem = nil
            cancelPreviewHide()
            cancelOutlineShow()
            cancelOutlineHide()
            parkSprings()
            breatheSpring.snap(to: 1)
            pointerLocation = nil
            pointerVelocityY = 0
            lastPointerSample = nil
            pointerIsInPreview = false
            pointerIsInOutline = false
            preview.hide()
            outline.dismiss()
            updateHoveredBand(at: nil, animated: false)
        }
    }

    // MARK: - Band construction

    /// Builds bands from a parsed document plus overlays.  Static so the Quick
    /// Look extension can reuse it (§10) without instantiating a view.
    public static func bands(
        for document: ParsedDocument,
        changes: [(ChangeKind, NSRange)],
        searchHits: [NSRange]
    ) -> [DensityBand] {
        let length = CGFloat(max(1, document.length))
        func band(_ kind: DensityBand.Kind, _ range: NSRange) -> DensityBand {
            let start = min(1, max(0, CGFloat(range.location) / length))
            let end = min(1, max(start, CGFloat(range.upperBound) / length))
            return DensityBand(kind: kind, startFraction: start, endFraction: end)
        }

        var result: [DensityBand] = []
        document.root.walkPruning { block in
            switch block.content {
            case .heading(let level):
                result.append(band(.heading(level: level), block.range))
                return false
            case .codeBlock:
                result.append(band(.codeBlock, block.range))
                return false
            case .mermaid:
                // A diagram is a figure, not code, once it is rendered (§6.2).
                result.append(band(.image, block.range))
                return false
            case .mathBlock:
                result.append(band(.math, block.range))
                return false
            case .table:
                result.append(band(.table, block.range))
                return false
            case .callout:
                // Pruned: a callout is a single visual object in the rail even
                // when it contains a list, and nesting bands inside bands makes
                // a 14pt track unreadable.
                result.append(band(.callout, block.range))
                return false
            case .list:
                guard containsCheckbox(block) else { return true }
                result.append(band(.taskList, block.range))
                return false
            case .paragraph:
                if containsImage(block) { result.append(band(.image, block.range)) }
                return false
            default:
                return true
            }
        }

        for (kind, range) in changes { result.append(band(.change(kind), range)) }
        for hit in searchHits { result.append(band(.searchHit, hit)) }
        return result
    }

    private static func containsCheckbox(_ block: MDBlock) -> Bool {
        block.children.contains { child in
            if case .listItem(_, let checkbox) = child.content { return checkbox != nil }
            return false
        }
    }

    private static func containsImage(_ block: MDBlock) -> Bool {
        var found = false
        for inline in block.inlines {
            inline.walk { span in
                if case .image = span.kind { found = true }
            }
            if found { break }
        }
        return found
    }
}
