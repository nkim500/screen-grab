import Testing
import Foundation
@testable import BrainProcess

@Test func defaultDelaysExponentialThenCapped() {
    let p = BackoffPolicy.default
    #expect(p.delays == [1, 2, 4, 8, 16, 30, 30, 30, 30, 30])
    #expect(p.maxAttempts == 10)
    #expect(p.healthyThreshold == 5)
}

@Test func nextDelayReturnsValuesUntilExhausted() {
    let p = BackoffPolicy.default
    var s = BackoffState(policy: p)
    let now = Date(timeIntervalSince1970: 0)
    let actual = (0..<11).map { _ in s.recordExit(at: now) }
    #expect(actual == [1, 2, 4, 8, 16, 30, 30, 30, 30, 30, nil])
}

@Test func recordHealthyResetsCounterIfUptimeExceedsThreshold() {
    let p = BackoffPolicy.default
    var s = BackoffState(policy: p)
    let t0 = Date(timeIntervalSince1970: 0)
    _ = s.recordExit(at: t0) // attempt 1
    _ = s.recordExit(at: t0) // attempt 2
    s.recordStart(at: t0.addingTimeInterval(0.1))
    s.recordHealthy(at: t0.addingTimeInterval(6.0)) // > 5s healthy uptime
    let next = s.recordExit(at: t0.addingTimeInterval(7.0))
    #expect(next == 1) // counter reset
    #expect(s.attempt == 1)
}

@Test func healthyShorterThanThresholdDoesNotReset() {
    let p = BackoffPolicy.default
    var s = BackoffState(policy: p)
    let t0 = Date(timeIntervalSince1970: 0)
    _ = s.recordExit(at: t0)
    _ = s.recordExit(at: t0)
    s.recordStart(at: t0.addingTimeInterval(0.1))
    s.recordHealthy(at: t0.addingTimeInterval(2.0)) // < 5s
    let next = s.recordExit(at: t0.addingTimeInterval(3.0))
    #expect(next == 4) // attempt 3
}

@Test func resetReturnsCounterToZero() {
    var s = BackoffState(policy: .default)
    _ = s.recordExit(at: Date())
    _ = s.recordExit(at: Date())
    s.reset()
    #expect(s.attempt == 0)
}
