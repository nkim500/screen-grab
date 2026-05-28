import Foundation
import Speech
import AVFoundation
import struct AudioCapture.AudioBuffer
import class AudioCapture.AudioCapture

public final class AppleSpeechTranscriber: Transcriber {
    public let name = "apple-speech"
    private let locale: Locale
    private let timeoutSeconds: TimeInterval

    public init(locale: Locale = .current, timeoutSeconds: TimeInterval = 5) {
        self.locale = locale
        self.timeoutSeconds = timeoutSeconds
    }

    public func transcribe(_ buffer: AudioBuffer) async throws -> Transcript {
        if buffer.samples.isEmpty {
            throw TranscriberError.empty
        }
        // Permission check first — Apple Speech requires its own TCC bucket
        // separate from microphone. AppDelegate requests at launch but if it
        // wasn't granted yet, fail loudly here rather than silently.
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: break
        case .notDetermined, .denied, .restricted:
            throw TranscriberError.permissionDenied
        @unknown default:
            throw TranscriberError.permissionDenied
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw TranscriberError.engineFailed(message: "recognizer unavailable for locale \(locale.identifier)")
        }
        // Diagnostic line: when "No speech detected" recurs, the log shows
        // which locale the daemon picked and whether the recognizer is using
        // on-device or server-side. Pairs with the rms= field in the
        // [audio] stop log line to distinguish silence-in-buffer from
        // signal-rejected-by-VAD.
        NSLog("[screen-grab][stt] locale=\(recognizer.locale.identifier) onDevice=\(recognizer.supportsOnDeviceRecognition) buffer=\(buffer.samples.count) samples")

        // Try on-device first if supported (privacy preserving, low latency).
        // If that fails with .empty (Apple's VAD said no speech) or
        // .engineFailed (kAFAssistantErrorDomain 1110 surfaces here), retry
        // once via server-side recognition. On-device models on macOS are
        // documented to be less robust than server-side for short utterances.
        let preferOnDevice = recognizer.supportsOnDeviceRecognition
        do {
            return try await runRecognition(recognizer: recognizer, buffer: buffer, onDevice: preferOnDevice)
        } catch TranscriberError.empty, TranscriberError.engineFailed {
            if !preferOnDevice { throw TranscriberError.empty }
            NSLog("[screen-grab][stt] on-device recognition failed; retrying server-side")
            return try await runRecognition(recognizer: recognizer, buffer: buffer, onDevice: false)
        }
    }

    private func runRecognition(
        recognizer: SFSpeechRecognizer,
        buffer: AudioBuffer,
        onDevice: Bool
    ) async throws -> Transcript {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        if #available(macOS 13.0, *) {
            request.requiresOnDeviceRecognition = onDevice
        }

        // Convert samples → AVAudioPCMBuffer and append to the request, then
        // signal end-of-audio. SFSpeechRecognizer will emit isFinal once it
        // has chewed through the buffer.
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw TranscriberError.engineFailed(message: "AVAudioFormat init failed")
        }
        let frameCount = AVAudioFrameCount(buffer.samples.count)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw TranscriberError.engineFailed(message: "AVAudioPCMBuffer alloc failed")
        }
        pcm.frameLength = frameCount
        buffer.samples.withUnsafeBufferPointer { src in
            pcm.floatChannelData?[0].update(from: src.baseAddress!, count: src.count)
        }
        request.append(pcm)
        request.endAudio()

        return try await withThrowingTaskGroup(of: Transcript.self) { group in
            group.addTask { [timeoutSeconds] in
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw TranscriberError.timeout
            }
            group.addTask {
                try await Self.awaitFinalResult(recognizer: recognizer, request: request)
            }
            // Whichever completes first wins; cancel the loser.
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private static func awaitFinalResult(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest
    ) async throws -> Transcript {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Transcript, Error>) in
            var resumed = false
            let task = recognizer.recognitionTask(with: request) { result, error in
                if resumed { return }
                if let error = error {
                    resumed = true
                    cont.resume(throwing: TranscriberError.engineFailed(message: String(describing: error)))
                    return
                }
                guard let result = result else { return }
                if result.isFinal {
                    resumed = true
                    let text = result.bestTranscription.formattedString
                    if text.isEmpty {
                        cont.resume(throwing: TranscriberError.empty)
                    } else {
                        let conf = result.bestTranscription.segments.first?.confidence
                        cont.resume(returning: Transcript(text: text, locale: recognizer.locale.identifier, confidence: conf))
                    }
                }
            }
            // Keep `task` alive in case of cancellation by the timeout group.
            _ = task
        }
    }
}
