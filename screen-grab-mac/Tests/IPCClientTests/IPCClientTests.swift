import Testing
import Foundation
@testable import IPCClient
@testable import ContextCapture

private final class FakeConnection: Connection {
    var sent: [Data] = []
    var onReceive: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?
    func send(_ data: Data) { sent.append(data) }
    func close() { onClose?(nil) }
    /// Simulate the brain replying.
    func feed(_ s: String) { onReceive?(Data(s.utf8)) }
}

@Suite("IPCClient via fake Connection")
struct IPCClientTests {
    @Test func framedConnectionDispatchesParsedEvents() {
        let fake = FakeConnection()
        let framed = LineFramedConnection(fake)

        var lines: [String] = []
        framed.onLine = { data in
            lines.append(String(data: data, encoding: .utf8) ?? "")
        }

        fake.feed("{\"type\":\"delta\",\"reqId\":\"a\",\"text\":\"He\"}\n")
        fake.feed("{\"type\":\"delta\",\"req")
        fake.feed("Id\":\"a\",\"text\":\"llo\"}\n{\"type\":\"done\",\"reqId\":\"a\",\"promptTokens\":1,\"completionTokens\":2}\n")

        #expect(lines.count == 3)
        #expect(lines[0].contains("\"He\""))
        #expect(lines[1].contains("\"llo\""))
        #expect(lines[2].contains("done"))
    }

    @Test func sendGenerateWritesAJSONLine() throws {
        let fake = FakeConnection()
        let framed = LineFramedConnection(fake)
        let req = BrainRequest(
            reqId: "id-1", app: "Mail", windowTitle: "Reply", intent: .draft,
            axTree: AXTree(focusedFieldRole: "AXTextArea", focusedFieldText: "", siblingTexts: []),
            screenshotBase64: nil
        )
        try framed.send(req)
        #expect(fake.sent.count == 1)
        let line = fake.sent[0]
        #expect(line.last == 0x0A)
        let body = line.dropLast()
        let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(obj?["reqId"] as? String == "id-1")
    }

    @Test func generateMessageForwardsDictationAndScreenshotFields() throws {
        // Regression guard: the GenerateMessage encoder used to drop
        // spokenIntent and transcriberName silently, leaving the brain to fall
        // back to compose prompts even when dictation had succeeded.
        let req = BrainRequest(
            reqId: "id-2", app: "Chrome", windowTitle: "Inbox - Gmail",
            intent: .draft,
            axTree: AXTree(focusedFieldRole: "AXUnknown", focusedFieldText: "", siblingTexts: []),
            screenshotBase64: "AAAA",
            spokenIntent: "tell sarah friday at 3 works",
            transcriberName: "apple-speech"
        )
        let data = try JSONEncoder().encode(GenerateMessage(req: req))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["type"] as? String == "generate")
        #expect(obj?["spokenIntent"] as? String == "tell sarah friday at 3 works")
        #expect(obj?["transcriberName"] as? String == "apple-speech")
        #expect(obj?["screenshotBase64"] as? String == "AAAA")
    }

    @Test func generateMessageOmitsAbsentOptionalFields() throws {
        let req = BrainRequest(
            reqId: "id-3", app: "Mail", windowTitle: "Reply", intent: .draft,
            axTree: AXTree(focusedFieldRole: "AXTextArea", focusedFieldText: "", siblingTexts: [])
        )
        let data = try JSONEncoder().encode(GenerateMessage(req: req))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["spokenIntent"] == nil)
        #expect(obj?["transcriberName"] == nil)
        #expect(obj?["screenshotBase64"] == nil)
    }
}
