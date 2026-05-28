import AppKit

public final class HUDOverlay: NSObject, NSTextViewDelegate {
    public var onEnter: (() -> Void)?
    public var onEsc:   (() -> Void)?
    public var onCmdR:  (() -> Void)?
    /// Fires while in `ready` state when the user types in the text view.
    /// Argument is the current full text-view contents.
    public var onEdit:  ((String) -> Void)?

    private var panel: HUDPanel?
    private var textView: HUDTextView?
    private var statusLabel: NSTextField?
    private var keyHintLabel: NSTextField?
    private var headerLabel: NSTextField?
    private var meterView: NSProgressIndicator?
    private var currentState: HUDState = .idle

    public override init() { super.init() }

    public func show(state: HUDState, onScreenContaining focusPoint: NSPoint?) {
        if panel == nil { buildPanel() }
        position(onScreenContaining: focusPoint)
        currentState = state
        render(state)
        if shouldBecomeKey(for: state) {
            // With `.nonactivatingPanel` in styleMask, this orders the panel
            // front AND makes it key, without activating the app — so the
            // underlying text field keeps app-level focus while the HUD owns
            // keystrokes. We deliberately do NOT call `NSApp.activate`: for an
            // accessory-policy app it's at best a no-op, at worst it fights
            // the focus-restoration captured in `lastFrontmostApp`.
            panel?.makeKeyAndOrderFront(nil)
            // Load-bearing regression detector: if the focus fix breaks
            // (panel ordered front but not key), Enter routes nowhere and
            // the user has to click in. Logging only on the failure path
            // keeps the happy case silent. The cause is almost always the
            // `.nonactivatingPanel` style bit going missing or the
            // app's activation policy changing.
            if panel?.isKeyWindow != true {
                NSLog("[screen-grab][hud] WARN panel ordered front but NOT key — keystrokes will not route to HUD. styleMask=\(panel?.styleMask.rawValue ?? 0) activationPolicy=\(NSApp.activationPolicy().rawValue)")
            }
        } else {
            // Accessory apps (LSUIElement=true) need orderFrontRegardless to
            // bring a window to the visible space without activating the app.
            // Plain orderFront is a silent no-op when the app isn't already
            // active.
            panel?.orderFrontRegardless()
        }
    }

    public func update(state: HUDState) {
        currentState = state
        render(state)
        if shouldBecomeKey(for: state) {
            // Avoid churning first-responder by re-keying an already-key panel.
            if panel?.isKeyWindow != true {
                panel?.makeKey()
            }
        }
        // Once we land in `.ready`, route typing to the editable text view
        // rather than to HUDPanel.keyDown's switch — otherwise pressing a
        // letter triggers the panel's key handling instead of inserting.
        if case .ready = state, let panel = panel, let textView = textView {
            if panel.firstResponder !== textView {
                panel.makeFirstResponder(textView)
            }
        }
    }

    public func dismiss() {
        panel?.orderOut(nil)
    }

    private func shouldBecomeKey(for state: HUDState) -> Bool {
        // Every visible state should claim keyboard input so Esc dismiss and
        // Cmd+R retry/regenerate work without the user having to click the
        // panel first. `.idle` is never actually shown, but defensively we
        // exclude it so an accidental `.idle` show doesn't grab keys.
        switch state {
        case .idle: return false
        default: return true
        }
    }

    // MARK: - Build

    private func buildPanel() {
        let w: CGFloat = 460
        let h: CGFloat = 140
        // `.nonactivatingPanel` is essential: without it, `makeKey` on this
        // panel tries to activate the app first. We're an `.accessory`-policy
        // app (LSUIElement=true) which cannot activate, so the makeKey request
        // is silently dropped and the panel never claims keyboard input.
        // `.nonactivatingPanel` lets the panel become key without activation,
        // so the underlying app keeps focus while the HUD receives keystrokes.
        let panel = HUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.acceptsMouseMovedEvents = false
        // NSPanel defaults hidesOnDeactivate=true. For an `.accessory`-policy
        // app the panel would be hidden the moment AppKit decides the app
        // isn't frontmost — which is essentially always. Override to keep the
        // HUD on screen during streaming regardless of activation state.
        panel.hidesOnDeactivate = false

        let bg = NSVisualEffectView(frame: panel.contentView!.bounds)
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 10
        bg.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(bg)

        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 10, weight: .semibold)
        status.textColor = .systemBlue
        status.frame = NSRect(x: 14, y: h - 22, width: w - 28, height: 14)
        status.autoresizingMask = [.width]
        bg.addSubview(status)

        let header = NSTextField(labelWithString: "")
        header.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        header.textColor = .secondaryLabelColor
        header.backgroundColor = .clear
        header.isBordered = false
        header.lineBreakMode = .byTruncatingTail
        header.maximumNumberOfLines = 1
        header.frame = NSRect(x: 14, y: h - 40, width: w - 28, height: 18)
        header.isHidden = true
        bg.addSubview(header)
        self.headerLabel = header

        let meter = NSProgressIndicator(frame: NSRect(x: 14, y: h / 2 - 6, width: w - 28, height: 12))
        meter.isIndeterminate = false
        meter.style = .bar
        meter.minValue = 0
        meter.maxValue = 1
        meter.doubleValue = 0
        meter.isHidden = true
        bg.addSubview(meter)
        self.meterView = meter

        // Wrap the text view in an NSScrollView so long drafts can be scrolled.
        // The scroll view tracks the bg's width via autoresizing; the text view
        // grows vertically with its content. Height is reduced by 24 vs. the
        // original to leave room for the transcript header label above.
        let scroll = NSScrollView(frame: NSRect(x: 14, y: 28, width: w - 28, height: h - 74))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]

        let contentSize = scroll.contentSize
        let textView = HUDTextView(frame: NSRect(origin: .zero, size: contentSize))
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.isEditable = false   // Default; toggled in render()
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.delegate = self
        textView.hudOverlay = self    // For Enter/Esc/Cmd+R passthrough.
        scroll.documentView = textView
        bg.addSubview(scroll)

        let keyHint = NSTextField(labelWithString: "")
        keyHint.font = .systemFont(ofSize: 9)
        keyHint.textColor = .secondaryLabelColor
        keyHint.frame = NSRect(x: 14, y: 8, width: w - 28, height: 14)
        keyHint.autoresizingMask = [.width]
        bg.addSubview(keyHint)

        panel.hudOverlay = self  // For key passthrough — see HUDPanel below.
        self.panel = panel
        self.textView = textView
        self.statusLabel = status
        self.keyHintLabel = keyHint
        // One-shot at first show: confirms the load-bearing config bits are
        // set as intended. `.nonactivatingPanel` is the most important one —
        // without it the HUD can't become key in an accessory app.
        NSLog("[screen-grab][hud] panel armed nonActivating=\(panel.styleMask.contains(.nonactivatingPanel)) level=\(panel.level.rawValue) hidesOnDeactivate=\(panel.hidesOnDeactivate) screens=\(NSScreen.screens.count)")
    }

    private func position(onScreenContaining focusPoint: NSPoint?) {
        let target: NSScreen
        if let fp = focusPoint, let s = NSScreen.screens.first(where: { NSMouseInRect(fp, $0.frame, false) }) {
            target = s
        } else {
            target = NSScreen.main ?? NSScreen.screens.first!
        }
        guard let panel = panel else {
            NSLog("[screen-grab][hud] position aborted: panel nil")
            return
        }
        let frame = panel.frame
        let x = target.visibleFrame.midX - frame.width / 2
        let y = target.visibleFrame.minY + 32
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func render(_ state: HUDState) {
        // Default to non-editable; the .ready arm flips this on.
        textView?.isEditable = false
        switch state {
        case .idle:
            statusLabel?.stringValue = ""
            keyHintLabel?.stringValue = ""
            textView?.string = ""
            headerLabel?.isHidden = true
            meterView?.isHidden = true
        case .starting:
            statusLabel?.stringValue = "Starting\u{2026}"
            keyHintLabel?.stringValue = ""
            textView?.string = ""
            headerLabel?.isHidden = true
            meterView?.isHidden = true
        case .listening(let level):
            statusLabel?.stringValue = "Listening\u{2026}"
            keyHintLabel?.stringValue = "release to send \u{2022} esc cancels"
            textView?.string = ""
            headerLabel?.isHidden = true
            meterView?.isHidden = false
            meterView?.doubleValue = Double(level)
        case .transcribing:
            statusLabel?.stringValue = "Transcribing\u{2026}"
            keyHintLabel?.stringValue = "esc cancels"
            textView?.string = ""
            headerLabel?.isHidden = true
            meterView?.isHidden = true
        case .generating(let transcript, let buf, _):
            statusLabel?.stringValue = "Generating\u{2026}"
            keyHintLabel?.stringValue = "enter accepts \u{2022} esc dismisses \u{2022} \u{2318}r regenerates"
            textView?.string = buf
            applyTranscriptHeader(transcript)
            meterView?.isHidden = true
        case .ready(let transcript, let draft, let edited, _):
            statusLabel?.stringValue = "Ready"
            keyHintLabel?.stringValue = "enter accepts \u{2022} esc dismisses \u{2022} \u{2318}r regenerates"
            // Only set the text view contents if there's no edit yet — otherwise we'd
            // clobber the user's typing. The state machine carries `edited` once the
            // user has typed at least once.
            if edited == nil {
                textView?.string = draft
                // Only place the cursor at end on first entry into ready (before any
                // user edit). Once `edited` is non-nil, the user is mid-typing and we
                // must not move the caret out from under them on subsequent renders
                // (e.g., stats updates, redraws).
                if let tv = textView {
                    tv.setSelectedRange(NSRange(location: tv.string.count, length: 0))
                }
            } else {
                textView?.string = edited!
            }
            applyTranscriptHeader(transcript)
            meterView?.isHidden = true
            textView?.isEditable = true
        case .reconnecting:
            statusLabel?.stringValue = "Reconnecting\u{2026}"
            keyHintLabel?.stringValue = "esc dismisses"
            textView?.string = ""
            headerLabel?.isHidden = true
            meterView?.isHidden = true
        case .error(let msg):
            statusLabel?.stringValue = "Error"
            keyHintLabel?.stringValue = "\u{2318}r retries \u{2022} esc dismisses"
            textView?.string = msg
            // Keep transcript header pinned in error state if we have one,
            // so the user can see what was captured even when generation failed.
            meterView?.isHidden = true
        }
    }

    private func applyTranscriptHeader(_ transcript: String?) {
        if let t = transcript, !t.isEmpty {
            headerLabel?.stringValue = "Heard: \(t)"
            headerLabel?.isHidden = false
        } else {
            headerLabel?.isHidden = true
        }
    }

    // MARK: - NSTextViewDelegate

    public func textDidChange(_ notification: Notification) {
        guard case .ready = currentState, let tv = textView else { return }
        onEdit?(tv.string)
    }

    // MARK: - Testing accessors

    public var headerLabelTextForTesting: String? { headerLabel?.stringValue }
    public var headerLabelHiddenForTesting: Bool { headerLabel?.isHidden ?? true }
    public var statusLabelTextForTesting: String? { statusLabel?.stringValue }
    public var meterLevelForTesting: Float? {
        meterView.map { Float($0.doubleValue) }
    }
    public var meterHiddenForTesting: Bool { meterView?.isHidden ?? true }
}

// Internal text-view subclass that routes Enter / Esc / Cmd+R to the overlay
// when the text view holds first-responder status (the .ready state).
// Without this, NSTextView's keyDown swallows Enter (inserts a newline) and
// Esc (silently consumed), so the panel-level handlers never fire.
final class HUDTextView: NSTextView {
    weak var hudOverlay: HUDOverlay?

    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 36, 76: // return, keypad enter
            hudOverlay?.onEnter?()
        case 53: // esc
            hudOverlay?.onEsc?()
        case 15 where cmd: // 'R' with Cmd
            hudOverlay?.onCmdR?()
        default:
            super.keyDown(with: event)
        }
    }
}

// Internal panel subclass that routes Enter / Esc / Cmd+R to the overlay.
final class HUDPanel: NSPanel {
    weak var hudOverlay: HUDOverlay?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 36, 76: // return, keypad enter
            hudOverlay?.onEnter?()
        case 53:     // esc
            hudOverlay?.onEsc?()
        case 15 where cmd: // 'R' with Cmd
            hudOverlay?.onCmdR?()
        default:
            super.keyDown(with: event)
        }
    }
}
