import Foundation

public enum HotkeyModifier: String, Equatable {
    case leftCommand
    case rightCommand
    case leftOption
    case rightOption
    case leftControl
    case rightControl
    case leftShift
    case rightShift
}

public enum HotkeyKey: String, Equatable {
    case space
    case semicolon
    case period
    case slash
    case quote
    case backtick
    case `return`
    case tab
    case escape
}

public struct HotkeySpec: Equatable {
    public let modifier: HotkeyModifier
    public let key: HotkeyKey?

    public init(modifier: HotkeyModifier, key: HotkeyKey? = nil) {
        self.modifier = modifier
        self.key = key
    }

    public enum ParseError: Error, CustomStringConvertible {
        case empty
        case unknownModifier(String)
        case unknownKey(String)

        public var description: String {
            switch self {
            case .empty: return "hotkey string is empty"
            case .unknownModifier(let s): return "unknown modifier: \(s)"
            case .unknownKey(let s): return "unknown key: \(s)"
            }
        }
    }

    public static func parse(_ raw: String) throws -> HotkeySpec {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParseError.empty }

        let parts = trimmed.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty else { throw ParseError.empty }

        let modifier = try parseModifier(parts[0])
        guard parts.count >= 2 else {
            return HotkeySpec(modifier: modifier, key: nil)
        }
        let key = try parseKey(parts[1])
        return HotkeySpec(modifier: modifier, key: key)
    }

    private static func parseModifier(_ s: String) throws -> HotkeyModifier {
        let lc = s.lowercased()
        switch lc {
        case "rightcommand", "rightcmd", "rcmd": return .rightCommand
        case "leftcommand",  "leftcmd",  "lcmd": return .leftCommand
        case "rightoption",  "rightopt", "ropt", "rightalt": return .rightOption
        case "leftoption",   "leftopt",  "lopt", "leftalt":  return .leftOption
        case "rightcontrol", "rightctrl", "rctrl": return .rightControl
        case "leftcontrol",  "leftctrl",  "lctrl": return .leftControl
        case "rightshift", "rshift": return .rightShift
        case "leftshift",  "lshift": return .leftShift
        default: throw ParseError.unknownModifier(s)
        }
    }

    private static func parseKey(_ s: String) throws -> HotkeyKey {
        let lc = s.lowercased()
        switch lc {
        case "space": return .space
        case ";", "semicolon": return .semicolon
        case ".", "period": return .period
        case "/", "slash": return .slash
        case "'", "quote", "apostrophe": return .quote
        case "`", "backtick", "grave": return .backtick
        case "return", "enter": return .return
        case "tab": return .tab
        case "escape", "esc": return .escape
        default: throw ParseError.unknownKey(s)
        }
    }
}
