import Foundation

public enum BrainIntent: String, Codable {
    case draft
}

public struct AXNode: Codable, Equatable {
    public let role: String
    public let text: String
    public init(role: String, text: String) {
        self.role = role
        self.text = text
    }
}

public struct AXTree: Codable, Equatable {
    public let focusedFieldRole: String
    public let focusedFieldText: String
    public let siblingTexts: [AXNode]
    public init(focusedFieldRole: String, focusedFieldText: String, siblingTexts: [AXNode]) {
        self.focusedFieldRole = focusedFieldRole
        self.focusedFieldText = focusedFieldText
        self.siblingTexts = siblingTexts
    }
}

public struct BrainRequest: Codable, Equatable {
    public let reqId: String
    public let app: String
    public let windowTitle: String
    public let intent: BrainIntent
    public let axTree: AXTree
    public let screenshotBase64: String?
    /// Present iff this request originated from dictation.
    public let spokenIntent: String?
    /// Present iff `spokenIntent` is set; identifies the STT backend used.
    public let transcriberName: String?

    public init(
        reqId: String,
        app: String,
        windowTitle: String,
        intent: BrainIntent,
        axTree: AXTree,
        screenshotBase64: String? = nil,
        spokenIntent: String? = nil,
        transcriberName: String? = nil
    ) {
        self.reqId = reqId
        self.app = app
        self.windowTitle = windowTitle
        self.intent = intent
        self.axTree = axTree
        self.screenshotBase64 = screenshotBase64
        self.spokenIntent = spokenIntent
        self.transcriberName = transcriberName
    }
}
