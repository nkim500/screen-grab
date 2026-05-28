import Foundation

public struct StreamStats: Equatable {
    public let promptTokens: Int
    public let completionTokens: Int
    public let latencyMs: Int

    public init(promptTokens: Int, completionTokens: Int, latencyMs: Int) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.latencyMs = latencyMs
    }
}

public enum HUDState: Equatable {
    case idle
    case starting
    /// Mic is open, capturing audio. `level` is RMS 0.0–1.0 for the meter.
    case listening(level: Float)
    /// Audio capture finished; awaiting transcript.
    case transcribing
    /// Streaming. `transcript` is the dictation header text (nil for Compose mode).
    case generating(transcript: String?, buf: String, pendingAccept: Bool)
    /// Editable draft state. `transcript` carries through from generating.
    case ready(transcript: String?, draft: String, edited: String?, stats: StreamStats)
    case reconnecting
    case error(String)

    public static var initial: HUDState { .idle }
}

public enum HUDInput: Equatable {
    case brainStarting
    case brainReady
    case brainDisconnected
    case brainDelta(String)
    case brainDone(promptTokens: Int, completionTokens: Int, latencyMs: Int)
    case brainError(String)
    case userPressEnter
    case userPressEsc
    case userPressCmdR
    case userEdit(String)
    // Dictation lifecycle (programmatic, not keyboard-driven):
    case recordingStarted
    case audioLevel(Float)
    case recordingStopped
    case transcriptReady(String)
    case transcriptFailed(reason: String)
}

public enum HUDAction: Equatable {
    case none
    case insertAndDismiss(text: String)
    case dismiss
    case regenerate
    case retry
}

extension HUDState {
    public var isError: Bool {
        if case .error = self { return true }
        return false
    }

    @discardableResult
    public mutating func apply(_ input: HUDInput) -> HUDAction {
        // Esc dismisses from any state.
        if case .userPressEsc = input { return .dismiss }
        // brainError overrides everything except reconnecting.
        if case .brainError(let m) = input, self != .reconnecting {
            self = .error(m)
            return .none
        }
        // brainDisconnected forces reconnecting from any non-idle state.
        if case .brainDisconnected = input {
            self = .reconnecting
            return .none
        }

        switch (self, input) {
        // --- recording lifecycle ---
        case (.idle, .recordingStarted):
            self = .listening(level: 0)
            return .none
        case (.listening, .audioLevel(let l)):
            self = .listening(level: l)
            return .none
        case (.listening, .recordingStopped):
            self = .transcribing
            return .none
        case (.transcribing, .transcriptReady(let t)):
            self = .generating(transcript: t, buf: "", pendingAccept: false)
            return .none
        case (.transcribing, .transcriptFailed(let reason)):
            self = .error(reason)
            return .none

        // --- idle / starting / reconnecting transitions ---
        case (.idle, .brainStarting):
            self = .starting
            return .none
        case (.starting, .brainReady):
            self = .generating(transcript: nil, buf: "", pendingAccept: false)
            return .none
        case (.reconnecting, .brainReady):
            self = .idle
            return .none

        // --- brainDelta ---
        case (.generating(let t, let buf, let pa), .brainDelta(let txt)):
            self = .generating(transcript: t, buf: buf + txt, pendingAccept: pa)
            return .none
        case (.idle, .brainDelta(let txt)):
            // Defensive: race where deltas arrive before logical transition.
            self = .generating(transcript: nil, buf: txt, pendingAccept: false)
            return .none
        case (.ready, .brainDelta), (.error, .brainDelta), (.starting, .brainDelta), (.reconnecting, .brainDelta), (.listening, .brainDelta), (.transcribing, .brainDelta):
            return .none

        // --- brainDone ---
        case (.generating(let t, let buf, let pa), .brainDone(let p, let c, let l)):
            let stats = StreamStats(promptTokens: p, completionTokens: c, latencyMs: l)
            self = .ready(transcript: t, draft: buf, edited: nil, stats: stats)
            return pa ? .insertAndDismiss(text: buf) : .none
        case (.idle, .brainDone(let p, let c, let l)):
            let stats = StreamStats(promptTokens: p, completionTokens: c, latencyMs: l)
            self = .ready(transcript: nil, draft: "", edited: nil, stats: stats)
            return .none
        case (.ready, .brainDone), (.error, .brainDone), (.starting, .brainDone), (.reconnecting, .brainDone), (.listening, .brainDone), (.transcribing, .brainDone):
            return .none

        // --- userPressEnter ---
        case (.generating(let t, let buf, _), .userPressEnter):
            self = .generating(transcript: t, buf: buf, pendingAccept: true)
            return .none
        case (.ready(_, let draft, let edited, _), .userPressEnter):
            let final = edited ?? draft
            return .insertAndDismiss(text: final)
        case (.idle, .userPressEnter), (.starting, .userPressEnter), (.reconnecting, .userPressEnter), (.error, .userPressEnter), (.listening, .userPressEnter), (.transcribing, .userPressEnter):
            return .none

        // --- userPressCmdR ---
        case (.ready(let t, _, _, _), .userPressCmdR):
            self = .generating(transcript: t, buf: "", pendingAccept: false)
            return .regenerate
        case (.error, .userPressCmdR):
            self = .generating(transcript: nil, buf: "", pendingAccept: false)
            return .retry
        case (.idle, .userPressCmdR), (.starting, .userPressCmdR), (.generating, .userPressCmdR), (.reconnecting, .userPressCmdR), (.listening, .userPressCmdR), (.transcribing, .userPressCmdR):
            return .none

        // --- userEdit ---
        case (.ready(let t, let draft, _, let stats), .userEdit(let txt)):
            self = .ready(transcript: t, draft: draft, edited: txt, stats: stats)
            return .none
        case (.idle, .userEdit), (.starting, .userEdit), (.generating, .userEdit), (.reconnecting, .userEdit), (.error, .userEdit), (.listening, .userEdit), (.transcribing, .userEdit):
            return .none

        // --- handled-above shadows for exhaustiveness ---
        case (_, .brainError):
            return .none
        case (_, .userPressEsc):
            return .dismiss
        case (_, .brainDisconnected):
            return .none

        // --- transitions that should be no-ops ---
        case (.starting, .brainStarting), (.generating, .brainStarting), (.ready, .brainStarting), (.reconnecting, .brainStarting), (.error, .brainStarting), (.listening, .brainStarting), (.transcribing, .brainStarting):
            return .none
        case (.idle, .brainReady), (.generating, .brainReady), (.ready, .brainReady), (.error, .brainReady), (.listening, .brainReady), (.transcribing, .brainReady):
            return .none

        // --- recording-lifecycle inputs in non-applicable states ---
        case (_, .recordingStarted), (_, .audioLevel), (_, .recordingStopped), (_, .transcriptReady), (_, .transcriptFailed):
            return .none
        }
    }
}
