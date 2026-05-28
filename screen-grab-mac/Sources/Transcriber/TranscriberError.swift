import Foundation

public enum TranscriberError: Error, Equatable, CustomStringConvertible {
    case empty
    case permissionDenied
    case engineFailed(message: String)
    case timeout

    public var description: String {
        switch self {
        case .empty:                   return "Didn't catch anything — try again"
        case .permissionDenied:        return "Speech Recognition permission denied. System Settings → Privacy & Security → Speech Recognition."
        case .engineFailed(let m):     return "Speech recognition failed: \(m)"
        case .timeout:                 return "Transcription timed out"
        }
    }
}
