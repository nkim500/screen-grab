import Testing
import Foundation
@testable import Transcriber
@testable import AudioCapture

@Test func fakeTranscriberReturnsConfiguredTranscript() async throws {
    let fake = FakeTranscriber()
    fake.nextResult = .success(Transcript(text: "hello world", locale: "en-US", confidence: nil))
    let buf = AudioBuffer(samples: [0.1, 0.2], durationMs: 100)
    let transcript = try await fake.transcribe(buf)
    #expect(transcript.text == "hello world")
    #expect(transcript.locale == "en-US")
}

@Test func fakeTranscriberThrowsConfiguredError() async {
    let fake = FakeTranscriber()
    fake.nextResult = .failure(TranscriberError.empty)
    let buf = AudioBuffer.empty
    await #expect(throws: TranscriberError.empty) {
        _ = try await fake.transcribe(buf)
    }
}

@Test func fakeTranscriberRecordsLastBuffer() async throws {
    let fake = FakeTranscriber()
    fake.nextResult = .success(Transcript(text: "x", locale: "en-US", confidence: nil))
    let buf = AudioBuffer(samples: [0.5], durationMs: 100)
    _ = try await fake.transcribe(buf)
    #expect(fake.lastBufferReceived?.samples == [0.5])
}
