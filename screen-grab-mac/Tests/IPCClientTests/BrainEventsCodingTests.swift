import Testing
import Foundation
@testable import IPCClient

@Suite("BrainEvent Codable")
struct BrainEventsCodingTests {
    @Test func decodeDelta() throws {
        let json = #"{"type":"delta","reqId":"abc","text":"Hello"}"#.data(using: .utf8)!
        let ev = try JSONDecoder().decode(BrainEvent.self, from: json)
        guard case .delta(let reqId, let text) = ev else {
            Issue.record("not a delta")
            return
        }
        #expect(reqId == "abc")
        #expect(text == "Hello")
    }

    @Test func decodeDone() throws {
        let json = #"{"type":"done","reqId":"abc","promptTokens":100,"completionTokens":50}"#.data(using: .utf8)!
        let ev = try JSONDecoder().decode(BrainEvent.self, from: json)
        guard case .done(let reqId, let prompt, let completion) = ev else {
            Issue.record("not a done")
            return
        }
        #expect(reqId == "abc")
        #expect(prompt == 100)
        #expect(completion == 50)
    }

    @Test func decodeError() throws {
        let json = #"{"type":"error","reqId":"abc","message":"rate limited"}"#.data(using: .utf8)!
        let ev = try JSONDecoder().decode(BrainEvent.self, from: json)
        guard case .error(let reqId, let message) = ev else {
            Issue.record("not an error")
            return
        }
        #expect(reqId == "abc")
        #expect(message == "rate limited")
    }

    @Test func decodeUnknownTypeReturnsUnknown() throws {
        let json = #"{"type":"weather","reqId":"abc"}"#.data(using: .utf8)!
        let ev = try JSONDecoder().decode(BrainEvent.self, from: json)
        guard case .unknown = ev else {
            Issue.record("not unknown")
            return
        }
    }

    @Test func encodeFeedbackAccepted() throws {
        let msg = FeedbackMessage(reqId: "abc", event: .accepted, finalText: "hi", durationFromGenToCloseMs: 1000)
        let data = try JSONEncoder().encode(msg)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["type"] as? String == "feedback")
        #expect(obj?["reqId"] as? String == "abc")
        #expect(obj?["event"] as? String == "accepted")
        #expect(obj?["finalText"] as? String == "hi")
        #expect(obj?["durationFromGenToCloseMs"] as? Int == 1000)
    }

    @Test func encodeFeedbackDismissedOmitsFinal() throws {
        let msg = FeedbackMessage(reqId: "abc", event: .dismissed, finalText: nil, durationFromGenToCloseMs: 100)
        let data = try JSONEncoder().encode(msg)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["event"] as? String == "dismissed")
        // finalText: encoder either omits or emits null. Both are valid for brain.
        #expect(obj?["finalText"] == nil || obj?["finalText"] is NSNull)
    }

    @Test func feedbackEventErrorEncodesCorrectly() throws {
        let msg = FeedbackMessage(reqId: "r1", event: .error, finalText: nil, durationFromGenToCloseMs: 100)
        let data = try JSONEncoder().encode(msg)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"event\":\"error\""))
        #expect(json.contains("\"reqId\":\"r1\""))
    }
}
