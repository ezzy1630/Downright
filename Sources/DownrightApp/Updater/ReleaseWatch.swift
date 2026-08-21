import AppKit
import CryptoKit
import Foundation
import Network

/// What one conditional probe of the appcast learned.
enum ReleaseFeedProbeResult: Equatable {
    /// Byte-identical to the last feed this session saw.
    case unchanged
    /// The feed moved.  `validator` is the token to send back next time.
    case changed(validator: String?)
    /// The probe could not complete.  Never surfaced: a laptop opened without
    /// wifi is not an update failure, and `UpdateCoordinator` already refuses
    /// to raise that alarm for background cycles.
    case unreachable
}

/// One conditional GET.  A protocol so the watch's whole schedule can be
/// tested without a network, a server, or a wall clock.
@MainActor
protocol ReleaseFeedProbe: AnyObject {
    func probe(feed: URL, validator: String?) async -> ReleaseFeedProbeResult
}

// MARK: - Policy

/// When the watch may probe, and how often.
///
/// Pure policy, deliberately kept apart from the timer that obeys it: every
/// rule here is then a value comparison in a test rather than a wait.
struct ReleaseWatchPolicy: Equatable {
    /// Frontmost and in use.  A build that lands while the reader is sitting
    /// here should be offered while they are still sitting here.
    static let activeInterval: TimeInterval = 90
    /// Running, but the reader is in another app.  Still worth knowing before
    /// they come back; not worth waking the radio on their behalf.
    static let backgroundInterval: TimeInterval = 15 * 60
    /// The floor between two probes, however many events coincide.  Wake fires
    /// activate as well, and a held Cmd-Tab flaps activation several times a
    /// second; without a floor each of those becomes its own request.
    static let minimumSpacing: TimeInterval = 20

    var isAppActive = false
    var isLowPower = false
    var hasNetwork = true

    /// `nil` means "do not probe at all right now".
    var interval: TimeInterval? {
        guard hasNetwork else { return nil }
        // Low Power Mode is an explicit request to stop doing optional work.
        // Polling for a build the reader has not asked for is exactly that, so
        // the background cadence stops entirely and the foreground one drops
        // to it — Sparkle's own hourly schedule still covers the app.
        if isLowPower { return isAppActive ? Self.backgroundInterval : nil }
        return isAppActive ? Self.activeInterval : Self.backgroundInterval
    }
}

// MARK: - Watch

/// Notices that the appcast moved, so a build published while the app is open
/// is offered in about a minute instead of on Sparkle's next scheduled check.
///
/// The important line, and the reason this can be as cheap as it is: **the
/// watch is a trigger, not a trust path.**  It learns exactly one bit — the
/// feed is not the one we last saw — and hands that to Sparkle.  It never
/// parses the appcast, never compares versions, never reads an enclosure URL,
/// and cannot cause an install.  Every signature check, ordering decision, and
/// download stays inside Sparkle, so shortening the *latency* of an update
/// leaves the *security model* of one untouched.
@MainActor
final class ReleaseWatch {
    /// Why a probe is happening.  Only `.scheduled` is exempt from the spacing
    /// floor, because the schedule already spaces itself.
    private enum ProbeReason {
        case scheduled
        case event
    }

    /// Called when the feed has moved since the baseline.  Never called for
    /// the probe that establishes the baseline.
    var onFeedChanged: (() -> Void)?

    /// Test seam: how many probes have completed, and what the last one said.
    private(set) var completedProbeCount = 0
    private(set) var lastResult: ReleaseFeedProbeResult?
    private(set) var hasBaseline = false

    private let feed: URL
    private let prober: any ReleaseFeedProbe
    private(set) var policy = ReleaseWatchPolicy()

    private var isRunning = false
    private var isProbing = false
    private var validator: String?
    private var lastProbeDate: Date?
    private var pending: DispatchWorkItem?
    /// Tokens are paired with the centre that issued them: the wake
    /// notification comes from the workspace centre, and handing its token to
    /// the default centre to remove is a silent no-op that leaks the observer.
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var pathMonitor: NWPathMonitor?

    init(feed: URL, prober: (any ReleaseFeedProbe)? = nil) {
        self.feed = feed
        self.prober = prober ?? ReleaseFeedURLProbe()
    }

    deinit {
        pending?.cancel()
        pathMonitor?.cancel()
        for (center, observer) in observers { center.removeObserver(observer) }
    }

    // MARK: Lifecycle

    /// Begins watching.  Safe to call twice; the second call is a no-op.
    func start(observingSystemEvents: Bool = true) {
        guard !isRunning else { return }
        isRunning = true
        policy.isAppActive = NSApp?.isActive ?? false
        policy.isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        if observingSystemEvents { observeSystemEvents() }
        // The first probe establishes the baseline rather than firing, so it
        // can go out immediately without racing Sparkle's post-launch check.
        probe(reason: .event)
    }

    func stop() {
        isRunning = false
        pending?.cancel()
        pending = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
    }

    // MARK: Inputs (also the test seam — every one of these is callable directly)

    func applicationDidChangeActivation(isActive: Bool) {
        guard policy.isAppActive != isActive else { return }
        policy.isAppActive = isActive
        // Coming back to the app is the moment a pending build matters most;
        // leaving it only changes the cadence.
        if isActive { probe(reason: .event) } else { scheduleNext() }
    }

    func systemDidWake() {
        // The feed almost certainly moved across a closed lid, and the
        // schedule that would have caught it did not fire while asleep.
        probe(reason: .event)
    }

    func powerStateDidChange(isLowPower: Bool) {
        guard policy.isLowPower != isLowPower else { return }
        policy.isLowPower = isLowPower
        scheduleNext()
    }

    func networkAvailabilityDidChange(hasNetwork: Bool) {
        guard policy.hasNetwork != hasNetwork else { return }
        policy.hasNetwork = hasNetwork
        if hasNetwork { probe(reason: .event) } else { scheduleNext() }
    }

    /// Ignores the spacing floor.  Only for tests and the debug feed override.
    func probeNow() {
        lastProbeDate = nil
        probe(reason: .event)
    }

    // MARK: Scheduling

    private func scheduleNext() {
        pending?.cancel()
        pending = nil
        guard isRunning, let interval = policy.interval else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.probe(reason: .scheduled) }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
    }

    private func probe(reason: ProbeReason) {
        guard isRunning, policy.interval != nil, !isProbing else { return }
        if reason == .event, let last = lastProbeDate,
           Date().timeIntervalSince(last) < ReleaseWatchPolicy.minimumSpacing {
            // Too soon.  Fall back to the schedule rather than dropping the
            // event entirely, or a burst of activations can leave no timer.
            if pending == nil { scheduleNext() }
            return
        }
        isProbing = true
        lastProbeDate = Date()
        pending?.cancel()
        pending = nil
        let feed = self.feed
        let validator = self.validator
        let prober = self.prober
        Task { @MainActor [weak self] in
            let result = await prober.probe(feed: feed, validator: validator)
            self?.probeDidFinish(result)
        }
    }

    private func probeDidFinish(_ result: ReleaseFeedProbeResult) {
        isProbing = false
        completedProbeCount += 1
        lastResult = result
        if case .changed(let newValidator) = result {
            validator = newValidator
            if hasBaseline {
                onFeedChanged?()
            } else {
                // Sparkle's own post-launch check already answers "was an
                // update waiting when you opened the app". Firing here as well
                // would ask the same feed the same question twice.
                hasBaseline = true
            }
        }
        scheduleNext()
    }

    // MARK: System events

    private func observeSystemEvents() {
        let center = NotificationCenter.default
        observers.append((center, center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applicationDidChangeActivation(isActive: true) }
        }))
        observers.append((center, center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applicationDidChangeActivation(isActive: false) }
        }))
        observers.append((center, center.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            let low = ProcessInfo.processInfo.isLowPowerModeEnabled
            MainActor.assumeIsolated { self?.powerStateDidChange(isLowPower: low) }
        }))
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemDidWake() }
        }))

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.networkAvailabilityDidChange(hasNetwork: satisfied)
            }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }
}

// MARK: - Production probe

/// One conditional GET against the appcast, and nothing else.
///
/// Deliberately the smallest request that can answer the question: no
/// cookies, no credentials, no cache of its own, no identifiers, and an
/// unchanged feed answers `304` with an empty body.  It reads the feed only
/// far enough to know *that* it moved — never what it says.
final class ReleaseFeedURLProbe: ReleaseFeedProbe {
    /// A feed larger than this is not one this app publishes; refuse to hash
    /// an unbounded body just to learn one bit.
    private static let maximumBodyBytes = 4 * 1024 * 1024

    private let session: URLSession

    /// `session` is a test seam: production uses the locked-down ephemeral
    /// configuration; tests inject one backed by a stub URLProtocol.
    init(session: URLSession = URLSession(configuration: ReleaseFeedURLProbe.makeConfiguration())) {
        self.session = session
    }

    nonisolated private static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        // The validators below are the cache; a URL cache on top of them only
        // adds a second staleness policy that can hold a fresh feed back.
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = false
        return configuration
    }

    func probe(feed: URL, validator: String?) async -> ReleaseFeedProbeResult {
        var request = URLRequest(url: feed)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // An ETag round-trips verbatim, and so does a stored document date.
        // A body hash is ours, not the server's, so it must never be offered
        // as either.
        if let validator, validator.hasPrefix(Self.etagPrefix) {
            request.setValue(
                String(validator.dropFirst(Self.etagPrefix.count)),
                forHTTPHeaderField: "If-None-Match"
            )
        } else if let validator, validator.hasPrefix(Self.lastModifiedPrefix) {
            request.setValue(
                String(validator.dropFirst(Self.lastModifiedPrefix.count)),
                forHTTPHeaderField: "If-Modified-Since"
            )
        }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else {
            return .unreachable
        }
        if http.statusCode == 304 { return .unchanged }
        guard (200..<300).contains(http.statusCode) else { return .unreachable }
        guard data.count <= Self.maximumBodyBytes else { return .unreachable }

        let fresh = Self.validator(for: http, body: data)
        return fresh == validator ? .unchanged : .changed(validator: fresh)
    }

    private static let etagPrefix = "etag:"
    private static let lastModifiedPrefix = "lastModified:"

    /// Prefer the server's own validator; fall back to the document date,
    /// which keeps conditional requests working on a host that serves no
    /// `ETag`; fall back further to hashing the body, which keeps the watch
    /// working on a host that serves neither.
    private static func validator(for response: HTTPURLResponse, body: Data) -> String {
        if let etag = response.value(forHTTPHeaderField: "ETag"), !etag.isEmpty {
            return etagPrefix + etag
        }
        if let lastModified = response.value(forHTTPHeaderField: "Last-Modified"),
           !lastModified.isEmpty {
            return lastModifiedPrefix + lastModified
        }
        let digest = SHA256.hash(data: body)
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }
}
