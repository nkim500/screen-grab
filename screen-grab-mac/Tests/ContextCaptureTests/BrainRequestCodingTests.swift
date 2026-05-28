import Testing
import Foundation
@testable import ContextCapture

@Suite("BrainRequest Codable")
struct BrainRequestCodingTests {
    @Test func encodesShapeMatchingBrainContract() throws {
        let req = BrainRequest(
            reqId: "abc",
            app: "Mail",
            windowTitle: "Reply: Q2",
            intent: .draft,
            axTree: AXTree(
                focusedFieldRole: "AXTextArea",
                focusedFieldText: "draft so far",
                siblingTexts: [
                    AXNode(role: "AXStaticText", text: "From: Sarah"),
                    AXNode(role: "AXStaticText", text: "Subject: Q2"),
                ]
            ),
            screenshotBase64: nil
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = try encoder.encode(req)
        let obj = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        #expect(obj?["reqId"] as? String == "abc")
        #expect(obj?["app"] as? String == "Mail")
        #expect(obj?["windowTitle"] as? String == "Reply: Q2")
        #expect(obj?["intent"] as? String == "draft")

        let ax = obj?["axTree"] as? [String: Any]
        #expect(ax?["focusedFieldRole"] as? String == "AXTextArea")
        #expect(ax?["focusedFieldText"] as? String == "draft so far")
        let sibs = ax?["siblingTexts"] as? [[String: Any]]
        #expect(sibs?.count == 2)
        #expect(sibs?[0]["role"] as? String == "AXStaticText")
        #expect(sibs?[0]["text"] as? String == "From: Sarah")

        // No screenshot in v1 default path; absent or null both fine. Brain accepts both.
        #expect(obj?["screenshotBase64"] == nil || obj?["screenshotBase64"] is NSNull)
    }

    @Test func roundTrip() throws {
        let req = BrainRequest(
            reqId: "id-1",
            app: "Slack",
            windowTitle: "DM with Pat",
            intent: .draft,
            axTree: AXTree(
                focusedFieldRole: "AXTextField",
                focusedFieldText: "",
                siblingTexts: [AXNode(role: "AXStaticText", text: "Pat: how's it going?")]
            ),
            screenshotBase64: nil
        )
        let json = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(BrainRequest.self, from: json)
        #expect(decoded == req)
    }

    @Test func brainRequestEncodesSpokenIntentAndTranscriberName() throws {
        let req = BrainRequest(
            reqId: "r1",
            app: "Mail",
            windowTitle: "Reply",
            intent: .draft,
            axTree: AXTree(focusedFieldRole: "AXTextArea", focusedFieldText: "", siblingTexts: []),
            screenshotBase64: nil,
            spokenIntent: "say hi to sarah",
            transcriberName: "apple-speech"
        )
        let data = try JSONEncoder().encode(req)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["spokenIntent"] as? String == "say hi to sarah")
        #expect(json["transcriberName"] as? String == "apple-speech")
    }

    @Test func brainRequestRoundTripsWithoutDictationFields() throws {
        // Backwards-compat: a request with no dictation fields must encode and
        // decode cleanly, with the new fields nil.
        let req = BrainRequest(
            reqId: "r1",
            app: "Mail",
            windowTitle: "Reply",
            intent: .draft,
            axTree: AXTree(focusedFieldRole: "AXTextArea", focusedFieldText: "", siblingTexts: []),
            screenshotBase64: nil
        )
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(BrainRequest.self, from: data)
        #expect(decoded.spokenIntent == nil)
        #expect(decoded.transcriberName == nil)
    }

    @Test func brainRequestDecodesLegacyJSONWithoutDictationFields() throws {
        // A JSON payload from before the dictation fields were added must still
        // decode (the new fields are absent, not null).
        let legacyJSON = """
        {
          "reqId": "r1",
          "app": "Mail",
          "windowTitle": "Reply",
          "intent": "draft",
          "axTree": {"focusedFieldRole": "AXTextArea", "focusedFieldText": "", "siblingTexts": []},
          "screenshotBase64": null
        }
        """
        let data = legacyJSON.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(BrainRequest.self, from: data)
        #expect(decoded.spokenIntent == nil)
        #expect(decoded.transcriberName == nil)
    }
}
