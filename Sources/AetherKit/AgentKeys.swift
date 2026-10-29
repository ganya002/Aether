import Foundation

/// Bytes an agent means when it says `ctrl+c` or `enter`.
enum AgentInput {
    static func bytes(_ body: [String: Any]) -> Result<[UInt8], AgentError> {
        if let keys = body["keys"] as? String, !keys.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let encoded = AgentKeys.encode(keys) else {
                return .failure(AgentError("Unknown key \(keys). Use ctrl+c, enter, or a named key."))
            }
            return .success(encoded)
        }
        var data = AgentKeys.text(body["text"] as? String ?? "")
        if body["enter"] as? Bool == true { data.append(0x0d) }
        if data.isEmpty { return .failure(AgentError("Give text or --keys.")) }
        return .success(data)
    }
}

enum AgentKeys {
    /// Comma-separated chords: `ctrl+c`, `ctrl+c,enter`, `up`.
    static func encode(_ spec: String) -> [UInt8]? {
        let parts = spec.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        var out: [UInt8] = []
        for part in parts {
            guard let bytes = chord(String(part)) else { return nil }
            out.append(contentsOf: bytes)
        }
        return out
    }

    static func text(_ string: String) -> [UInt8] {
        Array(string.utf8)
    }

    static func chord(_ raw: String) -> [UInt8]? {
        let token = normalize(raw)
        if token.isEmpty { return nil }
        let pieces = token.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let key = pieces.last, !key.isEmpty else { return nil }
        var control = false
        var alt = false
        for modifier in pieces.dropLast() {
            switch modifier {
            case "ctrl", "control", "c":
                control = true
            case "alt", "option", "meta", "a", "m":
                alt = true
            case "shift", "s":
                continue
            default:
                return nil
            }
        }
        guard let base = named(key) ?? (key.utf8.count == 1 ? Array(key.utf8) : nil) else { return nil }
        if control {
            guard base.count == 1, let scalar = base.first else { return nil }
            let letter = scalar | 0x20
            if letter >= 0x61, letter <= 0x7a {
                return [letter - 0x60]
            }
            switch scalar {
            case 0x5b: return [0x1b]
            case 0x5c: return [0x1c]
            case 0x5d: return [0x1d]
            case 0x7e, 0x3f: return [0x1f]
            case 0x20: return [0x00]
            default: return nil
            }
        }
        if alt {
            return [0x1b] + base
        }
        return base
    }

    private static func normalize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("^"), text.count == 2 {
            text = "ctrl+" + String(text.dropFirst())
        }
        text = text.replacingOccurrences(of: "c-", with: "ctrl+")
        text = text.replacingOccurrences(of: "a-", with: "alt+")
        text = text.replacingOccurrences(of: "m-", with: "alt+")
        return text
    }

    private static func named(_ key: String) -> [UInt8]? {
        switch key {
        case "enter", "return", "ret", "cr": return [0x0d]
        case "esc", "escape": return [0x1b]
        case "tab": return [0x09]
        case "space", "spc": return [0x20]
        case "backspace", "bs": return [0x7f]
        case "delete", "del": return [0x1b, 0x5b, 0x33, 0x7e]
        case "up": return [0x1b, 0x5b, 0x41]
        case "down": return [0x1b, 0x5b, 0x42]
        case "right": return [0x1b, 0x5b, 0x43]
        case "left": return [0x1b, 0x5b, 0x44]
        case "home": return [0x1b, 0x5b, 0x48]
        case "end": return [0x1b, 0x5b, 0x46]
        case "pageup", "pgup": return [0x1b, 0x5b, 0x35, 0x7e]
        case "pagedown", "pgdn": return [0x1b, 0x5b, 0x36, 0x7e]
        default:
            if key.count >= 2, key.first == "f", let number = Int(key.dropFirst()), (1...12).contains(number) {
                return functionKey(number)
            }
            return nil
        }
    }

    private static func functionKey(_ number: Int) -> [UInt8] {
        switch number {
        case 1: return [0x1b, 0x4f, 0x50]
        case 2: return [0x1b, 0x4f, 0x51]
        case 3: return [0x1b, 0x4f, 0x52]
        case 4: return [0x1b, 0x4f, 0x53]
        default:
            let code = [11, 12, 13, 14, 15, 17, 18, 19][number - 5]
            return [0x1b, 0x5b, 0x31] + Array(String(code).utf8) + [0x7e]
        }
    }
}
