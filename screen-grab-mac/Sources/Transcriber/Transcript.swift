import Foundation

public struct Transcript: Equatable {
    public let text: String
    public let locale: String
    public let confidence: Float?

    public init(text: String, locale: String, confidence: Float? = nil) {
        self.text = text
        self.locale = locale
        self.confidence = confidence
    }
}
