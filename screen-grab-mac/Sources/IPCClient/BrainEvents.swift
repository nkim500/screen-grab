import Foundation

public enum BrainEvent: Decodable, Equatable {
    case delta(reqId: String, text: String)
    case done(reqId: String, promptTokens: Int, completionTokens: Int)
    case error(reqId: String, message: String)
    case unknown(rawType: String?)

    private enum CodingKeys: String, CodingKey {
        case type, reqId, text, promptTokens, completionTokens, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try? c.decode(String.self, forKey: .type)
        switch type {
        case "delta":
            self = .delta(
                reqId: try c.decode(String.self, forKey: .reqId),
                text: try c.decode(String.self, forKey: .text)
            )
        case "done":
            self = .done(
                reqId: try c.decode(String.self, forKey: .reqId),
                promptTokens: try c.decode(Int.self, forKey: .promptTokens),
                completionTokens: try c.decode(Int.self, forKey: .completionTokens)
            )
        case "error":
            self = .error(
                reqId: try c.decode(String.self, forKey: .reqId),
                message: try c.decode(String.self, forKey: .message)
            )
        default:
            self = .unknown(rawType: type)
        }
    }
}

public enum FeedbackEvent: String, Codable {
    case accepted, edited, regenerated, dismissed, error
}

public struct FeedbackMessage: Encodable {
    public let type: String = "feedback"
    public let reqId: String
    public let event: FeedbackEvent
    public let finalText: String?
    public let durationFromGenToCloseMs: Int?

    public init(reqId: String, event: FeedbackEvent, finalText: String?, durationFromGenToCloseMs: Int?) {
        self.reqId = reqId
        self.event = event
        self.finalText = finalText
        self.durationFromGenToCloseMs = durationFromGenToCloseMs
    }
}
