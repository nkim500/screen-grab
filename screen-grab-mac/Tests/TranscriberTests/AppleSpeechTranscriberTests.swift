#if INTEGRATION
import Testing
import Foundation
@testable import Transcriber
@testable import AudioCapture

// Run only when -DINTEGRATION is set:
//   swift test -Xswiftc -DINTEGRATION --filter AppleSpeechTranscriberTests
//
// Requires Speech Recognition permission already granted to the test
// runner. Will throw .permissionDenied otherwise.

@Test func transcribeEmptyBufferThrowsEmpty() async {
    let t = AppleSpeechTranscriber(timeoutSeconds: 1)
    await #expect(throws: TranscriberError.empty) {
        _ = try await t.transcribe(.empty)
    }
}

@Test func transcribeSilencePcmTimesOutWithinBudget() async {
    let t = AppleSpeechTranscriber(timeoutSeconds: 1)
    // 0.5s of silence at 16kHz
    let silence = [Float](repeating: 0, count: 8000)
    let buf = AudioBuffer(samples: silence, durationMs: 500)
    do {
        let result = try await t.transcribe(buf)
        // Apple Speech may return empty or a noise-floor word; either is acceptable.
        Issue.record("did not expect a successful transcript from silence: \(result.text)")
    } catch TranscriberError.empty {
        // OK
    } catch TranscriberError.timeout {
        // OK
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}
#endif
