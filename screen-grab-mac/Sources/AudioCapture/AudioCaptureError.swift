import Foundation

public enum AudioCaptureError: Error, CustomStringConvertible {
    case permissionDenied
    case deviceUnavailable
    case engineFailed(Error)

    public var description: String {
        switch self {
        case .permissionDenied:
            return "Microphone permission denied. Grant in System Settings → Privacy & Security → Microphone."
        case .deviceUnavailable:
            return "Microphone unavailable."
        case .engineFailed(let err):
            return "Audio engine failed: \(err)"
        }
    }
}
