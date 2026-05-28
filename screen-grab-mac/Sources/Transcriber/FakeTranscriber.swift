import Foundation
import AudioCapture

/// Test helper. Lives in the production target so AppDelegate-flow tests in
/// other modules can import it.
public final class FakeTranscriber: Transcriber {
    public let name = "fake"
    public var nextResult: Result<Transcript, TranscriberError> = .success(
        Transcript(text: "", locale: "en-US", confidence: nil)
    )
    public private(set) var lastBufferReceived: AudioBuffer?

    public init() {}

    public func transcribe(_ buffer: AudioBuffer) async throws -> Transcript {
        lastBufferReceived = buffer
        switch nextResult {
        case .success(let t): return t
        case .failure(let e): throw e
        }
    }
}
