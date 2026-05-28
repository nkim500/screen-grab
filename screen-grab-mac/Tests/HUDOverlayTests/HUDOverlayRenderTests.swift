import Testing
import AppKit
@testable import HUDOverlay

@Test @MainActor func transcriptHeaderVisibleWhenTranscriptNonNil() {
    let hud = HUDOverlay()
    let stats = StreamStats(promptTokens: 1, completionTokens: 1, latencyMs: 1)
    hud.show(state: .ready(transcript: "hi sarah", draft: "Hey Sarah,", edited: nil, stats: stats), onScreenContaining: nil)
    #expect(hud.headerLabelTextForTesting == "Heard: hi sarah")
    #expect(hud.headerLabelHiddenForTesting == false)
}

@Test @MainActor func transcriptHeaderHiddenWhenTranscriptNil() {
    let hud = HUDOverlay()
    let stats = StreamStats(promptTokens: 1, completionTokens: 1, latencyMs: 1)
    hud.show(state: .ready(transcript: nil, draft: "Compose draft", edited: nil, stats: stats), onScreenContaining: nil)
    #expect(hud.headerLabelHiddenForTesting == true)
}

@Test @MainActor func listeningRendersLevelMeter() {
    let hud = HUDOverlay()
    hud.show(state: .listening(level: 0.5), onScreenContaining: nil)
    #expect(hud.statusLabelTextForTesting == "Listening\u{2026}")
    #expect(hud.meterLevelForTesting == 0.5)
}

@Test @MainActor func transcribingRendersStatusOnly() {
    let hud = HUDOverlay()
    hud.show(state: .transcribing, onScreenContaining: nil)
    #expect(hud.statusLabelTextForTesting == "Transcribing\u{2026}")
    #expect(hud.meterHiddenForTesting == true)
}
