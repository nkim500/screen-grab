import Testing
@testable import TextInserter

@Suite("TextInserter.dedupAgainstSeed")
struct DedupAgainstSeedTests {

    // MARK: - Trivial passthroughs

    @Test func emptySeedPassesTextThrough() {
        // Empty field (typical Dictate-into-empty-box case). No dedup possible.
        // Regression guard for the bug where empty seed somehow produced "".
        #expect(TextInserter.dedupAgainstSeed(text: "hello world", seed: "") == "hello world")
    }

    @Test func bothEmptyReturnsEmpty() {
        // Pathological but defined: empty input → empty output, no crash.
        #expect(TextInserter.dedupAgainstSeed(text: "", seed: "") == "")
    }

    @Test func emptyTextWithSeedReturnsEmpty() {
        // If the brain returned "" (e.g., model produced nothing), we pass it
        // through. Caller logs textLen=0 so this surfaces in diagnostics.
        #expect(TextInserter.dedupAgainstSeed(text: "", seed: "Hello") == "")
    }

    // MARK: - Happy strip

    @Test func stripsExactPrefixLeavingContinuation() {
        let out = TextInserter.dedupAgainstSeed(
            text: "Hello my name is Nick — and I want to build something crazy",
            seed: "Hello my name is Nick"
        )
        #expect(out == " — and I want to build something crazy")
    }

    @Test func stripsPrefixWhenContinuationIsJustOneChar() {
        // Even a single non-whitespace character counts as meaningful.
        #expect(TextInserter.dedupAgainstSeed(text: "abcZ", seed: "abc") == "Z")
    }

    // MARK: - No prefix → passthrough

    @Test func passesTextThroughWhenSeedNotAPrefix() {
        // Model wrote something entirely different from the seed.
        #expect(TextInserter.dedupAgainstSeed(text: "Goodbye", seed: "Hello") == "Goodbye")
    }

    @Test func passesThroughWhenSeedIsSubstringButNotPrefix() {
        // 'lo' appears in 'Hello' but isn't a prefix — must not strip.
        #expect(TextInserter.dedupAgainstSeed(text: "Hello world", seed: "lo") == "Hello world")
    }

    // MARK: - Fallback: don't paste empty (the bug 21749ab tried to fix)

    @Test func fallsBackToFullTextWhenStripLeavesEmpty() {
        // Model echoed the seed verbatim with nothing after. Stripping yields "".
        // Better to paste the duplicate than to silently paste nothing.
        #expect(TextInserter.dedupAgainstSeed(text: "Hello", seed: "Hello") == "Hello")
    }

    @Test func fallsBackToFullTextWhenStripLeavesOnlyWhitespace() {
        // Same idea: trailing whitespace after the seed isn't useful content.
        #expect(TextInserter.dedupAgainstSeed(text: "Hello   ", seed: "Hello") == "Hello   ")
        #expect(TextInserter.dedupAgainstSeed(text: "Hello\n\n", seed: "Hello") == "Hello\n\n")
        #expect(TextInserter.dedupAgainstSeed(text: "Hello \t \n", seed: "Hello") == "Hello \t \n")
    }

    // MARK: - Real-world shapes

    @Test func longSeedShortContinuation() {
        let seed = "The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog."
        let text = seed + " End."
        #expect(TextInserter.dedupAgainstSeed(text: text, seed: seed) == " End.")
    }

    @Test func multilineSeedWithContinuation() {
        // Multi-line focus field (Notes, code editor) — newlines in seed
        // must not break the prefix match.
        let seed = "line one\nline two"
        let text = "line one\nline two\nline three"
        #expect(TextInserter.dedupAgainstSeed(text: text, seed: seed) == "\nline three")
    }
}
