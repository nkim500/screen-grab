import Testing
import Foundation
@testable import HUDOverlay

// MARK: - Recording lifecycle

@Test func recordingStartedFromIdleEntersListening() {
    var s: HUDState = .idle
    let action = s.apply(.recordingStarted)
    #expect(s == .listening(level: 0))
    #expect(action == .none)
}

@Test func audioLevelInListeningUpdatesLevel() {
    var s: HUDState = .listening(level: 0)
    _ = s.apply(.audioLevel(0.7))
    #expect(s == .listening(level: 0.7))
}

@Test func recordingStoppedFromListeningEntersTranscribing() {
    var s: HUDState = .listening(level: 0.5)
    _ = s.apply(.recordingStopped)
    #expect(s == .transcribing)
}

@Test func transcriptReadyFromTranscribingEntersGeneratingWithHeader() {
    var s: HUDState = .transcribing
    _ = s.apply(.transcriptReady("hi sarah"))
    #expect(s == .generating(transcript: "hi sarah", buf: "", pendingAccept: false))
}

@Test func transcriptFailedFromTranscribingEntersError() {
    var s: HUDState = .transcribing
    _ = s.apply(.transcriptFailed(reason: "Didn't catch anything — try again"))
    #expect(s == .error("Didn't catch anything — try again"))
}

@Test func escFromListeningDismisses() {
    var s: HUDState = .listening(level: 0.3)
    let action = s.apply(.userPressEsc)
    #expect(action == .dismiss)
}

@Test func escFromTranscribingDismisses() {
    var s: HUDState = .transcribing
    let action = s.apply(.userPressEsc)
    #expect(action == .dismiss)
}

// MARK: - Transcript carried through generating + ready

@Test func brainDeltaInGeneratingPreservesTranscript() {
    var s: HUDState = .generating(transcript: "hi sarah", buf: "Hey ", pendingAccept: false)
    _ = s.apply(.brainDelta("Sarah,"))
    #expect(s == .generating(transcript: "hi sarah", buf: "Hey Sarah,", pendingAccept: false))
}

@Test func brainDoneInGeneratingPreservesTranscriptIntoReady() {
    var s: HUDState = .generating(transcript: "hi sarah", buf: "Hey Sarah,", pendingAccept: false)
    _ = s.apply(.brainDone(promptTokens: 1, completionTokens: 1, latencyMs: 1))
    let stats = StreamStats(promptTokens: 1, completionTokens: 1, latencyMs: 1)
    #expect(s == .ready(transcript: "hi sarah", draft: "Hey Sarah,", edited: nil, stats: stats))
}

@Test func enterInReadyWithEditedPrefersEdit() {
    let stats = StreamStats(promptTokens: 1, completionTokens: 1, latencyMs: 1)
    var s: HUDState = .ready(transcript: "hi", draft: "Hey", edited: "Hey there", stats: stats)
    let action = s.apply(.userPressEnter)
    #expect(action == .insertAndDismiss(text: "Hey there"))
}

// MARK: - Compose regression guard

@Test func composeFlowWithNilTranscriptStillReachesReady() {
    var s: HUDState = .generating(transcript: nil, buf: "", pendingAccept: false)
    _ = s.apply(.brainDelta("Hello"))
    #expect(s == .generating(transcript: nil, buf: "Hello", pendingAccept: false))
    _ = s.apply(.brainDone(promptTokens: 1, completionTokens: 1, latencyMs: 1))
    let stats = StreamStats(promptTokens: 1, completionTokens: 1, latencyMs: 1)
    #expect(s == .ready(transcript: nil, draft: "Hello", edited: nil, stats: stats))
}

@Test func cmdRFromReadyWithTranscriptCarriesTranscriptIntoGenerating() {
    let stats = StreamStats(promptTokens: 1, completionTokens: 1, latencyMs: 1)
    var s: HUDState = .ready(transcript: "hi sarah", draft: "Hey Sarah,", edited: nil, stats: stats)
    let action = s.apply(.userPressCmdR)
    #expect(action == .regenerate)
    #expect(s == .generating(transcript: "hi sarah", buf: "", pendingAccept: false))
}

@Test func enterInGeneratingWithTranscriptKeepsTranscriptOnPendingAcceptFlip() {
    var s: HUDState = .generating(transcript: "hi sarah", buf: "Hey Sarah,", pendingAccept: false)
    let action = s.apply(.userPressEnter)
    #expect(s == .generating(transcript: "hi sarah", buf: "Hey Sarah,", pendingAccept: true))
    #expect(action == .none)
}
