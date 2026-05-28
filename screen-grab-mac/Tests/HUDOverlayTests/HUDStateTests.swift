import Testing
import Foundation
@testable import HUDOverlay

// State name shorthand:
// idle             - HUD not shown / first launch
// starting         - brain not yet ready on first hotkey press
// listening(level) - mic open, capturing audio
// transcribing     - audio captured, awaiting transcript
// generating(transcript?, buf, pendingAccept)
// ready(transcript?, draft, edited?, stats)   - editable; `edited` carries the live text-view contents
// reconnecting     - brain disconnected, awaiting respawn
// error(msg)

// MARK: - Existing transitions, ported to the new state names

@Test func deltaInGeneratingAppendsToBuffer() {
    var s: HUDState = .generating(transcript: nil, buf: "Hey ", pendingAccept: false)
    let action = s.apply(.brainDelta("Sarah"))
    #expect(s == .generating(transcript: nil, buf: "Hey Sarah", pendingAccept: false))
    #expect(action == .none)
}

@Test func firstDeltaTransitionsFromGeneratingEmpty() {
    var s: HUDState = .generating(transcript: nil, buf: "", pendingAccept: false)
    _ = s.apply(.brainDelta("Hello"))
    #expect(s == .generating(transcript: nil, buf: "Hello", pendingAccept: false))
}

@Test func doneTransitionsToReady() {
    var s: HUDState = .generating(transcript: nil, buf: "Draft.", pendingAccept: false)
    let action = s.apply(.brainDone(promptTokens: 100, completionTokens: 5, latencyMs: 800))
    #expect(s == .ready(transcript: nil, draft: "Draft.", edited: nil, stats: StreamStats(promptTokens: 100, completionTokens: 5, latencyMs: 800)))
    #expect(action == .none)
}

@Test func enterDuringGeneratingMarksPendingAccept() {
    var s: HUDState = .generating(transcript: nil, buf: "Partial", pendingAccept: false)
    let action = s.apply(.userPressEnter)
    #expect(s == .generating(transcript: nil, buf: "Partial", pendingAccept: true))
    #expect(action == .none)
}

@Test func doneAfterPendingAcceptInsertsAndDismisses() {
    var s: HUDState = .generating(transcript: nil, buf: "Buffered", pendingAccept: true)
    let action = s.apply(.brainDone(promptTokens: 1, completionTokens: 1, latencyMs: 1))
    #expect(action == .insertAndDismiss(text: "Buffered"))
}

@Test func enterInReadyInsertsDraft() {
    let stats = StreamStats(promptTokens: 1, completionTokens: 1, latencyMs: 1)
    var s: HUDState = .ready(transcript: nil, draft: "Draft", edited: nil, stats: stats)
    let action = s.apply(.userPressEnter)
    #expect(action == .insertAndDismiss(text: "Draft"))
}

@Test func brainErrorOverridesAnyState() {
    var s: HUDState = .generating(transcript: nil, buf: "partial", pendingAccept: false)
    _ = s.apply(.brainError("boom"))
    #expect(s == .error("boom"))
}

@Test func escDismissesFromAnyState() {
    var s: HUDState = .ready(transcript: nil, draft: "x", edited: nil, stats: StreamStats(promptTokens: 0, completionTokens: 0, latencyMs: 0))
    let action = s.apply(.userPressEsc)
    #expect(action == .dismiss)
}

@Test func ignoreLateDeltaInReady() {
    let stats = StreamStats(promptTokens: 1, completionTokens: 1, latencyMs: 1)
    var s: HUDState = .ready(transcript: nil, draft: "x", edited: nil, stats: stats)
    _ = s.apply(.brainDelta("y"))
    #expect(s == .ready(transcript: nil, draft: "x", edited: nil, stats: stats))
}

// MARK: - New: starting / reconnecting / Cmd+R / edit

@Test func brainStartingTransitionsIdleToStarting() {
    var s: HUDState = .idle
    _ = s.apply(.brainStarting)
    #expect(s == .starting)
}

@Test func startingPlusBrainReadyTransitionsToGenerating() {
    var s: HUDState = .starting
    _ = s.apply(.brainReady)
    #expect(s == .generating(transcript: nil, buf: "", pendingAccept: false))
}

@Test func brainDisconnectedTransitionsToReconnecting() {
    var s: HUDState = .ready(transcript: nil, draft: "x", edited: nil, stats: StreamStats(promptTokens: 0, completionTokens: 0, latencyMs: 0))
    _ = s.apply(.brainDisconnected)
    #expect(s == .reconnecting)
}

@Test func brainReadyFromReconnectingReturnsToIdle() {
    var s: HUDState = .reconnecting
    _ = s.apply(.brainReady)
    #expect(s == .idle)
}

@Test func cmdRInReadyEmitsRegenerateAction() {
    let stats = StreamStats(promptTokens: 0, completionTokens: 0, latencyMs: 0)
    var s: HUDState = .ready(transcript: nil, draft: "draft", edited: nil, stats: stats)
    let action = s.apply(.userPressCmdR)
    #expect(action == .regenerate)
    #expect(s == .generating(transcript: nil, buf: "", pendingAccept: false))
}

@Test func cmdRInErrorEmitsRetryAction() {
    var s: HUDState = .error("boom")
    let action = s.apply(.userPressCmdR)
    #expect(action == .retry)
    #expect(s == .generating(transcript: nil, buf: "", pendingAccept: false))
}

@Test func userEditUpdatesEditedField() {
    let stats = StreamStats(promptTokens: 0, completionTokens: 0, latencyMs: 0)
    var s: HUDState = .ready(transcript: nil, draft: "draft", edited: nil, stats: stats)
    _ = s.apply(.userEdit("draft+"))
    #expect(s == .ready(transcript: nil, draft: "draft", edited: "draft+", stats: stats))
}

@Test func enterInReadyWithEditInsertsEdited() {
    let stats = StreamStats(promptTokens: 0, completionTokens: 0, latencyMs: 0)
    var s: HUDState = .ready(transcript: nil, draft: "draft", edited: "draft++", stats: stats)
    let action = s.apply(.userPressEnter)
    #expect(action == .insertAndDismiss(text: "draft++"))
}
