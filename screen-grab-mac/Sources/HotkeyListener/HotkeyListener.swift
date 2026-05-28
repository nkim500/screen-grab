import Foundation
import CoreGraphics
import AppKit

public final class HotkeyListener {
    private enum Mode {
        case holdThreshold(millis: Int, onFire: () -> Void)
        case pressAndRelease(onPress: () -> Void, onRelease: () -> Void)
    }

    private let spec: HotkeySpec
    private let mode: Mode
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pendingFire: DispatchWorkItem?
    private var prHeld = false  // pressAndRelease: are we currently in a hold?
    private static var firstEventLogged = false

    /// Hold-to-fire after a threshold (Compose hotkey path).
    public init(spec: HotkeySpec, holdMillis: Int = 1000, onFire: @escaping () -> Void) {
        self.spec = spec
        self.mode = .holdThreshold(millis: holdMillis, onFire: onFire)
    }

    /// Fire onPress on key-down for the target modifier; fire onRelease on
    /// key-up OR on any cancel condition (other modifier/key during hold).
    /// Used by the dictation push-to-talk flow.
    public init(
        spec: HotkeySpec,
        onPress: @escaping () -> Void,
        onRelease: @escaping () -> Void
    ) {
        self.spec = spec
        self.mode = .pressAndRelease(onPress: onPress, onRelease: onRelease)
    }

    public func start() throws {
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let unmanagedSelf = Unmanaged.passUnretained(self)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let listener = Unmanaged<HotkeyListener>.fromOpaque(refcon).takeUnretainedValue()
                listener.handleCGEvent(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: unmanagedSelf.toOpaque()
        ) else {
            throw HotkeyListenerError.tapCreateFailed
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("[screen-grab][hk] tap enabled spec=\(spec) mode=\(modeDescription)")
    }

    public func stop() {
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        cancelPendingFire(reason: "stop()")
        prHeld = false
    }

    private var modeDescription: String {
        switch mode {
        case .holdThreshold(let ms, _):     return "holdThreshold(\(ms)ms)"
        case .pressAndRelease:              return "pressAndRelease"
        }
    }

    private func cancelPendingFire(reason: String) {
        guard pendingFire != nil else { return }
        pendingFire?.cancel()
        pendingFire = nil
        NSLog("[screen-grab][hk] hold canceled: \(reason)")
    }

    private func handleCGEvent(type: CGEventType, event: CGEvent) {
        if !Self.firstEventLogged {
            Self.firstEventLogged = true
            NSLog("[screen-grab][hk] FIRST event delivered to tap (input monitoring is working)")
        }
        let kc = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let kcMap: [Int: HotkeyModifier] = [
            54: .rightCommand, 55: .leftCommand,
            61: .rightOption, 58: .leftOption,
            60: .rightShift, 56: .leftShift,
            62: .rightControl, 59: .leftControl,
        ]
        let modifierBit: Bool = {
            guard let m = kcMap[kc] else { return false }
            let bit: CGEventFlags
            switch m {
            case .leftCommand, .rightCommand:    bit = .maskCommand
            case .leftOption, .rightOption:      bit = .maskAlternate
            case .leftShift, .rightShift:        bit = .maskShift
            case .leftControl, .rightControl:    bit = .maskControl
            }
            return event.flags.contains(bit)
        }()
        handleDecodedEventForTesting(type, keyCode: kc, modifierBitSet: modifierBit)
    }

    /// Test seam: drive the FSM with already-decoded inputs. Production code
    /// invokes this from handleCGEvent after extracting keyCode + modifier
    /// state from the CGEvent.
    public func handleDecodedEventForTesting(_ type: CGEventType, keyCode: Int, modifierBitSet: Bool) {
        let kcMap: [Int: HotkeyModifier] = [
            54: .rightCommand, 55: .leftCommand,
            61: .rightOption, 58: .leftOption,
            60: .rightShift, 56: .leftShift,
            62: .rightControl, 59: .leftControl,
        ]
        switch (type, mode) {
        case (.flagsChanged, .holdThreshold(let ms, let onFire)):
            guard let m = kcMap[keyCode] else { return }
            if m == spec.modifier {
                if modifierBitSet {
                    cancelPendingFire(reason: "re-arm")
                    let work = DispatchWorkItem { [weak self] in
                        guard let self = self else { return }
                        self.pendingFire = nil
                        NSLog("[screen-grab][hk] hold threshold reached — firing")
                        onFire()
                    }
                    self.pendingFire = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms), execute: work)
                    NSLog("[screen-grab][hk] target down (\(m)) — armed hold (\(ms)ms)")
                } else {
                    cancelPendingFire(reason: "released early")
                }
            } else if modifierBitSet {
                cancelPendingFire(reason: "other modifier \(m) pressed")
            }
        case (.flagsChanged, .pressAndRelease(let onPress, let onRelease)):
            guard let m = kcMap[keyCode] else { return }
            if m == spec.modifier {
                if modifierBitSet {
                    if !prHeld {
                        prHeld = true
                        onPress()
                    }
                } else {
                    if prHeld {
                        prHeld = false
                        onRelease()
                    }
                }
            } else if modifierBitSet {
                // Other modifier pressed mid-hold — cancel the hold.
                if prHeld {
                    prHeld = false
                    onRelease()
                }
            }
        case (.keyDown, .holdThreshold):
            cancelPendingFire(reason: "key pressed")
        case (.keyDown, .pressAndRelease(_, let onRelease)):
            if prHeld {
                prHeld = false
                onRelease()
            }
        default:
            break
        }
    }
}

public enum HotkeyListenerError: Error, CustomStringConvertible {
    case tapCreateFailed
    public var description: String {
        switch self {
        case .tapCreateFailed:
            return "CGEvent.tapCreate returned nil — usually means Accessibility permission is missing."
        }
    }
}
