enum XMLEscaping {
    /// Escapes text and attribute values alike; output is valid in either position.
    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            case "\n": out += "&#10;"
            case "\r": out += "&#13;"
            case "\t": out += "&#9;"
            case "\u{0}"..."\u{8}", "\u{B}", "\u{C}", "\u{E}"..."\u{1F}", "\u{FFFE}", "\u{FFFF}":
                continue  // not allowed in XML 1.0: dropped so the stanza stays well-formed
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
