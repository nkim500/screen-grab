import AppKit
import IOKit.hid
import HotkeyListener
import ContextCapture
import IPCClient
import HUDOverlay
import TextInserter
import struct AudioCapture.AudioBuffer
import class AudioCapture.AudioCapture
import class AudioCapture.AudioLevelThrottle
import AudioCapture
import Transcriber
import AVFoundation
import Speech

// MARK: - Daemon config (Swift-side; complementary to the brain's config.json)

struct DaemonConfig {
    let hotkey: HotkeySpec               // dictation push-to-talk
    let composeHotkey: HotkeySpec        // compose hold-to-fire (screen-only draft)
    let composeHoldMillis: Int
    let socketPath: String
    let brainBinPath: String
    let brainConfigPath: String
    let repoRoot: String
    let transcriberName: String          // "apple-speech" for slice 1
    let transcriberLocale: String

    static func load() throws -> DaemonConfig {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let cfgPath = "\(home)/.config/screen-grab/config.json"
        guard let data = FileManager.default.contents(atPath: cfgPath) else {
            throw DaemonConfigError.missing(path: cfgPath)
        }
        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let hotkeyStr = (raw["hotkey"] as? String) ?? "RightCommand"
        let hotkey = try HotkeySpec.parse(hotkeyStr)
        // Backward-compat: accept the old `coldGenHotkey` / `coldGenHoldMillis`
        // keys so existing user configs keep working through the rename.
        let composeStr = (raw["composeHotkey"] as? String)
            ?? (raw["coldGenHotkey"] as? String)
            ?? "RightOption"
        let composeHotkey = try HotkeySpec.parse(composeStr)
        let composeMillis = (raw["composeHoldMillis"] as? Int)
            ?? (raw["coldGenHoldMillis"] as? Int)
            ?? 1000
        let socketPath = (raw["socketPath"] as? String) ?? "\(home)/.screen-grab.sock"
        let brainBinPath = (raw["brainBinPath"] as? String)
            ?? "\(home)/Documents/GitHub/screen-grab/screen-grab-brain/bin/screen-grab-brain-ipc"
        let brainConfigPath = (raw["brainConfigPath"] as? String) ?? cfgPath
        let repoRoot = (raw["repoRoot"] as? String) ?? "\(home)/Documents/GitHub/screen-grab"
        let transcriberName = (raw["transcriber"] as? String) ?? "apple-speech"
        let transcriberLocale = (raw["transcriberLocale"] as? String) ?? Locale.current.identifier

        return DaemonConfig(
            hotkey: hotkey,
            composeHotkey: composeHotkey,
            composeHoldMillis: composeMillis,
            socketPath: socketPath,
            brainBinPath: brainBinPath,
            brainConfigPath: brainConfigPath,
            repoRoot: repoRoot,
            transcriberName: transcriberName,
            transcriberLocale: transcriberLocale
        )
    }
}

enum DaemonConfigError: Error, CustomStringConvertible {
    case missing(path: String)
    var description: String {
        switch self {
        case .missing(let p): return "config not found: \(p)"
        }
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, AudioCaptureDelegate {
    var hotkey: HotkeyListener?
    var composeHotkey: HotkeyListener?
    var capture: ContextCapture?
    var ipc: IPCClient?
    var hud: HUDOverlay?
    var inserter: TextInserter?
    var brain: BrainProcessManager?
    var statusItem: NSStatusItem?
    var audioCapture: AudioCapture?
    var transcriber: (any Transcriber)?
    var lastAxCapture: AXCapture?

    var currentReqId: String?
    var generationStartedAt: Date?
    var lastRequest: BrainRequest?
    var lastFrontmostApp: NSRunningApplication?

    private var hudState: HUDState = .idle
    private var cfg: DaemonConfig?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let cfg = try DaemonConfig.load()
            self.cfg = cfg

            // HUD + capture + inserter first — they don't depend on the brain.
            let hud = HUDOverlay()
            self.hud = hud
            self.capture = ContextCapture()
            self.inserter = TextInserter()
            hud.onEnter = { [weak self] in self?.onEnter() }
            hud.onEsc   = { [weak self] in self?.onEsc()   }
            hud.onCmdR  = { [weak self] in self?.onCmdR()  }
            hud.onEdit  = { [weak self] txt in self?.onEdit(txt) }

            // Brain manager (async readiness via READY\n).
            let brain = BrainProcessManager(
                binPath: cfg.brainBinPath,
                configPath: cfg.brainConfigPath,
                socketPath: cfg.socketPath,
                repoRoot: cfg.repoRoot
            )
            brain.onReady = { [weak self] in self?.onBrainReady(socketPath: cfg.socketPath) }
            brain.onExit  = { [weak self] willRespawn in self?.onBrainExit(willRespawn: willRespawn) }
            brain.onExhausted = { [weak self] in self?.onBrainExhausted() }
            brain.start()
            self.brain = brain

            // Dictate hotkey: press-and-release for push-to-talk.
            let dictateHk = HotkeyListener(
                spec: cfg.hotkey,
                onPress:   { [weak self] in DispatchQueue.main.async { self?.onDictateHotkeyPress() } },
                onRelease: { [weak self] in DispatchQueue.main.async { self?.onDictateHotkeyRelease() } }
            )
            try dictateHk.start()
            self.hotkey = dictateHk

            // Compose hotkey: hold-to-fire. Drafts from screen context + voice
            // evidence with no spoken input — useful when the screen has plenty
            // of context but you have nothing to say.
            let composeHk = HotkeyListener(
                spec: cfg.composeHotkey,
                holdMillis: cfg.composeHoldMillis,
                onFire: { [weak self] in DispatchQueue.main.async { self?.onComposeHotkeyFire() } }
            )
            try composeHk.start()
            self.composeHotkey = composeHk

            let audio = AudioCapture()
            audio.delegate = self
            self.audioCapture = audio
            self.transcriber = AppleSpeechTranscriber(locale: Locale(identifier: cfg.transcriberLocale))

            // Request mic + Speech Recognition permissions early so they're
            // already granted by the time the user holds the dictate hotkey.
            // Both calls are async; we don't block startup. If perms aren't
            // granted by hotkey-press time, the relevant TranscriberError or
            // AudioCaptureError surfaces with the standard "Open Settings" hint.
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                NSLog("[screen-grab][perm] microphone=\(granted ? "granted" : "DENIED")")
            }
            SFSpeechRecognizer.requestAuthorization { status in
                let s: String
                switch status {
                case .authorized:    s = "granted"
                case .denied:        s = "DENIED"
                case .notDetermined: s = "notDetermined"
                case .restricted:    s = "RESTRICTED"
                @unknown default:    s = "unknown"
                }
                NSLog("[screen-grab][perm] speechRecognition=\(s)")
            }

            installMenubar()

            NSLog("[screen-grab] up. hotkey=%@ socket=%@",
                  String(describing: cfg.hotkey), cfg.socketPath)
            let screens = NSScreen.screens.enumerated().map { "[\($0.offset)]frame=\($0.element.frame) visible=\($0.element.visibleFrame)" }.joined(separator: " ")
            NSLog("[screen-grab][env] activationPolicy=\(NSApp.activationPolicy().rawValue) screenCount=\(NSScreen.screens.count) main=\(String(describing: NSScreen.main?.frame)) screens={\(screens)}")

            // Permission self-check. If either of these is denied, the hotkey
            // tap silently won't deliver events and the AX capture won't work
            // — even though the daemon appears to start up cleanly. Log the
            // status so we can spot misconfigured permissions instantly.
            let axTrusted = AXIsProcessTrusted()
            let imAccess = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
            let imStatus: String
            switch imAccess {
            case kIOHIDAccessTypeGranted: imStatus = "granted"
            case kIOHIDAccessTypeDenied:  imStatus = "DENIED"
            case kIOHIDAccessTypeUnknown: imStatus = "UNKNOWN"
            default:                      imStatus = "raw=\(imAccess.rawValue)"
            }
            NSLog("[screen-grab][perm] accessibility=\(axTrusted ? "granted" : "DENIED") inputMonitoring=\(imStatus)")
            if !axTrusted || imAccess != kIOHIDAccessTypeGranted {
                NSLog("[screen-grab][perm] FIX: System Settings → Privacy & Security → Accessibility AND Input Monitoring → toggle screen-grab-mac on. Add it via the + button if not listed: \(Bundle.main.bundlePath)/Contents/MacOS/screen-grab-mac")
            }
        } catch {
            NSLog("[screen-grab] startup failed: %@", String(describing: error))
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey?.stop()
        composeHotkey?.stop()
        ipc?.close()
        brain?.terminate()
        _ = audioCapture?.stop()
    }

    // MARK: - Brain lifecycle

    private func onBrainReady(socketPath: String) {
        // (Re)open the IPC connection for every brain start.
        ipc?.close()
        let ipc = IPCClient(socketPath: socketPath)
        ipc.onEvent = { [weak self] ev in
            DispatchQueue.main.async { self?.handleBrainEvent(ev) }
        }
        ipc.onClose = { [weak self] err in
            DispatchQueue.main.async { self?.onIPCClose(err) }
        }
        ipc.connect()
        self.ipc = ipc

        // If we were previously showing starting/reconnecting on the HUD,
        // transition it. The state machine handles the "what's next" logic:
        //   - .starting + .brainReady → .generating (but we have no req in flight)
        //   - .reconnecting + .brainReady → .idle
        //
        // Special case: if hudState was .starting because the user pressed the
        // hotkey before the brain came up, we treat that as cancelled and
        // return to idle (we never sent a generate). Otherwise the HUD would
        // sit in .generating forever waiting for a delta that won't arrive.
        switch hudState {
        case .starting:
            hudState = .idle
            hud?.dismiss()
        case .reconnecting:
            hudState.apply(.brainReady)  // → .idle
            hud?.dismiss()
        default:
            break
        }
    }

    private func onBrainExit(willRespawn: Bool) {
        if !willRespawn { return }   // exhausted → onBrainExhausted handles it
        hudState = .reconnecting
        hud?.show(state: hudState, onScreenContaining: NSEvent.mouseLocation)
        currentReqId = nil
    }

    private func onBrainExhausted() {
        hudState = .error("Brain failed to start. Click the menubar icon -> Restart screen-grab.")
        hud?.show(state: hudState, onScreenContaining: NSEvent.mouseLocation)
        currentReqId = nil
    }

    private func onIPCClose(_ err: Error?) {
        currentReqId = nil
        // Drop the dead connection so the next hotkey press doesn't try to
        // send through it. onBrainReady will create a fresh IPCClient when
        // the brain comes back up.
        ipc?.close()
        ipc = nil
        if !hudState.isError {
            hudState = .reconnecting
            hud?.show(state: hudState, onScreenContaining: NSEvent.mouseLocation)
        }
    }

    // MARK: - Menubar

    private func installMenubar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "sg"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Restart screen-grab",
                                action: #selector(restartBrain),
                                keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        item.menu = menu
        self.statusItem = item
    }

    @objc private func restartBrain() {
        guard let cfg = cfg else { return }
        // Tear down current brain + IPC, then start fresh. terminate() resets
        // BrainProcessManager.state to .notStarted so start() proceeds.
        ipc?.close()
        ipc = nil
        brain?.terminate()
        currentReqId = nil
        hudState = .idle
        hud?.dismiss()

        let brain = BrainProcessManager(
            binPath: cfg.brainBinPath,
            configPath: cfg.brainConfigPath,
            socketPath: cfg.socketPath,
            repoRoot: cfg.repoRoot
        )
        brain.onReady = { [weak self] in self?.onBrainReady(socketPath: cfg.socketPath) }
        brain.onExit  = { [weak self] willRespawn in self?.onBrainExit(willRespawn: willRespawn) }
        brain.onExhausted = { [weak self] in self?.onBrainExhausted() }
        brain.start()
        self.brain = brain
    }

    // MARK: - Hotkey handlers

    func onDictateHotkeyPress() {
        guard let capture = capture, let hud = hud, let brain = brain,
              let audioCapture = audioCapture else { return }
        lastFrontmostApp = NSWorkspace.shared.frontmostApplication

        if brain.state != .ready {
            hudState = .starting
            hud.show(state: hudState, onScreenContaining: NSEvent.mouseLocation)
            return
        }
        do {
            lastAxCapture = try capture.captureAx()
        } catch ContextCaptureError.axPermissionDenied {
            hudState = .error("Need Accessibility permission. System Settings → Privacy → Accessibility.")
            hud.show(state: hudState, onScreenContaining: nil)
            return
        } catch ContextCaptureError.noFocusedElement {
            // Chrome / Electron / Gmail compose often don't expose a focused
            // AX element. Fall back to a screenshot of the focused window;
            // the brain can read it via vision input.
            do {
                lastAxCapture = try capture.captureScreenshotFallback()
                NSLog("[screen-grab][ctx] AX read failed, falling back to screenshot")
            } catch ContextCaptureError.screenshotFallbackFailed {
                hudState = .error("Need Screen Recording permission. System Settings → Privacy & Security → Screen Recording.")
                hud.show(state: hudState, onScreenContaining: nil)
                return
            } catch {
                hudState = .error("Couldn't read screen: \(error)")
                hud.show(state: hudState, onScreenContaining: nil)
                return
            }
        } catch {
            hudState = .error("Couldn't read screen: \(error)")
            hud.show(state: hudState, onScreenContaining: nil)
            return
        }
        do {
            try audioCapture.start()
        } catch let err as AudioCaptureError {
            // Inlined here (rather than calling the delegate method
            // self.audioCapture(didFail:)) to avoid the ambiguous-looking
            // method call vs the `audioCapture` property of the same name.
            let msg: String
            switch err {
            case .permissionDenied:
                msg = "Need Microphone permission. System Settings → Privacy & Security → Microphone."
            default:
                msg = "Couldn't start microphone: \(err)"
            }
            hudState = .error(msg)
            hud.show(state: hudState, onScreenContaining: nil)
            return
        } catch {
            hudState = .error("Couldn't start microphone: \(error)")
            hud.show(state: hudState, onScreenContaining: nil)
            return
        }
        currentReqId = UUID().uuidString
        generationStartedAt = Date()
        _ = hudState.apply(.recordingStarted)
        hud.show(state: hudState, onScreenContaining: NSEvent.mouseLocation)
    }

    func onDictateHotkeyRelease() {
        guard let audioCapture = audioCapture, let hud = hud,
              let reqId = currentReqId, audioCapture.isRecording else {
            // Cancel path — release with no recording (e.g. cancel from
            // sibling-modifier press already torn it down).
            currentReqId = nil
            return
        }
        let buffer = audioCapture.stop()
        _ = hudState.apply(.recordingStopped)
        hud.update(state: hudState)
        guard let transcriber = transcriber, let captured = lastAxCapture else { return }

        Task { [weak self] in
            do {
                let transcript = try await transcriber.transcribe(buffer)
                await MainActor.run { self?.onTranscriptReady(reqId: reqId, captured: captured, transcript: transcript, transcriberName: transcriber.name) }
            } catch let err as TranscriberError {
                await MainActor.run { self?.onTranscriptFailed(reqId: reqId, err: err) }
            } catch {
                await MainActor.run { self?.onTranscriptFailed(reqId: reqId, err: .engineFailed(message: String(describing: error))) }
            }
        }
    }

    func onComposeHotkeyFire() {
        guard let capture = capture, let hud = hud, let brain = brain else { return }
        lastFrontmostApp = NSWorkspace.shared.frontmostApplication
        if brain.state != .ready {
            hudState = .starting
            hud.show(state: hudState, onScreenContaining: NSEvent.mouseLocation)
            return
        }
        guard let ipc = ipc else { return }
        let reqId = UUID().uuidString
        do {
            let captured: AXCapture
            do {
                captured = try capture.captureAx()
            } catch ContextCaptureError.noFocusedElement {
                captured = try capture.captureScreenshotFallback()
                NSLog("[screen-grab][ctx] AX read failed, falling back to screenshot")
            }
            // captureScreenshotFallback may throw screenshotFallbackFailed; let
            // it propagate to the outer catch arm that surfaces a Screen
            // Recording permission hint.
            let req = ContextCapture.buildRequest(reqId: reqId, captured: captured)
            currentReqId = reqId
            generationStartedAt = Date()
            lastRequest = req
            hudState = .generating(transcript: nil, buf: "", pendingAccept: false)
            hud.show(state: hudState, onScreenContaining: NSEvent.mouseLocation)
            try ipc.sendGenerate(req)
        } catch ContextCaptureError.axPermissionDenied {
            hudState = .error("Need Accessibility permission. System Settings → Privacy → Accessibility.")
            hud.show(state: hudState, onScreenContaining: nil)
        } catch ContextCaptureError.screenshotFallbackFailed {
            hudState = .error("Need Screen Recording permission. System Settings → Privacy & Security → Screen Recording.")
            hud.show(state: hudState, onScreenContaining: nil)
        } catch {
            hudState = .error("Couldn't read screen: \(error)")
            hud.show(state: hudState, onScreenContaining: nil)
        }
    }

    private func onTranscriptReady(reqId: String, captured: AXCapture, transcript: Transcript, transcriberName: String) {
        // Stale-request guard: the user may have started a new dictation
        // while this one was still transcribing.
        guard reqId == currentReqId else { return }
        guard let ipc = ipc, let hud = hud else { return }
        if transcript.text.isEmpty {
            onTranscriptFailed(reqId: reqId, err: .empty)
            return
        }
        let req = ContextCapture.buildRequest(
            reqId: reqId,
            captured: captured,
            spokenIntent: transcript.text,
            transcriberName: transcriberName
        )
        lastRequest = req
        _ = hudState.apply(.transcriptReady(transcript.text))
        hud.update(state: hudState)
        do {
            try ipc.sendGenerate(req)
        } catch {
            hudState = .error("Couldn't reach brain: \(error)")
            hud.update(state: hudState)
        }
    }

    private func onTranscriptFailed(reqId: String, err: TranscriberError) {
        guard reqId == currentReqId else { return }
        let reason: String
        switch err {
        case .empty:               reason = "Didn't catch anything — try again"
        case .permissionDenied:    reason = "Need Speech Recognition permission. System Settings → Privacy & Security → Speech Recognition."
        case .engineFailed(let m): reason = "Speech recognition failed: \(m)"
        case .timeout:             reason = "Transcription timed out"
        }
        _ = hudState.apply(.transcriptFailed(reason: reason))
        hud?.update(state: hudState)
        currentReqId = nil
    }

    // MARK: - Brain event handling

    func handleBrainEvent(_ ev: BrainEvent) {
        guard let hud = hud else { return }
        switch ev {
        case .delta(let id, let t):
            guard id == currentReqId else { return }
            let action = hudState.apply(.brainDelta(t))
            hud.update(state: hudState)
            handleAction(action)
        case .done(let id, let p, let c):
            guard id == currentReqId else { return }
            let latency = Int((Date().timeIntervalSince(generationStartedAt ?? Date())) * 1000)
            let action = hudState.apply(.brainDone(promptTokens: p, completionTokens: c, latencyMs: latency))
            hud.update(state: hudState)
            handleAction(action)
        case .error(let id, let m):
            guard id == currentReqId else { return }
            _ = hudState.apply(.brainError(m))
            hud.update(state: hudState)
            // Daemon-side: write the resolution row before clearing reqId so
            // the brain can correlate the failed request with its outcome.
            let dur = Int((Date().timeIntervalSince(generationStartedAt ?? Date())) * 1000)
            try? ipc?.sendFeedback(FeedbackMessage(
                reqId: id, event: .error, finalText: nil, durationFromGenToCloseMs: dur))
            currentReqId = nil
        case .unknown:
            break
        }
    }

    // MARK: - HUD callbacks

    func onEnter() {
        let action = hudState.apply(.userPressEnter)
        hud?.update(state: hudState)
        handleAction(action)
    }

    func onEsc() {
        // Capture the edited text *before* applying the input — the .dismiss
        // action doesn't carry it, and we want `finalText` populated on the
        // dismissed feedback row.
        var editedFinalText: String? = nil
        if case .ready(_, _, let edited, _) = hudState { editedFinalText = edited }

        let action = hudState.apply(.userPressEsc)
        handleAction(action)

        if let id = currentReqId, let ipc = ipc {
            let dur = Int((Date().timeIntervalSince(generationStartedAt ?? Date())) * 1000)
            try? ipc.sendFeedback(FeedbackMessage(
                reqId: id, event: .dismissed,
                finalText: editedFinalText,
                durationFromGenToCloseMs: dur))
        }
        currentReqId = nil
        hudState = .idle
        // Restore focus to the previously-frontmost app so the next user
        // input goes to it, not to our (now-hidden) panel.
        lastFrontmostApp?.activate(options: [])
    }

    func onCmdR() {
        let action = hudState.apply(.userPressCmdR)
        hud?.update(state: hudState)
        switch action {
        case .regenerate: sendRegenerate()
        case .retry:      sendRetry()
        default:          break
        }
    }

    func onEdit(_ text: String) {
        _ = hudState.apply(.userEdit(text))
        // No HUD render — the user is typing into the live text view directly,
        // and re-rendering would clobber the caret. The state machine carries
        // the edit so onEnter / onEsc can read it.
    }

    private func sendRegenerate() {
        guard let ipc = ipc, let req = lastRequest, let oldId = currentReqId else { return }
        // Supersede pattern: write the prior row as `regenerated` so telemetry
        // pairs the old draft with its dismissal, then start a new request
        // with a fresh reqId. Late deltas/done from oldId will be filtered by
        // the `id == currentReqId` guard in handleBrainEvent.
        let dur = Int((Date().timeIntervalSince(generationStartedAt ?? Date())) * 1000)
        try? ipc.sendFeedback(FeedbackMessage(
            reqId: oldId, event: .regenerated,
            finalText: nil,
            durationFromGenToCloseMs: dur))

        let newId = UUID().uuidString
        let newReq = BrainRequest(
            reqId: newId,
            app: req.app,
            windowTitle: req.windowTitle,
            intent: req.intent,
            axTree: req.axTree,
            screenshotBase64: req.screenshotBase64,
            spokenIntent: req.spokenIntent,
            transcriberName: req.transcriberName
        )
        currentReqId = newId
        generationStartedAt = Date()
        lastRequest = newReq
        try? ipc.sendGenerate(newReq)
    }

    private func sendRetry() {
        guard let ipc = ipc, let req = lastRequest else { return }
        // The prior row was already written with resolution `error` from
        // handleBrainEvent — no extra feedback to send here.
        let newId = UUID().uuidString
        let newReq = BrainRequest(
            reqId: newId,
            app: req.app,
            windowTitle: req.windowTitle,
            intent: req.intent,
            axTree: req.axTree,
            screenshotBase64: req.screenshotBase64,
            spokenIntent: req.spokenIntent,
            transcriberName: req.transcriberName
        )
        currentReqId = newId
        generationStartedAt = Date()
        lastRequest = newReq
        try? ipc.sendGenerate(newReq)
    }

    private func handleAction(_ action: HUDAction) {
        switch action {
        case .none, .regenerate, .retry:
            // .regenerate / .retry are handled in onCmdR explicitly above.
            break
        case .insertAndDismiss(let text):
            // Order matters: hide the HUD BEFORE synthesizing Cmd+V. With
            // `.nonactivatingPanel`, the HUD panel held key-window status so
            // Enter routed to our handler — but if we leave the panel key
            // while posting Cmd+V, the synthesized paste lands back in the
            // HUD's textView instead of the underlying app. `orderOut`
            // resigns key synchronously, so by the time `insert` posts the
            // event the previously-frontmost app's key window is the system
            // key window again. Then activate as a belt-and-suspenders cue
            // (no-op when the app never lost frontmost, but useful if it
            // somehow did).
            hud?.dismiss()
            lastFrontmostApp?.activate(options: [])
            let seed = lastAxCapture?.axTree.focusedFieldText ?? ""
            let toInsert = TextInserter.dedupAgainstSeed(text: text, seed: seed)
            NSLog("[screen-grab][insert] textLen=\(text.count) seedLen=\(seed.count) toInsertLen=\(toInsert.count)")
            inserter?.insert(toInsert)
            if let id = currentReqId, let ipc = ipc {
                let dur = Int((Date().timeIntervalSince(generationStartedAt ?? Date())) * 1000)
                let event: FeedbackEvent
                if case .ready(_, let draft, let edited, _) = hudState,
                   let e = edited, e != draft {
                    event = .edited
                } else {
                    event = .accepted
                }
                try? ipc.sendFeedback(FeedbackMessage(
                    reqId: id, event: event,
                    finalText: toInsert,
                    durationFromGenToCloseMs: dur))
            }
            currentReqId = nil
            hudState = .idle
        case .dismiss:
            hud?.dismiss()
            // Esc-specific cleanup happens in onEsc above (which also does the
            // focus restoration); .dismiss from non-Esc paths is rare.
        }
    }

    // MARK: - AudioCaptureDelegate

    func audioCaptureDidUpdateLevel(_ level: Float) {
        _ = hudState.apply(.audioLevel(level))
        hud?.update(state: hudState)
    }

    func audioCapture(didFail err: AudioCaptureError) {
        let msg: String
        switch err {
        case .permissionDenied:
            msg = "Need Microphone permission. System Settings → Privacy & Security → Microphone."
        default:
            msg = "Couldn't start microphone: \(err)"
        }
        hudState = .error(msg)
        hud?.show(state: hudState, onScreenContaining: nil)
    }

    func audioCaptureWillCapAt(remainingMs: Int) {
        // Cosmetic warning at 50s — for slice 1, we just NSLog. The HUD's
        // .listening label could include "(10s left)" if we want to be flashy
        // later; keep simple now.
        NSLog("[screen-grab][audio] cap warning — \(remainingMs)ms remaining")
    }
}

// MARK: - Bootstrap

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
