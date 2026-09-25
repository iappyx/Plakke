import Foundation

/// Line handling shared by classification, previews and transforms.
///
/// Swift treats "\r\n" as a *single* Character, so `split(separator: "\n")` returns one element
/// for a whole CRLF document — which silently turned Reflow, Tidy and Markdown into no-ops on
/// text copied from Windows apps, Outlook and most email clients. Everything that splits lines
/// goes through `lines` (or normalises first) so the terminator never matters again.
extension String {
    /// Every Unicode line terminator, rewritten to "\n".
    var normalizedNewlines: String {
        guard unicodeScalars.contains(where: Self.isLineTerminator) else { return self }
        var out = String()
        out.reserveCapacity(count)
        var scalars = String.UnicodeScalarView()
        var skipNextLF = false
        for s in unicodeScalars {
            if skipNextLF, s == "\n" { skipNextLF = false; continue }
            skipNextLF = false
            if Self.isLineTerminator(s) {
                scalars.append("\n")
                if s == "\r" { skipNextLF = true }   // CRLF collapses to one break
            } else {
                scalars.append(s)
            }
        }
        out.unicodeScalars.append(contentsOf: scalars)
        return out
    }

    /// Splits on any Unicode line terminator, keeping empty lines.
    var lines: [String] {
        normalizedNewlines.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private static func isLineTerminator(_ s: Unicode.Scalar) -> Bool {
        switch s {
        case "\n", "\r", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}": return true
        default: return false
        }
    }

    /// True when the string is empty or holds nothing but whitespace — including NBSP and the
    /// zero-width characters that survive a naive space-only check.
    var isBlankLine: Bool {
        allSatisfy { $0.isPlakkeWhitespace || $0.isZeroWidth }
    }

    /// Truncates to at most `maxBytes` UTF-8 bytes without splitting a grapheme cluster.
    /// The size caps are byte budgets, so counting Characters (as the old code did) let a clip of
    /// CJK or emoji reach four times the documented limit.
    func truncatedToUTF8(_ maxBytes: Int) -> String {
        guard utf8.count > maxBytes else { return self }
        var out = String()
        out.reserveCapacity(maxBytes)
        var used = 0
        for ch in self {
            let n = String(ch).utf8.count
            if used + n > maxBytes { break }
            out.append(ch)
            used += n
        }
        return out
    }

    /// Leading whitespace kept verbatim, internal runs collapsed to one space.
    /// Prose indentation carries meaning — aligned columns, nested outlines — and dropping it
    /// flattened both.
    var collapsingWhitespaceKeepingIndent: String {
        let indent = leadingWhitespace
        let rest = String(dropFirst(indent.count)).collapsingWhitespace
        return rest.isEmpty ? "" : indent + rest
    }

    /// NBSP and friends become ordinary spaces, zero-width characters go, indentation is untouched.
    /// Used for code, where collapsing runs would break alignment but an NBSP from a web page is
    /// still something that won't compile.
    var normalizingInvisibles: String {
        var out = String()
        out.reserveCapacity(count)
        for ch in self {
            if ch.isZeroWidth { continue }
            if ch != " " && ch != "\t" && ch.isPlakkeWhitespace { out.append(" "); continue }
            out.append(ch)
        }
        return out
    }

    /// Collapses runs of whitespace to a single space and drops zero-width characters.
    var collapsingWhitespace: String {
        var out = String()
        out.reserveCapacity(count)
        var pendingSpace = false
        for ch in self {
            if ch.isZeroWidth { continue }
            if ch.isPlakkeWhitespace {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace { out.append(" ") }
            pendingSpace = false
            out.append(ch)
        }
        return out
    }

    /// Trailing whitespace removed, indentation untouched (used when tidying code).
    var trimmingTrailingWhitespace: String {
        var s = self
        while let last = s.last, last.isPlakkeWhitespace || last.isZeroWidth { s.removeLast() }
        return s
    }

    /// Leading whitespace, as a string — so reflow can put indentation back.
    var leadingWhitespace: String {
        String(prefix { $0.isPlakkeWhitespace })
    }
}

extension Character {
    /// Any Unicode whitespace: space, tab, NBSP, the en/em spaces, ideographic space…
    /// `isWhitespace` rather than a bridged `CharacterSet` lookup, which this pays per character of
    /// a clip up to 1 MB.
    var isPlakkeWhitespace: Bool { isWhitespace }

    /// Zero-width characters that shouldn't count as content.
    ///
    /// Deliberately NOT the bidi marks U+200E/U+200F: stripping those from Hebrew or Arabic changes
    /// how the line renders. Nor the soft hyphen U+00AD, which Reflow needs to see at end of line to
    /// rejoin a split word — treating it as nothing produced "remain ing".
    var isZeroWidth: Bool {
        unicodeScalars.allSatisfy {
            switch $0 {
            case "\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}": return true
            default: return false
            }
        }
    }

    /// A discretionary hyphen, which Reflow treats as a line-break hyphen.
    var isSoftHyphen: Bool { unicodeScalars.allSatisfy { $0 == "\u{00AD}" } }
}
