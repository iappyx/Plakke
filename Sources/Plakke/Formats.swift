import Foundation

/// Hex ↔ `rgb()` conversion for the Colour transform. The card already renders a live swatch for
/// these clips; this is the only thing it didn't let you do with one.
enum ColorFormat {
    struct Parsed {
        var r: Int, g: Int, b: Int
        var alpha: Double?
        /// True when the source was already `rgb()` / `rgba()`, so the transform goes the other way.
        var wasFunctional: Bool
    }

    static func detect(_ text: String) -> Parsed? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return parseHex(t) ?? parseFunctional(t)
    }

    /// Hex in, `rgb()` out — and `rgb()` in, hex out.
    static func converted(_ text: String) -> String? {
        guard let c = detect(text) else { return nil }
        if c.wasFunctional { return hexString(c) }
        if let a = c.alpha {
            return "rgba(\(c.r), \(c.g), \(c.b), \(trimmed(a)))"
        }
        return "rgb(\(c.r), \(c.g), \(c.b))"
    }

    private static func parseHex(_ t: String) -> Parsed? {
        guard t.hasPrefix("#") else { return nil }
        var s = String(t.dropFirst())
        // Digits only: `UInt64(_:radix:)` accepts a leading "+", which let "#+12345" convert.
        guard s.allSatisfy(\.isHexDigit) else { return nil }
        if s.count == 3 || s.count == 4 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        if s.count == 8 {
            return Parsed(r: Int((v >> 24) & 0xFF), g: Int((v >> 16) & 0xFF), b: Int((v >> 8) & 0xFF),
                          alpha: Double(v & 0xFF) / 255, wasFunctional: false)
        }
        return Parsed(r: Int((v >> 16) & 0xFF), g: Int((v >> 8) & 0xFF), b: Int(v & 0xFF),
                      alpha: nil, wasFunctional: false)
    }

    private static func parseFunctional(_ t: String) -> Parsed? {
        let pattern = #"^rgba?\(\s*(\d{1,3})\s*[, ]\s*(\d{1,3})\s*[, ]\s*(\d{1,3})\s*(?:[,/]\s*([0-9.]+%?)\s*)?\)$"#
        guard let m = t.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
              m == t.startIndex..<t.endIndex else { return nil }

        let numbers = t.matches(of: #/[0-9.]+%?/#).map { String($0.output) }
        guard numbers.count >= 3,
              let r = Int(numbers[0]), let g = Int(numbers[1]), let b = Int(numbers[2]),
              (0...255).contains(r), (0...255).contains(g), (0...255).contains(b) else { return nil }

        var alpha: Double?
        if numbers.count >= 4 {
            let raw = numbers[3]
            if raw.hasSuffix("%") {
                alpha = Double(raw.dropLast()).map { $0 / 100 }
            } else {
                alpha = Double(raw)
            }
        }
        return Parsed(r: r, g: g, b: b, alpha: alpha, wasFunctional: true)
    }

    private static func hexString(_ c: Parsed) -> String {
        if let a = c.alpha, a < 1 {
            return String(format: "#%02X%02X%02X%02X", c.r, c.g, c.b, Int((a * 255).rounded()))
        }
        return String(format: "#%02X%02X%02X", c.r, c.g, c.b)
    }

    private static func trimmed(_ value: Double) -> String {
        let s = String(format: "%.3f", value)
        var out = s
        while out.hasSuffix("0") { out.removeLast() }
        if out.hasSuffix(".") { out.removeLast() }
        return out.isEmpty ? "0" : out
    }
}

/// Pretty-print ↔ minify for the JSON transform. Which direction depends on what you copied, so one
/// key covers both.
enum JSONFormat {
    /// Guards arming the transform: no point offering it on text that isn't JSON.
    static func isJSON(_ text: String) -> Bool {
        validate(text) != nil
    }

    static func converted(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validate(trimmed) != nil else { return nil }
        // Decide on the *trimmed* text: a trailing newline (everything `pbcopy` or a file copy gives
        // you) used to make minified JSON look like it was already pretty, so J appeared to do nothing.
        return trimmed.contains("\n") ? reformat(trimmed, pretty: false) : reformat(trimmed, pretty: true)
    }

    /// Validates the text is a JSON container, without using the parsed result for output.
    private static func validate(_ text: String) -> Any? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only containers: a bare `42` or `"word"` is valid JSON but formatting it is pointless.
        guard t.count >= 2, let first = t.first, first == "{" || first == "[",
              let data = t.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return object
    }

    /// Re-indents the original text, character by character, rather than re-serialising the parsed
    /// object.
    ///
    /// Going through `JSONSerialization` rewrote the data: `0.1` came back as
    /// `0.10000000000000001`, `10.50` as `10.5`, the float `1.0` as the integer `1`, and `.sortedKeys`
    /// reordered every object. Pretty-printing a config and pasting it back was therefore a silent
    /// edit. Working on the text keeps every token — and every key's position — exactly as written.
    private static func reformat(_ json: String, pretty: Bool) -> String {
        var out = String()
        out.reserveCapacity(pretty ? json.count * 2 : json.count)
        var depth = 0
        var inString = false
        var escaped = false
        let chars = Array(json)
        var i = 0

        func indent(_ level: Int) {
            out.append("\n")
            out.append(String(repeating: "  ", count: max(0, level)))
        }

        /// Index of the next character that isn't JSON whitespace.
        func nextMeaningful(after index: Int) -> Int? {
            var j = index + 1
            while j < chars.count, chars[j] == " " || chars[j] == "\n" || chars[j] == "\r" || chars[j] == "\t" {
                j += 1
            }
            return j < chars.count ? j : nil
        }

        while i < chars.count {
            let c = chars[i]

            if inString {
                out.append(c)
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
                i += 1
                continue
            }

            switch c {
            case "\"":
                inString = true
                out.append(c)
            case " ", "\n", "\r", "\t":
                break                                   // structural whitespace is rebuilt, not copied
            case "{", "[":
                out.append(c)
                // An empty container stays on one line.
                if let j = nextMeaningful(after: i), chars[j] == (c == "{" ? "}" : "]") {
                    out.append(chars[j])
                    i = j + 1
                    continue
                }
                depth += 1
                if pretty { indent(depth) }
            case "}", "]":
                depth -= 1
                if pretty { indent(depth) }
                out.append(c)
            case ",":
                out.append(c)
                if pretty { indent(depth) } 
            case ":":
                out.append(c)
                if pretty { out.append(" ") }
            default:
                out.append(c)
            }
            i += 1
        }
        return out
    }
}
