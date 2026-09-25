import AppKit
import CryptoKit
import SwiftUI

enum PlakkeColor {
    /// Red used for secrets: 4.98:1 in light mode, the pastel in dark.
    static let secret = dynamic(light: 0xD32F2F, dark: 0xF25966)

    /// A colour that follows the appearance and the Increase Contrast setting — the old hardcoded
    /// `Color(red:green:blue:)` values responded to neither.
    ///
    /// Increase Contrast is read from NSWorkspace rather than the appearance name: a dynamic
    /// provider isn't handed the high-contrast appearance unless the colour declares support for it,
    /// so switching on `appearance.name` silently did nothing (measured: 4.61:1 either way).
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let base = NSColor(rgb: isDark ? dark : light)
            guard NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast else { return base }
            return base.blended(withFraction: 0.3, of: isDark ? .white : .black) ?? base
        })
    }
}

extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255,
                  alpha: 1)
    }
}

enum ClipKind: String, Codable {
    case text, code, url, color, image, file

    var label: String {
        switch self {
        case .text:  return "Text"
        case .code:  return "Code"
        case .url:   return "Link"
        case .color: return "Color"
        case .image: return "Image"
        case .file:  return "Files"
        }
    }

    var symbol: String {
        switch self {
        case .text:  return "text.alignleft"
        case .code:  return "chevron.left.forwardslash.chevron.right"
        case .url:   return "link"
        case .color: return "paintpalette"
        case .image: return "photo"
        case .file:  return "doc.on.doc"
        }
    }

    /// Glow colour: borders, shadows, swatches. Light pastels, tuned for the dark material — they
    /// only ever sit behind or beside text, never carry it.
    var accent: Color {
        switch self {
        case .text:  return Color(red: 0.55, green: 0.65, blue: 1.00)
        case .code:  return Color(red: 0.98, green: 0.62, blue: 0.35)
        case .url:   return Color(red: 0.35, green: 0.85, blue: 0.75)
        case .color: return Color(red: 0.95, green: 0.45, blue: 0.75)
        case .image: return Color(red: 0.80, green: 0.55, blue: 1.00)
        case .file:  return Color(red: 0.98, green: 0.82, blue: 0.35)
        }
    }

    /// The same hue at text strength. The pastels above measure 1.5:1 (Files) to 2.6:1 (Color)
    /// against a white backdrop, so using them for 10pt text failed the 4.5:1 requirement by a wide
    /// margin in light mode. These light variants are 4.6-5.3:1; dark mode keeps the pastels, which
    /// pass comfortably there.
    var textAccent: Color {
        switch self {
        case .text:  return PlakkeColor.dynamic(light: 0x4A6BE8, dark: 0x8CA6FF)   // 4.60:1
        case .code:  return PlakkeColor.dynamic(light: 0xB35A00, dark: 0xFA9E59)   // 4.80:1
        case .url:   return PlakkeColor.dynamic(light: 0x00826D, dark: 0x59D9BF)   // 4.76:1
        case .color: return PlakkeColor.dynamic(light: 0xD81B7A, dark: 0xF273BF)   // 4.82:1
        case .image: return PlakkeColor.dynamic(light: 0x8B4BF0, dark: 0xCC8CFF)   // 4.81:1
        case .file:  return PlakkeColor.dynamic(light: 0x8A6A00, dark: 0xFAD159)   // 5.07:1
        }
    }

    // MARK: classification

    /// Only the head of a clip is scanned: a 50 MB paste must not drag the main thread through
    /// twenty `contains` passes and two regexes before the card can be drawn.
    static let scanLimit = 64 * 1024

    static func classify(_ s: String) -> ClipKind {
        let head = s.truncatedToUTF8(scanLimit)
        let t = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if isColor(t) { return .color }
        if isURL(t) { return .url }
        if looksLikeCode(t) { return .code }
        return .text
    }

    static func isColor(_ t: String) -> Bool {
        // 3, 4 (#RGBA), 6 or 8 digits — the short alpha form was the one gap.
        t.range(of: #"^#(?:[0-9a-fA-F]{3,4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$"#,
                options: .regularExpression) != nil
    }

    static func isURL(_ t: String) -> Bool {
        guard !t.contains("\n"), !t.contains("\r"), !t.contains(" "), let u = URL(string: t),
              let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme),
              u.host != nil else { return false }
        return true
    }

    // Compiled once. `range(of:options:.regularExpression)` builds a fresh NSRegularExpression on
    // every call, and these ran per line over the 64 KB head — 93 ms on a large multi-line clip, on
    // the main thread, for every copy.
    private static let keyValueHead = try? NSRegularExpression(pattern: #"^\s*[\w.$-]+\s*[:=]\s*"#)
    private static let blockOpener = try? NSRegularExpression(
        pattern: #"^\s*(def|class|if|for|while|with|try|else|elif|switch|case)\b.*:\s*$"#)
    /// "git is a distributed version control system" is a sentence about a command, not a command.
    private static let copula = try? NSRegularExpression(pattern: #"\b(is|are|was|were|means|stands)\b"#)

    private static func matches(_ re: NSRegularExpression?, _ s: String) -> NSRange? {
        guard let re else { return nil }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return re.firstMatch(in: s, range: range)?.range
    }

    static func looksLikeCode(_ t: String) -> Bool {
        let lines = t.lines
        let tokens = ["{", "}", ";", "=>", "->", "func ", "def ", "import ", "const ", "let ",
                      "var ", "return ", "class ", "#include", "</", "/>", "==", "!=", "&&", "||", "$("]
        var score = tokens.reduce(0) { $0 + (t.contains($1) ? 1 : 0) }
        let nonEmpty = lines.filter { !$0.isBlankLine }
        let indented = lines.filter { $0.hasPrefix("  ") || $0.hasPrefix("\t") }.count

        // Indentation alone is not code — a quoted email or any indented prose has it too. It only
        // counts once something else already looks code-ish, and only for real multi-line blocks.
        if lines.count >= 2 && indented >= 1 && (score > 0 || indented >= 2) { score += 2 }

        // Config/markup shapes the token list misses entirely: `key: value` blocks (YAML, Procfile),
        // and block openers ending in ':' (Python). The value has to look like a value, though —
        // counting any `Word: …` line made every email header block and contact card "code".
        let keyValue = nonEmpty.filter { line in
            guard let r = matches(keyValueHead, line), let upper = Range(r, in: line)?.upperBound
            else { return false }
            let value = line[upper...].trimmingCharacters(in: .whitespaces)
            return !value.isEmpty && !value.contains(" ")
        }.count
        if keyValue >= 2 && keyValue * 2 >= nonEmpty.count { score += 3 }

        if nonEmpty.contains(where: { matches(blockOpener, $0) != nil }) && indented >= 1 { score += 3 }

        let firstLine = lines.first ?? ""
        if matches(copula, firstLine) == nil {
            for prefix in ["$ ", "git ", "npm ", "brew ", "curl ", "sudo ", "cd "]
            where t.hasPrefix(prefix) { score += 3 }
        }
        return score >= 3
    }
}

struct ClipItem: Identifiable, Codable, Equatable {
    let id: UUID
    let kind: ClipKind
    var date: Date
    let sourceBundleID: String?

    let text: String?
    let rtf: Data?
    let html: Data?
    let imageFile: String?
    let fileURLs: [String]?
    /// SHA-256 of the image bytes, so a re-copied image dedupes instead of piling up PNGs.
    let imageHash: String?

    /// Short excerpt used by the cards, so a 5 MB clip never reaches SwiftUI layout.
    let preview: String?

    var pinned: Bool = false
    var ocrText: String? = nil
    /// Precomputed so the card doesn't re-excerpt the whole OCR string on every render.
    var ocrPreview: String? = nil

    /// Secrets from password managers: kept in memory only, blurred on the card, gone after `secretLifetime`.
    var expiresAt: Date? = nil
    var isSecret: Bool { expiresAt != nil }
    static let secretLifetime: TimeInterval = 60

    // Size limits, in UTF-8 bytes. Text beyond `maxTextBytes` is truncated; rich forms beyond
    // `maxRichBytes` are dropped; an image past `maxImageBytes` is not worth a history slot.
    static let maxTextBytes = 1_000_000
    static let maxRichBytes = 256 * 1024
    static let maxImageBytes = 64 * 1024 * 1024
    static let maxFileURLs = 512
    static let previewChars = 400
    static let previewLines = 10

    init(kind: ClipKind, sourceBundleID: String?, text: String? = nil, rtf: Data? = nil,
         html: Data? = nil, imageFile: String? = nil, imageHash: String? = nil,
         fileURLs: [String]? = nil, expiresAt: Date? = nil) {
        self.id = UUID()
        self.kind = kind
        self.date = Date()
        self.sourceBundleID = sourceBundleID
        self.text = text.map { $0.truncatedToUTF8(Self.maxTextBytes) }
        self.rtf = rtf.flatMap { $0.count > Self.maxRichBytes ? nil : $0 }
        self.html = html.flatMap { $0.count > Self.maxRichBytes ? nil : $0 }
        self.imageFile = imageFile
        self.imageHash = imageHash
        self.fileURLs = fileURLs.map { Array($0.prefix(Self.maxFileURLs)) }
        self.preview = self.text.map(Self.makePreview)
        self.expiresAt = expiresAt
    }

    static func makePreview(_ text: String) -> String {
        // Bound the input first: makePreview used to split a whole 1 MB clip to keep ten lines.
        let head = text.truncatedToUTF8(previewChars * 8)
        let lines = head.lines.prefix(previewLines)
        let joined = lines.joined(separator: "\n")
        return joined.count > previewChars ? String(joined.prefix(previewChars)) + "…" : joined
    }

    static func hash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // Tolerant decoding so histories written by older builds still load.
    private enum CodingKeys: String, CodingKey {
        case id, kind, date, sourceBundleID, text, rtf, html, imageFile, imageHash, fileURLs,
             preview, pinned, ocrText, ocrPreview
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(ClipKind.self, forKey: .kind)
        date = try c.decode(Date.self, forKey: .date)
        sourceBundleID = try c.decodeIfPresent(String.self, forKey: .sourceBundleID)
        // The same caps the memberwise init applies: a history written by another build, or hand
        // edited, would otherwise load unbounded values into memory and write them straight back out.
        text = try c.decodeIfPresent(String.self, forKey: .text)?.truncatedToUTF8(Self.maxTextBytes)
        rtf = try c.decodeIfPresent(Data.self, forKey: .rtf).flatMap { $0.count > Self.maxRichBytes ? nil : $0 }
        html = try c.decodeIfPresent(Data.self, forKey: .html).flatMap { $0.count > Self.maxRichBytes ? nil : $0 }
        imageFile = try c.decodeIfPresent(String.self, forKey: .imageFile)
        imageHash = try c.decodeIfPresent(String.self, forKey: .imageHash)
        fileURLs = try c.decodeIfPresent([String].self, forKey: .fileURLs)
        preview = try c.decodeIfPresent(String.self, forKey: .preview) ?? text.map(Self.makePreview)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        ocrText = try c.decodeIfPresent(String.self, forKey: .ocrText)
        ocrPreview = try c.decodeIfPresent(String.self, forKey: .ocrPreview) ?? ocrText.map(Self.makePreview)
        expiresAt = nil          // secrets are never persisted, so nothing to decode
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(date, forKey: .date)
        try c.encodeIfPresent(sourceBundleID, forKey: .sourceBundleID)
        try c.encodeIfPresent(text, forKey: .text)
        try c.encodeIfPresent(rtf, forKey: .rtf)
        try c.encodeIfPresent(html, forKey: .html)
        try c.encodeIfPresent(imageFile, forKey: .imageFile)
        try c.encodeIfPresent(imageHash, forKey: .imageHash)
        try c.encodeIfPresent(fileURLs, forKey: .fileURLs)
        try c.encodeIfPresent(preview, forKey: .preview)
        try c.encode(pinned, forKey: .pinned)
        try c.encodeIfPresent(ocrText, forKey: .ocrText)
        try c.encodeIfPresent(ocrPreview, forKey: .ocrPreview)
    }

    /// True if this and `other` are the same clip (used to dedupe repeated copies).
    func isSameContent(as other: ClipItem) -> Bool {
        guard kind == other.kind else { return false }
        switch kind {
        case .image:
            guard let a = imageHash, let b = other.imageHash else { return false }
            return a == b
        case .file:  return fileURLs == other.fileURLs
        default:     return text == other.text
        }
    }

    /// The text a transform would operate on. Images fall back to OCR; file references have no
    /// text form, so transforms don't apply to them — arming one used to leave the card showing
    /// files while the paste silently became transformed filenames.
    var plainText: String? {
        switch kind {
        case .image: return ocrText
        case .file:  return nil
        default:     return text
        }
    }

    /// Whether ⇧ (plain paste) has something to give: the OCR text of an image, the names of a
    /// Files clip, or the text itself.
    var canPastePlain: Bool {
        switch kind {
        case .image: return ocrText?.isEmpty == false
        case .file:  return text?.isEmpty == false
        default:     return text?.isEmpty == false
        }
    }

    var title: String {
        switch kind {
        case .url:
            if let t = text, let u = URL(string: t.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return u.host ?? t
            }
            return text ?? ""
        case .file:
            return (fileURLs ?? []).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        case .image:
            return ocrText.map { String($0.prefix(60)) } ?? "Image"
        default:
            return text ?? ""
        }
    }

    /// Title safe to show in the menu bar. `title` is cleartext, and the ⌥-alternate menu item used
    /// it verbatim — which put the first 48 characters of a password on screen.
    var safeTitle: String {
        guard !isSecret else { return "Secret (\(sourceBundleID ?? "unknown app"))" }
        let flat = title.lines.joined(separator: " ⏎ ")
        let short = flat.count > 48 ? String(flat.prefix(48)) + "…" : flat
        return short.isEmpty ? kind.label : short
    }
}
