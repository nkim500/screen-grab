import Testing
import Foundation
@testable import AudioCapture

@Test func audioBufferStoresSamplesAndDuration() {
    let buf = AudioBuffer(samples: [0.1, 0.2, 0.3], durationMs: 60)
    #expect(buf.samples == [0.1, 0.2, 0.3])
    #expect(buf.durationMs == 60)
}

@Test func audioBufferEmptyIsValid() {
    let buf = AudioBuffer(samples: [], durationMs: 0)
    #expect(buf.samples.isEmpty)
    #expect(buf.durationMs == 0)
}

@Test func audioCaptureErrorDescriptions() {
    #expect(String(describing: AudioCaptureError.permissionDenied).contains("permission"))
    #expect(String(describing: AudioCaptureError.deviceUnavailable).contains("unavailable"))
}
