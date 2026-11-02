import Foundation

/// Aggregate, device-local eligibility only. No paths, document contents, or
/// GitHub identity are retained, and an offer never resets with an app update.
struct StarPromptUsage: Codable, Equatable {
    static let requiredOpens = 5
    static let requiredForegroundSeconds: TimeInterval = 10 * 60

    enum OpenOrigin {
        case user, restoration, tour
    }

    private(set) var documentOpens = 0
    private(set) var foregroundSeconds: TimeInterval = 0
    private(set) var hasBeenOffered = false

    var isEligible: Bool {
        !hasBeenOffered && documentOpens >= Self.requiredOpens
            && foregroundSeconds >= Self.requiredForegroundSeconds
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        documentOpens = min(Self.requiredOpens, max(0,
            try values.decodeIfPresent(Int.self, forKey: .documentOpens) ?? 0
        ))
        let seconds = try values.decodeIfPresent(TimeInterval.self, forKey: .foregroundSeconds) ?? 0
        foregroundSeconds = seconds.isFinite ? min(Self.requiredForegroundSeconds, max(0, seconds)) : 0
        hasBeenOffered = try values.decodeIfPresent(Bool.self, forKey: .hasBeenOffered) ?? false
    }

    mutating func recordOpen(origin: OpenOrigin) {
        guard !hasBeenOffered, origin == .user else { return }
        documentOpens = min(Self.requiredOpens, documentOpens + 1)
    }

    mutating func recordForegroundTime(_ seconds: TimeInterval) {
        guard !hasBeenOffered, seconds.isFinite, seconds > 0 else { return }
        foregroundSeconds = min(Self.requiredForegroundSeconds, foregroundSeconds + seconds)
    }

    mutating func retire() { hasBeenOffered = true }
}

/// Only consecutive visible/active samples count. Focus transitions discard
/// their partial interval so time in another app cannot make the offer eligible.
struct StarPromptReadingClock {
    private var previous: (time: TimeInterval, isReading: Bool)?

    mutating func sample(at time: TimeInterval, isReading: Bool) -> TimeInterval {
        defer { previous = (time, isReading) }
        guard let previous, previous.isReading, isReading else { return 0 }
        return max(0, time - previous.time)
    }
}
