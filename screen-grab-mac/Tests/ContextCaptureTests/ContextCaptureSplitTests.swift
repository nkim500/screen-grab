import Testing
import Foundation
@testable import ContextCapture

@Test func buildRequestComposesAxTreeWithDictationFields() {
    let axTree = AXTree(
        focusedFieldRole: "AXTextArea",
        focusedFieldText: "Hi Sarah —",
        siblingTexts: [AXNode(role: "AXStaticText", text: "From: Sarah")]
    )
    let captured = AXCapture(
        app: "Mail",
        windowTitle: "Reply",
        axTree: axTree
    )
    let req = ContextCapture.buildRequest(
        reqId: "r1",
        captured: captured,
        spokenIntent: "tell her friday at 3 works",
        transcriberName: "apple-speech"
    )
    #expect(req.reqId == "r1")
    #expect(req.app == "Mail")
    #expect(req.axTree.focusedFieldText == "Hi Sarah —")
    #expect(req.spokenIntent == "tell her friday at 3 works")
    #expect(req.transcriberName == "apple-speech")
}

@Test func buildRequestPropagatesScreenshotFromCapture() {
    // Screenshot-fallback path: AX captured nothing, but a screenshot was
    // attached to the AXCapture. buildRequest must forward it to BrainRequest
    // so the brain can route to its vision branch.
    let axTree = AXTree(focusedFieldRole: "AXUnknown", focusedFieldText: "", siblingTexts: [])
    let captured = AXCapture(
        app: "Google Chrome",
        windowTitle: "Inbox - Gmail",
        axTree: axTree,
        screenshotBase64: "iVBORw0KGgoAAAA"
    )
    let req = ContextCapture.buildRequest(
        reqId: "r3",
        captured: captured,
        spokenIntent: "tell sarah I'll get back to her",
        transcriberName: "apple-speech"
    )
    #expect(req.screenshotBase64 == "iVBORw0KGgoAAAA")
    #expect(req.axTree.focusedFieldRole == "AXUnknown")
    #expect(req.spokenIntent == "tell sarah I'll get back to her")
}

@Test func buildRequestWithNilDictationFieldsMatchesComposeShape() {
    let axTree = AXTree(focusedFieldRole: "AXTextArea", focusedFieldText: "", siblingTexts: [])
    let captured = AXCapture(app: "Mail", windowTitle: "", axTree: axTree)
    let req = ContextCapture.buildRequest(
        reqId: "r2",
        captured: captured,
        spokenIntent: nil,
        transcriberName: nil
    )
    #expect(req.spokenIntent == nil)
    #expect(req.transcriberName == nil)
}
