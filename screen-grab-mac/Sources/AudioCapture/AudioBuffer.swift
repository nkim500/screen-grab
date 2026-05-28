import Foundation

/// 16kHz mono Float32 PCM samples accumulated during a single capture session.
public struct AudioBuffer: Equatable {
    public let samples: [Float]
    public let durationMs: Int

    public init(samples: [Float], durationMs: Int) {
        self.samples = samples
        self.durationMs = durationMs
    }

    public static let empty = AudioBuffer(samples: [], durationMs: 0)
}
