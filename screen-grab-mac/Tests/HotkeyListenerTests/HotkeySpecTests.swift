import Testing
@testable import HotkeyListener

@Suite("HotkeySpec")
struct HotkeySpecTests {
    @Test func rightCommandAlone() throws {
        let spec = try HotkeySpec.parse("RightCommand")
        #expect(spec.modifier == .rightCommand)
        #expect(spec.key == nil)
    }

    @Test func leftCommandAlone() throws {
        let spec = try HotkeySpec.parse("LeftCommand")
        #expect(spec.modifier == .leftCommand)
        #expect(spec.key == nil)
    }

    @Test func shortFormRightCmd() throws {
        let spec = try HotkeySpec.parse("RightCmd")
        #expect(spec.modifier == .rightCommand)
        #expect(spec.key == nil)
    }

    @Test func rightCommandPlusSpace() throws {
        let spec = try HotkeySpec.parse("RightCmd+Space")
        #expect(spec.modifier == .rightCommand)
        #expect(spec.key == .space)
    }

    @Test func rightOptionPlusSemicolon() throws {
        let spec = try HotkeySpec.parse("RightOpt+;")
        #expect(spec.modifier == .rightOption)
        #expect(spec.key == .semicolon)
    }

    @Test func caseInsensitive() throws {
        let spec = try HotkeySpec.parse("rightcommand")
        #expect(spec.modifier == .rightCommand)
    }

    @Test func whitespaceAroundPlus() throws {
        let spec = try HotkeySpec.parse("RightCmd + Space")
        #expect(spec.modifier == .rightCommand)
        #expect(spec.key == .space)
    }

    @Test func emptyStringThrows() {
        #expect(throws: (any Error).self) {
            _ = try HotkeySpec.parse("")
        }
    }

    @Test func unknownModifierThrows() {
        #expect(throws: (any Error).self) {
            _ = try HotkeySpec.parse("FunctionKey")
        }
    }

    @Test func unknownKeyThrows() {
        #expect(throws: (any Error).self) {
            _ = try HotkeySpec.parse("RightCmd+Hyperspace")
        }
    }
}
