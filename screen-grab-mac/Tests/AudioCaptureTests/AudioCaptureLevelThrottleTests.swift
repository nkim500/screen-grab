import Testing
import Foundation
@testable import AudioCapture

@Test func levelThrottleEmitsAtMostOnePerWindowMs() {
    let throttle = AudioLevelThrottle(windowMs: 33)
    let now = DispatchTime.now()
    #expect(throttle.shouldEmit(at: now) == true)             // first sample fires
    #expect(throttle.shouldEmit(at: now + .milliseconds(10)) == false) // within window
    #expect(throttle.shouldEmit(at: now + .milliseconds(40)) == true)  // after window
}

@Test func levelThrottleResetsAfterEmit() {
    let throttle = AudioLevelThrottle(windowMs: 33)
    let now = DispatchTime.now()
    _ = throttle.shouldEmit(at: now)
    #expect(throttle.shouldEmit(at: now + .milliseconds(34)) == true)
    #expect(throttle.shouldEmit(at: now + .milliseconds(40)) == false)
}

@Test func stopWithoutStartReturnsEmptyBuffer() {
    let capture = AudioCapture()
    let buf = capture.stop()
    #expect(buf == AudioBuffer.empty)
}

@Test func isRecordingFalseInitially() {
    let capture = AudioCapture()
    #expect(capture.isRecording == false)
}
