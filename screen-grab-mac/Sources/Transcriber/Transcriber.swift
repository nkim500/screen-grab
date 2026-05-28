import Foundation
import AudioCapture

public protocol Transcriber {
    /// e.g. "apple-speech", "whisper-cpp", "whisper-api"
    var name: String { get }
    func transcribe(_ buffer: AudioBuffer) async throws -> Transcript
}
