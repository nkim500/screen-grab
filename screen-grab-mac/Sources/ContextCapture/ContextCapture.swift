import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

/// Pure-data capture of AX state at a moment in time. Construct via
/// `ContextCapture.captureAx()`; convert to a `BrainRequest` later via
/// `ContextCapture.buildRequest(reqId:captured:spokenIntent:transcriberName:)`.
///
/// `screenshotBase64` is populated when the AX read failed and we fell back to
/// a screenshot of the focused window — empty axTree, but the LLM can read
/// the image. Always nil on the happy AX path.
public struct AXCapture: Codable, Equatable {
    public let app: String
    public let windowTitle: String
    public let axTree: AXTree
    public let screenshotBase64: String?
    public init(app: String, windowTitle: String, axTree: AXTree, screenshotBase64: String? = nil) {
        self.app = app
        self.windowTitle = windowTitle
        self.axTree = axTree
        self.screenshotBase64 = screenshotBase64
    }
}

public enum ContextCaptureError: Error, CustomStringConvertible {
    case noFrontmostApp
    case noFocusedElement
    case axPermissionDenied
    case screenshotFallbackFailed
    public var description: String {
        switch self {
        case .noFrontmostApp:           return "no frontmost app"
        case .noFocusedElement:         return "no focused UI element in frontmost app"
        case .axPermissionDenied:       return "Accessibility permission not granted"
        case .screenshotFallbackFailed: return "screenshot fallback failed (likely Screen Recording permission)"
        }
    }
}

/// Which a11y-enablement signal an app's bundle ID maps to. Chromium-family
/// browsers respond to `AXEnhancedUserInterface`; Safari uses
/// `AXManualAccessibility`. All other apps return nil and we leave them alone.
public enum BrowserFamily: Equatable {
    case chromium
    case safari
}

public final class ContextCapture {
    private let maxSiblings: Int
    // 200 because browser pages have far more siblingTexts worth keeping than
    // a native window does (Mail's reply view fits in ~32; a Gmail thread
    // doesn't). Raise further only if real captures show truncation hiding
    // meaningful nodes — the cap exists to bound prompt size, not for AX
    // perf.
    public init(maxSiblings: Int = 200) {
        self.maxSiblings = maxSiblings
    }

    /// Capture AX state without assembling a full BrainRequest. Used by
    /// the dictation path which must capture on hotkey press, then attach
    /// the spoken intent later when the transcript is ready.
    public func captureAx() throws -> AXCapture {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            throw ContextCaptureError.noFrontmostApp
        }
        let axApp = AXUIElementCreateApplication(frontApp.processIdentifier)
        let browserFamily = Self.classifyBrowserFamily(bundleId: frontApp.bundleIdentifier)
        Self.enableBrowserA11yIfNeeded(axApp, bundleId: frontApp.bundleIdentifier)

        var focusedRef: CFTypeRef?
        var focusedErr = AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        if focusedErr == .apiDisabled || focusedErr == .notImplemented {
            throw ContextCaptureError.axPermissionDenied
        }
        // First capture against a freshly-launched Chromium browser races the
        // a11y-tree build that the flag we just set kicks off (50–150ms per
        // the Chromium accessibility code). Retry once on browsers only; skip
        // entirely on the happy path so native apps pay no cost.
        if (focusedErr != .success || focusedRef == nil) && browserFamily != nil {
            Thread.sleep(forTimeInterval: 0.15)
            focusedRef = nil
            focusedErr = AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        }
        guard focusedErr == .success, let focused = focusedRef else {
            throw ContextCaptureError.noFocusedElement
        }
        let focusedEl = focused as! AXUIElement // swiftlint:disable:this force_cast

        let role = (Self.string(focusedEl, kAXRoleAttribute as CFString)) ?? "AXUnknown"
        let value = Self.string(focusedEl, kAXValueAttribute as CFString) ?? ""
        let windowTitle = Self.windowTitleForFocused(focusedEl) ?? ""
        let siblings = Self.collectSiblingTexts(near: focusedEl, max: maxSiblings)

        return AXCapture(
            app: frontApp.localizedName ?? "(unknown)",
            windowTitle: windowTitle,
            axTree: AXTree(focusedFieldRole: role, focusedFieldText: value, siblingTexts: siblings)
        )
    }

    /// Fallback path: AX returned no focused element (common in Chrome, Gmail
    /// compose, Electron apps). Capture a screenshot of the frontmost window
    /// and build a synthetic AXCapture so the brain has *something* to read.
    ///
    /// Caller must have already verified Screen Recording permission is
    /// granted; CGWindowListCreateImage silently returns a black image when
    /// it isn't, which would be worse than throwing.
    public func captureScreenshotFallback() throws -> AXCapture {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            throw ContextCaptureError.noFrontmostApp
        }
        guard let base64 = Self.captureFocusedWindowScreenshot(pid: frontApp.processIdentifier) else {
            // Distinct from noFocusedElement so the daemon can surface a
            // permission-specific hint (Screen Recording vs Accessibility)
            // instead of showing the same opaque message either way.
            throw ContextCaptureError.screenshotFallbackFailed
        }
        let windowTitle = Self.frontmostWindowTitle(pid: frontApp.processIdentifier) ?? ""
        // Empty axTree signals "no AX data" to the prompt builder, which will
        // route to the screenshot-only branch.
        let emptyTree = AXTree(
            focusedFieldRole: "AXUnknown",
            focusedFieldText: "",
            siblingTexts: []
        )
        return AXCapture(
            app: frontApp.localizedName ?? "(unknown)",
            windowTitle: windowTitle,
            axTree: emptyTree,
            screenshotBase64: base64
        )
    }

    /// Pure-data assembly. No I/O. Used by both Compose and Dictate paths.
    public static func buildRequest(
        reqId: String,
        captured: AXCapture,
        spokenIntent: String? = nil,
        transcriberName: String? = nil
    ) -> BrainRequest {
        return BrainRequest(
            reqId: reqId,
            app: captured.app,
            windowTitle: captured.windowTitle,
            intent: .draft,
            axTree: captured.axTree,
            screenshotBase64: captured.screenshotBase64,
            spokenIntent: spokenIntent,
            transcriberName: transcriberName
        )
    }

    /// Convenience: captureAx + buildRequest with nil dictation fields.
    /// Used by the Compose path (no spoken input).
    public func capture(reqId: String) throws -> BrainRequest {
        let captured = try captureAx()
        return Self.buildRequest(reqId: reqId, captured: captured, spokenIntent: nil, transcriberName: nil)
    }

    // MARK: - Browser a11y enablement

    private static let chromiumBundleIds: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "com.google.Chrome.canary",
        "com.brave.Browser",
        "com.brave.Browser.beta",
        "com.brave.Browser.nightly",
        "company.thebrowser.Browser",      // Arc
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta",
        "com.microsoft.edgemac.Dev",
        "com.microsoft.edgemac.Canary",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "com.operasoftware.OperaDeveloper",
    ]

    private static let safariBundleIds: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
    ]

    /// Pure classifier — exposed for unit tests so we can verify the bundle-ID
    /// list without running the AX side-effect against a real browser.
    public static func classifyBrowserFamily(bundleId: String?) -> BrowserFamily? {
        guard let bid = bundleId else { return nil }
        if chromiumBundleIds.contains(bid) { return .chromium }
        if safariBundleIds.contains(bid) { return .safari }
        return nil
    }

    /// Chromium ships with a11y off by default and only publishes its DOM into
    /// the AX tree once a client sets `AXEnhancedUserInterface=true` on the
    /// application element — the same signal VoiceOver sends. Safari uses
    /// `AXManualAccessibility`. Without this, browsers (the primary use case
    /// for this tool) return nil for `kAXFocusedUIElementAttribute`.
    ///
    /// Called every capture: idempotent and cheap. Leave the flag on per-app
    /// for the daemon's lifetime — toggling it off thrashes Chromium's a11y
    /// tree across reads.
    static func enableBrowserA11yIfNeeded(_ axApp: AXUIElement, bundleId: String?) {
        guard let family = classifyBrowserFamily(bundleId: bundleId) else { return }
        let attr: CFString = {
            switch family {
            case .chromium: return "AXEnhancedUserInterface" as CFString
            case .safari:   return "AXManualAccessibility" as CFString
            }
        }()
        // Errors are non-fatal — if the attribute is unsettable (e.g., the
        // browser was just launched and isn't ready yet) the next capture
        // either succeeds or falls through to the screenshot tail case.
        _ = AXUIElementSetAttributeValue(axApp, attr, kCFBooleanTrue)
    }

    // MARK: - AX helpers

    private static func string(_ el: AXUIElement, _ attr: CFString) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr, &ref) == .success else { return nil }
        if let s = ref as? String { return s }
        if let n = ref as? NSNumber { return n.stringValue }
        return nil
    }

    private static func element(_ el: AXUIElement, _ attr: CFString) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr, &ref) == .success, let r = ref else { return nil }
        return (r as! AXUIElement) // swiftlint:disable:this force_cast
    }

    private static func windowTitleForFocused(_ focused: AXUIElement) -> String? {
        var cur: AXUIElement? = focused
        while let c = cur {
            if let role = string(c, kAXRoleAttribute as CFString), role == "AXWindow" {
                return string(c, kAXTitleAttribute as CFString) ?? ""
            }
            cur = element(c, kAXParentAttribute as CFString)
        }
        return nil
    }

    private static func collectSiblingTexts(near focused: AXUIElement, max: Int) -> [AXNode] {
        guard let window = nearestWindow(of: focused) else { return [] }
        var out: [AXNode] = []
        var stack: [AXUIElement] = [window]
        while let el = stack.popLast(), out.count < max {
            if el != focused {
                if let role = string(el, kAXRoleAttribute as CFString),
                   role == "AXStaticText" || role == "AXTextArea" || role == "AXTextField" {
                    let txt = string(el, kAXValueAttribute as CFString)
                        ?? string(el, kAXTitleAttribute as CFString)
                        ?? ""
                    if !txt.isEmpty {
                        out.append(AXNode(role: role, text: txt))
                    }
                }
            }
            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                stack.append(contentsOf: children)
            }
        }
        return out
    }

    // MARK: - Screenshot fallback helpers

    /// Find the topmost on-screen window owned by `pid` and capture it as a
    /// base64-encoded PNG. Returns nil if no normal-layer window is found or
    /// image encoding fails.
    ///
    /// CGWindowListCreateImage is deprecated in macOS 14 (replaced by
    /// ScreenCaptureKit) but still functional on our macOS 13+ target. Swap
    /// when we drop 13 support.
    static func captureFocusedWindowScreenshot(pid: pid_t) -> String? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        // Window layer 0 = normal application window. Anything else is menu
        // bars, dock, status items — never the user's actual document.
        let candidate = infoList.first { dict in
            guard let owner = dict[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                  let layer = dict[kCGWindowLayer as String] as? Int, layer == 0 else {
                return false
            }
            return true
        }
        guard let windowDict = candidate,
              let windowNumber = windowDict[kCGWindowNumber as String] as? CGWindowID else {
            return nil
        }
        guard let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowNumber,
            [.boundsIgnoreFraming, .nominalResolution]
        ) else {
            return nil
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        return pngData.base64EncodedString()
    }

    /// Best-effort window title for the frontmost normal-layer window owned by
    /// `pid`. Used when the AX path didn't reach windowTitleForFocused().
    static func frontmostWindowTitle(pid: pid_t) -> String? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for dict in infoList {
            guard let owner = dict[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                  let layer = dict[kCGWindowLayer as String] as? Int, layer == 0,
                  let name = dict[kCGWindowName as String] as? String, !name.isEmpty else {
                continue
            }
            return name
        }
        return nil
    }

    private static func nearestWindow(of el: AXUIElement) -> AXUIElement? {
        var cur: AXUIElement? = el
        while let c = cur {
            if let role = string(c, kAXRoleAttribute as CFString), role == "AXWindow" {
                return c
            }
            cur = element(c, kAXParentAttribute as CFString)
        }
        return nil
    }
}
