import Foundation

/// Paste-time text transforms. Tap the key while the switcher is up; release ⌥ to paste the result.
enum Transform: CaseIterable {
    case uppercase, lowercase, tidy, reflow, markdown, colorFormat, json

    var key: Int64 {
        switch self {
        case .uppercase:   return 32   // U
        case .lowercase:   return 37   // L
        case .tidy:        return 17   // T
        case .reflow:      return 15   // R
        case .markdown:    return 46   // M
        case .colorFormat: return 8    // C
        case .json:        return 38   // J
        }
    }

    var label: String {
        switch self {
        case .uppercase:   return "UPPERCASE"
        case .lowercase:   return "lowercase"
        case .tidy:        return "Tidy whitespace"
        case .reflow:      return "Reflow paragraphs"
        case .markdown:    return "Markdown"
        case .colorFormat: return "Colour format"
        case .json:        return "JSON"
        }
    }

    var symbol: String {
        switch self {
        case .uppercase:   return "textformat.size.larger"
        case .lowercase:   return "textformat.size.smaller"
        case .tidy:        return "text.justify.leading"
        case .reflow:      return "text.word.spacing"
        case .markdown:    return "number"
        case .colorFormat: return "eyedropper"
        case .json:        return "curlybraces"
        }
    }

    static func forKey(_ key: Int64) -> Transform? {
        allCases.first { $0.key == key }
    }

    /// Canonical pipeline order: convert the value first, then fix structure, then case, then wrap
    /// in Markdown. Press order doesn't matter — Reflow always runs before Lowercase, Markdown last.
    static let pipelineOrder: [Transform] = [.json, .colorFormat, .reflow, .tidy,
                                             .uppercase, .lowercase, .markdown]

    static func ordered(_ chain: [Transform]) -> [Transform] {
        pipelineOrder.filter { chain.contains($0) }
    }

    /// Which transforms are worth offering for this clip. Colour and JSON only make sense when the
    /// text is actually one of those, so they aren't advertised — or armable — otherwise.
    static func applicable(to item: ClipItem) -> [Transform] {
        guard let text = item.plainText else { return [] }
        return pipelineOrder.filter { $0.applies(to: text) }
    }

    func applies(to text: String) -> Bool {
        switch self {
        case .colorFormat: return ColorFormat.detect(text) != nil
        case .json:        return JSONFormat.isJSON(text)
        default:           return true
        }
    }

    /// Applies a set of transforms to the clip's text in canonical order.
    static func apply(_ chain: [Transform], to item: ClipItem) -> String? {
        guard let text = item.plainText else { return nil }
        return apply(chain, to: text, kind: item.kind)
    }

    /// Newlines are normalised once, up front: every line-based step below would otherwise see a
    /// CRLF document as a single line and quietly do nothing.
    static func apply(_ chain: [Transform], to text: String, kind: ClipKind) -> String {
        let steps = ordered(chain)
        // Once JSON has been reformatted the text *is* code, whatever the clip was classified as.
        // Without this, J+T collapsed the indentation J had just added, and J+R joined every line of a
        // pretty-printed object into one 700-character run.
        let effective: ClipKind = steps.contains(.json) ? .code : kind
        return steps.reduce(text.normalizedNewlines) { $1.apply($0, kind: effective) }
    }

    func apply(_ text: String, kind: ClipKind) -> String {
        switch self {
        case .uppercase:
            return kind == .url ? text : text.uppercased()      // never change a URL's case
        case .lowercase:
            return kind == .url ? text : Self.lowercasedWithFinalSigma(text)
        case .tidy:
            return Self.tidy(text, kind: kind)
        case .reflow:
            return kind == .code ? text : Self.reflow(text)   // never reflow code
        case .markdown:
            return Self.markdown(text, kind: kind)
        case .colorFormat:
            return ColorFormat.converted(text) ?? text
        case .json:
            return JSONFormat.converted(text) ?? text
        }
    }

    /// Transforms that cancel each other out; arming one disarms the other.
    var conflicts: Transform? {
        switch self {
        case .uppercase: return .lowercase
        case .lowercase: return .uppercase
        default: return nil
        }
    }
}

// MARK: - Case

extension Transform {
    /// Final_Sigma also requires something cased *before* it — without the lookbehind a standalone
    /// summation sign Σ lowercased to ς.
    private static let finalSigma = try? NSRegularExpression(pattern: #"(?<=[\p{L}\p{M}])σ(?![\p{L}\p{M}])"#)

    /// `lowercased()` doesn't apply the Final_Sigma rule, so Greek words came out ending in σ.
    static func lowercasedWithFinalSigma(_ text: String) -> String {
        let lower = text.lowercased()
        guard lower.contains("σ"), let re = finalSigma else { return lower }
        let ns = NSMutableString(string: lower)
        re.replaceMatches(in: ns, range: NSRange(location: 0, length: ns.length), withTemplate: "ς")
        return ns as String
    }
}

// MARK: - Tidy

extension Transform {
    /// Trim trailing whitespace, collapse runs of blank lines to one, strip leading/trailing blank
    /// lines. Prose also gets internal whitespace runs collapsed; code keeps its indentation.
    /// "Whitespace" means every Unicode space — tabs and NBSP (ubiquitous in text copied from Word
    /// and the web) used to survive untouched, including NBSP-only lines that defeated the
    /// blank-line collapsing below.
    static func tidy(_ text: String, kind: ClipKind) -> String {
        var out: [String] = []
        for raw in text.lines {
            let line = kind == .code
                ? raw.normalizingInvisibles.trimmingTrailingWhitespace
                : raw.collapsingWhitespaceKeepingIndent
            if line.isBlankLine {
                if out.last?.isEmpty ?? true { continue }
                out.append("")
                continue
            }
            out.append(line)
        }
        while out.last?.isEmpty == true { out.removeLast() }
        while out.first?.isEmpty == true { out.removeFirst() }
        return out.joined(separator: "\n")
    }
}

// MARK: - Markdown

extension Transform {
    static func markdown(_ text: String, kind: ClipKind) -> String {
        switch kind {
        case .url:
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let host = (URL(string: t)?.host ?? t)
                .replacingOccurrences(of: #"\"#, with: #"\\"#)
                .replacingOccurrences(of: "[", with: #"\["#)
                .replacingOccurrences(of: "]", with: #"\]"#)
            return "[\(host)](\(linkDestination(t)))"
        case .code:
            return fenced(text)
        default:
            return text.lines
                .map { line in
                    if line.isBlankLine { return ">" }
                    // Already quoted: deepening it to "> >" isn't what M means.
                    if line.hasPrefix(">") { return line }
                    return "> \(line)"
                }
                .joined(separator: "\n")
        }
    }

    /// A destination containing parens or whitespace has to be wrapped in angle brackets, or
    /// CommonMark ends the link at the first unbalanced ")" — `https://x/a)b` became a link to
    /// `https://x/a` followed by a literal "b)".
    private static func linkDestination(_ url: String) -> String {
        // Angle brackets are escaped either way: unwrapped they still end a CommonMark autolink.
        let escaped = url
            .replacingOccurrences(of: "<", with: "%3C")
            .replacingOccurrences(of: ">", with: "%3E")
        let needsWrapping = escaped.contains("(") || escaped.contains(")")
            || escaped.contains(where: { $0.isPlakkeWhitespace })
        return needsWrapping ? "<\(escaped)>" : escaped
    }

    /// Picks a fence longer than any backtick run inside the code, so a snippet that already
    /// contains ``` doesn't close the block early and leave a dangling fence behind.
    private static func fenced(_ code: String) -> String {
        var longestRun = 0
        var run = 0
        for ch in code {
            if ch == "`" {
                run += 1
                longestRun = max(longestRun, run)
            } else {
                run = 0
            }
        }
        let fence = String(repeating: "`", count: max(3, longestRun + 1))
        var body = code
        while body.last == "\n" { body.removeLast() }      // no blank line before the closing fence
        return "\(fence)\n\(body)\n\(fence)"
    }
}

// MARK: - Reflow

extension Transform {
    /// Joins hard-wrapped lines (scans, OCR, emails) back into paragraphs.
    ///
    /// A line ends a paragraph if it's blank, ends with sentence punctuation before a capital, or is
    /// noticeably shorter than the surrounding lines. List items stay one per line, quote markers
    /// are carried on the paragraph instead of stranded mid-sentence, and anything structural
    /// (headings, tables, fenced or indented blocks, `key: value` lines) is passed through verbatim.
    static func reflow(_ text: String) -> String {
        let parsed = text.lines.map(Line.init)

        // Mark fenced regions before anything else; their contents are untouchable.
        var inFence = false
        var lines: [Line] = []
        for var line in parsed {
            if line.body.hasPrefix("```") || line.body.hasPrefix("~~~") {
                line.isVerbatim = true
                inFence.toggle()
            } else if inFence {
                line.isVerbatim = true
            }
            lines.append(line)
        }

        // The wrap width is measured from running prose only. List items are short by nature and
        // used to drag the median down, which made real prose lines look "short" and broke the
        // paragraph detection around every list.
        let prose = lines.filter {
            !$0.isBlank && !$0.isVerbatim && !$0.isStructural && !isListItem($0.body)
        }
        let lengths = prose.map(\.body.count).sorted()
        guard !lengths.isEmpty else { return text }
        let median = lengths[lengths.count / 2]

        // A few genuinely short lines is an address, a signature or a menu — not hard-wrapped prose.
        // Joining those was the worst of Reflow's false positives, so leave small blocks alone.
        if prose.count <= 6 && median < 30 { return text }

        let shortLimit = Int(Double(median) * 0.6)
        let terminators: Set<Character> = [".", "!", "?", ":", "\u{201D}", "\"", "\u{2019}", ")", "\u{00BB}"]

        var blocks: [Block] = []
        var current = ""
        var currentQuote = 0
        var currentIsList = false

        func flush() {
            let body = current.trimmingCharacters(in: .whitespaces)
            current = ""
            guard !body.isEmpty else { currentIsList = false; return }
            let prefix = String(repeating: "> ", count: currentQuote)
            blocks.append(Block(text: prefix + body, kind: currentIsList ? .list : .prose))
            currentIsList = false
        }

        for (i, line) in lines.enumerated() {
            // Verbatim first: a blank line inside a fenced block is part of the code, and testing
            // blankness ahead of it silently deleted those lines from blocks declared untouchable.
            if line.isBlank && !line.isVerbatim { flush(); continue }

            if line.isVerbatim || line.isStructural {
                flush()
                blocks.append(Block(text: line.raw, kind: .verbatim))
                continue
            }

            // Quote depth is part of the paragraph, not part of the text: joining "> a" and "> b"
            // used to produce "a > b".
            if line.quote != currentQuote { flush() }
            currentQuote = line.quote

            let startsList = isListItem(line.body)
            if startsList { flush(); currentQuote = line.quote }

            if current.last?.isSoftHyphen == true, let first = line.body.first, first.isLowercase {
                current.removeLast()            // discretionary hyphen: the word was never really split
                current += line.body
            } else if current.hasSuffix("-"), let first = line.body.first, first.isLowercase || first.isNumber {
                // A lowercase continuation is a word split across lines ("remain-\ning"), so the
                // hyphen goes. A digit continuation means the hyphen belongs to the token
                // ("COVID-\n19", "ISO-\n8601), so it stays — either way, no space is inserted.
                if first.isLowercase { current.removeLast() }
                current += line.body
            } else {
                current += current.isEmpty ? line.body : " " + line.body
            }
            if startsList { currentIsList = true }

            let next = lines.dropFirst(i + 1).first { !$0.isBlank }
            let nextBody = next?.body ?? ""
            let nextIsList = next.map { isListItem($0.body) } ?? false
            let nextIsStructural = next.map { $0.isStructural || $0.isVerbatim } ?? false
            // Anything that isn't a lowercase letter starts something new: a digit, a quote or an
            // opening paren used to count as "continuation" and get absorbed into the bullet above.
            let nextStartsUpper = !(nextBody.first?.isLowercase ?? false)
            let nextQuoteDiffers = next.map { $0.quote != currentQuote } ?? false

            if currentIsList {
                // A list item ends at its own line unless the next line is a lowercase continuation
                // of it — otherwise the sentence after the last bullet got absorbed into the bullet.
                if next == nil || nextIsList || nextIsStructural || nextStartsUpper || nextQuoteDiffers {
                    flush()
                }
                continue
            }

            let endsSentence = line.body.last.map(terminators.contains) ?? false
            let isShort = line.body.count < shortLimit
            if isShort || nextIsList || nextIsStructural || nextQuoteDiffers
                || (endsSentence && nextStartsUpper) { flush() }
        }
        flush()

        // Consecutive list items (and consecutive verbatim lines) stay tight; paragraphs get a
        // blank line between them.
        var out = ""
        for (i, b) in blocks.enumerated() {
            if i > 0 {
                let prev = blocks[i - 1].kind
                let tight = (b.kind == .list && prev == .list) || (b.kind == .verbatim && prev == .verbatim)
                out += tight ? "\n" : "\n\n"
            }
            out += b.text
        }
        return out
    }

    private struct Block {
        enum Kind { case prose, list, verbatim }
        var text: String
        var kind: Kind
    }

    /// One source line, split into the parts reflow needs: its indentation, its quote depth, and
    /// the text itself.
    private struct Line {
        var raw: String
        var indent: String
        var quote: Int
        var body: String
        var isVerbatim = false

        init(_ raw: String) {
            self.raw = raw
            self.indent = raw.leadingWhitespace
            var rest = Substring(raw.dropFirst(indent.count))
            var depth = 0
            while rest.first == ">" {
                depth += 1
                rest = rest.dropFirst()
                // All of it, not one space: Outlook and Gmail align nested quotes as ">   >", and
                // consuming a single space left the inner markers embedded mid-sentence.
                while let c = rest.first, c.isPlakkeWhitespace, c != "\n" { rest = rest.dropFirst() }
            }
            self.quote = depth
            self.body = String(rest).trimmingTrailingWhitespace
        }

        var isBlank: Bool { body.isBlankLine }

        /// Structure that must survive verbatim: markdown headings and tables, horizontal rules,
        /// `key: value` config lines, and anything indented like a code block.
        var isStructural: Bool {
            if indent.count >= 4 || indent.contains("\t") { return true }
            if body.hasPrefix("#"), body.dropFirst().first.map({ $0 == "#" || $0 == " " }) ?? false { return true }
            if body.hasPrefix("|") { return true }
            if body.range(of: #"^[-=_*]{3,}$"#, options: .regularExpression) != nil { return true }
            if let m = body.range(of: #"^[\w.$-]+\s*[:=]\s*"#, options: .regularExpression) {
                // A config line, not prose. `Note: this caveat matters a great deal` matched the bare
                // pattern and split the paragraph it was wrapped inside, so a value containing spaces
                // only counts when it is indented like a block.
                let value = body[m.upperBound...].trimmingCharacters(in: .whitespaces)
                if !value.isEmpty && (!indent.isEmpty || !value.contains(" ")) { return true }
            }
            return false
        }
    }

    /// Bullets, 1-2 digit numbers, and lowercase letter markers.
    ///
    /// Three digits let `2024. The report said…` read as a list item, and an uppercase letter let
    /// `J. R. R. Tolkien wrote…` do the same — both got flushed out of their paragraph and fenced off
    /// with blank lines.
    private static func isListItem(_ line: String) -> Bool {
        line.range(of: #"^([-*•▪◦]|\d{1,2}[.)]|[a-z][.)])\s+\S"#, options: .regularExpression) != nil
    }
}
