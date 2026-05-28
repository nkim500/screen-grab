import Testing
@testable import ContextCapture

@Suite("classifyBrowserFamily")
struct BrowserFamilyTests {
    @Test func recognizesChromeFamily() {
        #expect(ContextCapture.classifyBrowserFamily(bundleId: "com.google.Chrome") == .chromium)
        #expect(ContextCapture.classifyBrowserFamily(bundleId: "com.google.Chrome.canary") == .chromium)
        #expect(ContextCapture.classifyBrowserFamily(bundleId: "com.brave.Browser") == .chromium)
        #expect(ContextCapture.classifyBrowserFamily(bundleId: "com.brave.Browser.nightly") == .chromium)
        #expect(ContextCapture.classifyBrowserFamily(bundleId: "company.thebrowser.Browser") == .chromium)
        #expect(ContextCapture.classifyBrowserFamily(bundleId: "com.microsoft.edgemac") == .chromium)
        #expect(ContextCapture.classifyBrowserFamily(bundleId: "com.vivaldi.Vivaldi") == .chromium)
        #expect(ContextCapture.classifyBrowserFamily(bundleId: "com.operasoftware.Opera") == .chromium)
    }

    @Test func recognizesSafariFamily() {
        #expect(ContextCapture.classifyBrowserFamily(bundleId: "com.apple.Safari") == .safari)
        #expect(ContextCapture.classifyBrowserFamily(bundleId: "com.apple.SafariTechnologyPreview") == .safari)
    }

    @Test func ignoresNonBrowserApps() {
        #expect(ContextCapture.classifyBrowserFamily(bundleId: "com.apple.mail") == nil)
        #expect(ContextCapture.classifyBrowserFamily(bundleId: "com.tinyspeck.slackmacgap") == nil)
        #expect(ContextCapture.classifyBrowserFamily(bundleId: "com.microsoft.VSCode") == nil)
        #expect(ContextCapture.classifyBrowserFamily(bundleId: "") == nil)
        #expect(ContextCapture.classifyBrowserFamily(bundleId: nil) == nil)
    }

    @Test func doesNotMatchOnPrefix() {
        // Guard against drift if we ever switch from exact-match to prefix-match —
        // bundle IDs share prefixes across unrelated apps (com.google.* etc.).
        #expect(ContextCapture.classifyBrowserFamily(bundleId: "com.google.Chrome.helper") == nil)
        #expect(ContextCapture.classifyBrowserFamily(bundleId: "com.apple.SafariBookmarksSyncAgent") == nil)
    }
}
