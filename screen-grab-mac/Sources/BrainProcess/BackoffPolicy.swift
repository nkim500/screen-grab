import Foundation

public struct BackoffPolicy: Equatable, Sendable {
    public let delays: [TimeInterval]      // length == maxAttempts
    public let maxAttempts: Int
    public let healthyThreshold: TimeInterval

    public init(delays: [TimeInterval], maxAttempts: Int, healthyThreshold: TimeInterval) {
        precondition(delays.count == maxAttempts, "delays.count must equal maxAttempts")
        self.delays = delays
        self.maxAttempts = maxAttempts
        self.healthyThreshold = healthyThreshold
    }

    /// 1s, 2s, 4s, 8s, 16s, then 30s capped through attempt 10.
    /// Counter resets after 5s of healthy uptime.
    public static let `default` = BackoffPolicy(
        delays: [1, 2, 4, 8, 16, 30, 30, 30, 30, 30],
        maxAttempts: 10,
        healthyThreshold: 5
    )
}

public struct BackoffState: Equatable {
    public let policy: BackoffPolicy
    public private(set) var attempt: Int = 0
    private var lastStartedAt: Date?

    public init(policy: BackoffPolicy) {
        self.policy = policy
    }

    /// Call when the process is (re)started. Used to time healthy uptime.
    public mutating func recordStart(at now: Date) {
        lastStartedAt = now
    }

    /// Call when the process has been observed healthy for some uptime.
    /// If uptime exceeds the policy threshold, reset the attempt counter.
    public mutating func recordHealthy(at now: Date) {
        guard let started = lastStartedAt else { return }
        if now.timeIntervalSince(started) >= policy.healthyThreshold {
            attempt = 0
        }
    }

    /// Call when the process exits. Returns the delay before the next start
    /// attempt, or nil if max attempts are exhausted.
    @discardableResult
    public mutating func recordExit(at now: Date) -> TimeInterval? {
        // First, see if recent uptime would have reset the counter.
        recordHealthy(at: now)
        let idx = attempt
        if idx >= policy.maxAttempts { return nil }
        let delay = policy.delays[idx]
        attempt += 1
        return delay
    }

    public mutating func reset() {
        attempt = 0
        lastStartedAt = nil
    }
}
