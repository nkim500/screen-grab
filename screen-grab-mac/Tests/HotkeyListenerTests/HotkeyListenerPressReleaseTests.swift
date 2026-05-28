import Testing
import Foundation
@testable import HotkeyListener

@Test func pressAndReleaseFiresOnDownAndUp() {
    var pressed = 0
    var released = 0
    let listener = HotkeyListener(
        spec: HotkeySpec(modifier: .rightCommand),
        onPress:   { pressed += 1 },
        onRelease: { released += 1 }
    )
    // Right Cmd down (kc=54, .maskCommand bit set)
    listener.handleDecodedEventForTesting(.flagsChanged, keyCode: 54, modifierBitSet: true)
    #expect(pressed == 1)
    #expect(released == 0)
    // Right Cmd up (kc=54, .maskCommand bit cleared)
    listener.handleDecodedEventForTesting(.flagsChanged, keyCode: 54, modifierBitSet: false)
    #expect(pressed == 1)
    #expect(released == 1)
}

@Test func pressAndReleaseCancelsOnOtherModifierDuringHold() {
    var pressed = 0
    var released = 0
    let listener = HotkeyListener(
        spec: HotkeySpec(modifier: .rightCommand),
        onPress:   { pressed += 1 },
        onRelease: { released += 1 }
    )
    listener.handleDecodedEventForTesting(.flagsChanged, keyCode: 54, modifierBitSet: true) // RCmd down
    #expect(pressed == 1)
    // Right Shift down (kc=60). Should fire onRelease (cancel signal) and
    // suppress further events for this hold.
    listener.handleDecodedEventForTesting(.flagsChanged, keyCode: 60, modifierBitSet: true)
    #expect(released == 1)
    // Subsequent RCmd up should NOT fire onRelease again.
    listener.handleDecodedEventForTesting(.flagsChanged, keyCode: 54, modifierBitSet: false)
    #expect(released == 1)
}

@Test func pressAndReleaseCancelsOnOtherKeyDuringHold() {
    var pressed = 0
    var released = 0
    let listener = HotkeyListener(
        spec: HotkeySpec(modifier: .rightCommand),
        onPress:   { pressed += 1 },
        onRelease: { released += 1 }
    )
    listener.handleDecodedEventForTesting(.flagsChanged, keyCode: 54, modifierBitSet: true)
    listener.handleDecodedEventForTesting(.keyDown, keyCode: 36 /* return */, modifierBitSet: true)
    #expect(released == 1)
}

@Test func holdThresholdInitializerStillWorks() {
    // Regression: ensure the existing initializer compiles and isn't broken.
    let listener = HotkeyListener(
        spec: HotkeySpec(modifier: .rightOption),
        holdMillis: 1000,
        onFire: {}
    )
    #expect(type(of: listener) == HotkeyListener.self)
}
