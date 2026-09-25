import AppKit
import SwiftUI

/// Every font in the strip goes through here, so "Larger Cards" scales type and layout together.
func pFont(_ size: CGFloat, _ weight: Font.Weight = .regular, _ design: Font.Design = .default) -> Font {
    .system(size: size * SwitcherView.scale, weight: weight, design: design)
}

struct SwitcherView: View {
    @ObservedObject var model: SwitcherController
    @State private var now = Date()
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // Accessibility appearance settings. None of these were consulted before: the panel was always
    // translucent and every selection change always sprang, whatever the user had asked for.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 1.0, or 1.25 with "Larger Cards" on. Read as a static so the controller can size the panel
    /// from the same numbers the view draws with.
    static var scale: CGFloat { Settings.cardScale }

    // Layout constants (also used to size the panel).
    static var cardWidth: CGFloat { 172 * scale }
    static var cardHeight: CGFloat { 136 * scale }
    static var spacing: CGFloat { 12 * scale }
    static var dividerWidth: CGFloat { 1 }
    static var edgeWidth: CGFloat { 26 * scale }       // "‹ 3" / "4 ›" indicators
    static var inset: CGFloat { 18 * scale }           // inside the glass
    static var margin: CGFloat { 32 * scale }          // outside the glass, room for glow + scale
    static var peekWidth: CGFloat { 640 * scale }
    static var peekHeight: CGFloat { 300 * scale }
    static var hintHeight: CGFloat { 18 * scale }
    static var cardPadding: CGFloat { 12 * scale }

    // Concentric corners: a nested radius is the outer radius minus the padding between them.
    // The panel was 26 with an 18pt inset while the cards used 16, so none of them nested.
    static var cardRadius: CGFloat { 16 * scale }
    static var panelRadius: CGFloat { cardRadius + inset }          // 34 at 1.0
    static var innerRadius: CGFloat { cardRadius - cardPadding }    // 4 at 1.0

    /// One chip in the hint row. The row is built from these in both the view and the sizer, so the
    /// panel can't end up narrower than the hints it's about to draw.
    struct HintSpec {
        var key: String
        var action: String
    }

    /// Everything the panel size depends on.
    struct Layout {
        var visible: [ClipItem]
        var moreLeft: Int
        var moreRight: Int
        var transforms: [Transform]
        var hints: [HintSpec]
        var failure: String?
    }

    static func stripWidth(_ l: Layout) -> CGFloat {
        let n = l.visible.count
        guard n > 0 else { return 320 * scale }
        var w = CGFloat(n) * cardWidth + CGFloat(n - 1) * spacing
        if l.visible.contains(where: \.pinned) && l.visible.contains(where: { !$0.pinned }) {
            w += dividerWidth + spacing
        }
        if l.moreLeft > 0  { w += edgeWidth + spacing }
        if l.moreRight > 0 { w += edgeWidth + spacing }
        return w
    }

    /// Width of the hint row, estimated from the chips that will actually be drawn. The old fixed
    /// guess was ~100-160pt short of the full row, so with one to three clips the labels ellipsized.
    static func hintWidth(_ l: Layout) -> CGFloat {
        if let failure = l.failure {
            return (CGFloat(failure.count) * 6.5 + 60) * scale
        }
        var w: CGFloat = 0
        for h in l.hints {
            w += CGFloat(h.key.count) * 6.5 + 16 + CGFloat(h.action.count) * 6.0 + 4
        }
        for t in l.transforms {
            w += CGFloat(t.label.count) * 6.0 + 42        // capsule + icon + the "→" between pills
        }
        let chips = l.hints.count + l.transforms.count
        if chips > 1 { w += CGFloat(chips - 1) * 12 }
        return w * scale
    }

    static func size(layout l: Layout, peeking: Bool) -> CGSize {
        var content = max(stripWidth(l), hintWidth(l))
        var height = cardHeight + 12 * scale + hintHeight
        if peeking {
            content = max(content, peekWidth)
            height += peekHeight + 12 * scale
        }
        return CGSize(width: content + inset * 2 + margin * 2,
                      height: height + inset * 2 + margin * 2)
    }

    /// The single source of truth for the hint row.
    static func hintSpecs(for model: SwitcherController) -> [HintSpec] {
        // Nothing in the strip: don't advertise paste/peek/pin/remove, all of which are no-ops.
        guard let sel = model.selectedItem else {
            var out = [HintSpec(key: "esc", action: "cancel")]
            if model.canUndo { out.insert(HintSpec(key: "⌘Z", action: "undo"), at: 0) }
            return out
        }
        // A latched session owns the keyboard: ⌥ release no longer pastes and most keys are inert, so
        // advertise only what actually works. Keying this off `crop` alone meant that leaving crop
        // mode — while still latched — showed the full row, every line of which was a lie but `esc`.
        if model.isLatched || model.crop != nil {
            var out: [HintSpec] = []
            if model.crop != nil { out.append(HintSpec(key: "drag", action: "adjust")) }
            out.append(HintSpec(key: "⏎", action: "paste"))
            if model.crop != nil {
                out.append(HintSpec(key: "X", action: "full image"))
            } else if model.canEnterCropMode {
                out.append(HintSpec(key: "X", action: "crop"))
            }
            out.append(HintSpec(key: "esc", action: "cancel"))
            return out
        }
        var out: [HintSpec] = []
        let canTransform = sel.plainText != nil
        if model.transforms.isEmpty {
            out.append(HintSpec(key: "release \(Hotkey.current.modifierSymbols)", action: "paste"))
            // Images advertise ↑↓ instead; everything else that has a text form offers ⇧.
            if sel.canPastePlain && sel.kind != .image { out.append(HintSpec(key: "⇧", action: "plain")) }
        }
        if sel.kind == .image && sel.ocrText != nil {
            out.append(HintSpec(key: "↑↓", action: model.textMode ? "image" : "text"))
        }
        out.append(HintSpec(key: "space", action: model.isPeeking ? "close" : "peek"))
        if !sel.isSecret { out.append(HintSpec(key: "P", action: sel.pinned ? "unpin" : "pin")) }
        // The offered keys follow the clip: a colour gets C, JSON gets J, neither is advertised
        // anywhere it would do nothing.
        let keys = Transform.applicable(to: sel).map { KeyNames.name(for: $0.key) }
        if canTransform, !keys.isEmpty {
            out.append(HintSpec(key: keys.joined(separator: " "), action: "transform"))
        }
        if model.canEnterCropMode { out.append(HintSpec(key: "X", action: "crop")) }
        out.append(HintSpec(key: "⌫", action: "remove"))
        if model.canUndo { out.append(HintSpec(key: "⌘Z", action: "undo")) }
        out.append(HintSpec(key: "esc", action: "cancel"))
        return out
    }

    private var layout: Layout {
        Layout(visible: Array(model.visibleItems),
               moreLeft: model.visibleRange.lowerBound,
               moreRight: max(0, model.items.count - model.visibleRange.upperBound),
               transforms: model.transforms,
               hints: Self.hintSpecs(for: model),
               failure: model.failureMessage)
    }

    var body: some View {
        let l = layout
        VStack(spacing: 12 * Self.scale) {
            if model.isPeeking, let item = model.selectedItem {
                if let crop = model.crop, let image = model.fullImage(for: item) {
                    CropEditor(image: image,
                               crop: crop,
                               fullSize: model.cropPixelSize(for: item),
                               onChange: model.updateCrop)
                        .frame(width: max(Self.stripWidth(l), Self.peekWidth),
                               height: Self.peekHeight)
                } else {
                    PeekView(item: item,
                             image: item.kind == .image ? model.fullImage(for: item) : nil,
                             transforms: model.transforms,
                             textMode: model.textMode,
                             icon: model.fileIcon(for:))
                        .frame(width: max(Self.stripWidth(l), Self.peekWidth), height: Self.peekHeight)
                }
            }
            if model.items.isEmpty {
                emptyState
            } else {
                strip(l)
            }
            if let failure = l.failure {
                failureBanner(failure)
            } else {
                hint(l)
            }
        }
        .padding(Self.inset)
        .background(panelBackground)
        .overlay(
            RoundedRectangle(cornerRadius: Self.panelRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(reduceTransparency ? 0.22 : 0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
        .padding(Self.margin)
        // Only while the strip is up: the clock outlives the panel, and assigning `now` when nobody
        // is looking invalidated the whole body once a second for the life of the process.
        .onReceive(clock) { if model.isActive { now = $0 } }
    }

    /// Reduce Transparency means an opaque panel — the frosted material is the whole point of the
    /// design, but it's also the thing that setting exists to turn off.
    @ViewBuilder
    private var panelBackground: some View {
        let shape = RoundedRectangle(cornerRadius: Self.panelRadius, style: .continuous)
        if reduceTransparency {
            shape.fill(Color(nsColor: .windowBackgroundColor))
        } else {
            shape.fill(.ultraThinMaterial)
        }
    }

    private func strip(_ l: Layout) -> some View {
        HStack(spacing: Self.spacing) {
            if l.moreLeft > 0 { EdgeIndicator(count: l.moreLeft, leading: true) }
            ForEach(Array(model.visibleItems.enumerated()), id: \.element.id) { offset, item in
                let index = model.visibleRange.lowerBound + offset
                if item.pinned, index > 0, !model.items[index - 1].pinned, offset > 0 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: Self.dividerWidth, height: Self.cardHeight * 0.6)
                }
                ClipCard(item: item,
                         index: index,
                         isSelected: index == model.selected,
                         textMode: index == model.selected && model.textMode,
                         image: item.kind == .image ? model.thumbnail(for: item) : nil,
                         appIcon: model.appIcon(for: item.sourceBundleID),
                         icon: model.fileIcon(for:),
                         now: now,
                         motion: motion,
                         transforms: index == model.selected ? model.transforms : [])
                    .transition(.opacity)
            }
            if l.moreRight > 0 { EdgeIndicator(count: l.moreRight, leading: false) }
        }
        // The window used to slide with no transition at all, so cards swapped in place and it read
        // as a glitch rather than movement.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: model.visibleRange)
    }

    /// Selection animation. A spring with a 0.22s response restarts every 0.14s while the trigger
    /// key autorepeats, so held-down cycling never settled; fast cycling gets a short crossfade.
    private var motion: Animation? {
        if reduceMotion { return nil }
        return model.fastCycling
            ? .easeOut(duration: 0.08)
            : .spring(response: 0.22, dampingFraction: 0.78)
    }

    private var emptyState: some View {
        VStack(spacing: 6 * Self.scale) {
            Image(systemName: "doc.on.clipboard")
                .font(pFont(28, .light))
                .foregroundStyle(.secondary)
            Text("Nothing to paste yet")
                .font(pFont(13, .medium))
            Text("Copy something and come back")
                .font(pFont(11))
                .foregroundStyle(.secondary)
        }
        .frame(width: 320 * Self.scale, height: Self.cardHeight)
    }

    /// Shown instead of the hint row when a paste couldn't happen. Without this the strip just
    /// closed and nothing was pasted, with no explanation anywhere.
    private func failureBanner(_ message: String) -> some View {
        HStack(spacing: 6 * Self.scale) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(pFont(10, .semibold))
            Text(message)
                .font(pFont(11, .medium))
        }
        .foregroundStyle(PlakkeColor.secret)
        .frame(height: Self.hintHeight)
        .transition(.opacity)
    }

    private func hint(_ l: Layout) -> some View {
        HStack(spacing: 12 * Self.scale) {
            if !l.transforms.isEmpty {
                HStack(spacing: 4 * Self.scale) {
                    ForEach(Array(l.transforms.enumerated()), id: \.element) { i, t in
                        if i > 0 {
                            Image(systemName: "arrow.right")
                                .font(pFont(8, .bold))
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 3 * Self.scale) {
                            Image(systemName: t.symbol)
                            Text(t.label)
                        }
                        .font(pFont(10, .semibold))
                        .padding(.horizontal, 7 * Self.scale).padding(.vertical, 2 * Self.scale)
                        .background(Color.accentColor.opacity(0.22), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                        .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                    }
                }
            }
            ForEach(Array(l.hints.enumerated()), id: \.offset) { _, spec in
                HintKey(spec.key, spec.action)
            }
        }
        .font(pFont(10.5))
        .foregroundStyle(.secondary)
        .frame(height: Self.hintHeight)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.transforms)
    }
}

/// "‹ 3" / "4 ›" — how many cards are off-screen on that side.
private struct EdgeIndicator: View {
    let count: Int
    let leading: Bool

    var body: some View {
        VStack(spacing: 3 * SwitcherView.scale) {
            // Was 9pt — below the 10pt desktop minimum.
            Image(systemName: leading ? "chevron.left" : "chevron.right")
                .font(pFont(10, .bold))
            Text("\(count)")
                .font(pFont(10, .semibold, .rounded).monospacedDigit())
        }
        .foregroundStyle(.secondary)
        .frame(width: SwitcherView.edgeWidth, height: SwitcherView.cardHeight * 0.5)
        .background(Color.primary.opacity(0.05), in: Capsule())
    }
}

private struct HintKey: View {
    let key: String
    let action: String
    init(_ key: String, _ action: String) { self.key = key; self.action = action }

    var body: some View {
        HStack(spacing: 4 * SwitcherView.scale) {
            Text(key)
                .font(pFont(10, .semibold, .rounded))
                .padding(.horizontal, 5 * SwitcherView.scale).padding(.vertical, 1.5 * SwitcherView.scale)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            Text(action)
                .fixedSize()
        }
    }
}

// MARK: - Card

struct ClipCard: View {
    let item: ClipItem
    let index: Int
    let isSelected: Bool
    let textMode: Bool
    let image: NSImage?
    let appIcon: NSImage?
    let icon: (String) -> NSImage
    let now: Date
    let motion: Animation?
    /// Armed transforms, so the card's text matches what peek and the paste show. It previously
    /// rendered the raw OCR text while both of those showed the transformed version.
    var transforms: [Transform] = []

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * SwitcherView.scale) {
            header
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
            footer
        }
        .padding(SwitcherView.cardPadding)
        .frame(width: SwitcherView.cardWidth, height: SwitcherView.cardHeight)
        .background(
            RoundedRectangle(cornerRadius: SwitcherView.cardRadius, style: .continuous)
                .fill(Color.primary.opacity(isSelected ? 0.10 : 0.04))
        )
        .overlay(
            // The border is a UI boundary, so it uses the text-strength colour; the glow below keeps
            // the pastel. That way the accent still reads as the signature without carrying text.
            RoundedRectangle(cornerRadius: SwitcherView.cardRadius, style: .continuous)
                .strokeBorder(isSelected ? textAccent : Color.primary.opacity(0.08),
                              lineWidth: isSelected ? 1.5 : 1)
        )
        .shadow(color: isSelected ? glow.opacity(0.45) : .clear, radius: 16)
        .scaleEffect(isSelected ? 1.06 : 1)
        .animation(motion, value: isSelected)
    }

    private var header: some View {
        HStack(spacing: 5 * SwitcherView.scale) {
            Image(systemName: item.isSecret ? "lock.fill" : (textMode ? "text.viewfinder" : item.kind.symbol))
                .font(pFont(10, .semibold))
                .foregroundStyle(textAccent)
            // The label is secondary now: the symbol and the glow carry the type, so the hue doesn't
            // have to survive as 10pt text on an unknown backdrop.
            Text(item.isSecret ? "Secret" : (textMode ? "Text" : item.kind.label))
                .font(pFont(10, .semibold))
                .foregroundStyle(.secondary)
            if item.kind == .image && item.ocrText != nil && !textMode {
                Image(systemName: "text.viewfinder")
                    .font(pFont(10, .semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if item.pinned {
                Image(systemName: "pin.fill")
                    .font(pFont(10, .semibold))
                    .foregroundStyle(.secondary)
            }
            if let appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 16 * SwitcherView.scale, height: 16 * SwitcherView.scale)
            }
        }
    }

    private var glow: Color { item.isSecret ? PlakkeColor.secret : item.kind.accent }
    private var textAccent: Color { item.isSecret ? PlakkeColor.secret : item.kind.textAccent }

    /// Secrets are blurred on the card; peek reveals them.
    @ViewBuilder
    private var preview: some View {
        if item.isSecret {
            rawPreview
                .blur(radius: 5)
                .overlay(
                    Image(systemName: "lock.fill")
                        .font(pFont(18, .semibold))
                        .foregroundStyle(textAccent)
                )
        } else {
            rawPreview
        }
    }

    @ViewBuilder
    private var rawPreview: some View {
        switch item.kind {
        case .text:
            Text(item.preview ?? "")
                .font(pFont(12))
                .lineLimit(5)
                .foregroundStyle(.primary)
        case .code:
            Text(item.preview ?? "")
                .font(pFont(11, .regular, .monospaced))
                .lineLimit(5)
                .foregroundStyle(.primary)
        case .url:
            VStack(alignment: .leading, spacing: 3 * SwitcherView.scale) {
                Text(item.title)
                    .font(pFont(13, .semibold))
                    .lineLimit(1)
                Text(item.preview ?? "")
                    .font(pFont(10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        case .color:
            HStack(spacing: 10 * SwitcherView.scale) {
                RoundedRectangle(cornerRadius: 10 * SwitcherView.scale, style: .continuous)
                    .fill(Color(hex: item.text ?? "") ?? .gray)
                    .frame(width: 44 * SwitcherView.scale, height: 44 * SwitcherView.scale)
                    .overlay(RoundedRectangle(cornerRadius: 10 * SwitcherView.scale)
                        .strokeBorder(.white.opacity(0.25)))
                Text((item.text ?? "").uppercased())
                    .font(pFont(13, .medium, .monospaced))
            }
        case .image:
            if textMode, let ocr = item.ocrPreview {
                Text(transforms.isEmpty ? ocr : Transform.apply(transforms, to: ocr, kind: item.kind))
                    .font(pFont(12))
                    .lineLimit(5)
                    .foregroundStyle(.primary)
                    .transition(.opacity)
            } else if let image {
                // Overlay on an empty frame so a tall/wide image can't inflate the card's layout.
                Color.clear
                    .overlay(
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: SwitcherView.innerRadius, style: .continuous))
                    .transition(.opacity)
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        case .file:
            FileList(paths: item.fileURLs ?? [], limit: 4, icon: icon)
        }
    }

    private var footer: some View {
        HStack {
            // Weight carries the selection here, not hue.
            Text("\(index + 1)")
                .font(pFont(10, .bold, .rounded).monospacedDigit())
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            Spacer()
            if let expires = item.expiresAt {
                let left = max(0, Int(expires.timeIntervalSince(now).rounded(.up)))
                HStack(spacing: 3 * SwitcherView.scale) {
                    Image(systemName: "timer").font(pFont(10))
                    Text("\(left) s").font(pFont(10, .medium).monospacedDigit())
                }
                .foregroundStyle(left <= 5 ? AnyShapeStyle(textAccent) : AnyShapeStyle(.secondary))
            } else {
                // Was `.tertiary` at 10pt — roughly 1.9:1 on a light backdrop.
                Text(Self.relative.localizedString(for: item.date, relativeTo: now))
                    .font(pFont(10))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Peek

struct PeekView: View {
    let item: ClipItem
    let image: NSImage?
    let transforms: [Transform]
    let textMode: Bool
    let icon: (String) -> NSImage

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: SwitcherView.cardRadius, style: .continuous)
                .fill(Color.primary.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: SwitcherView.cardRadius, style: .continuous)
                        .strokeBorder(item.kind.textAccent.opacity(0.5), lineWidth: 1)
                )
            content
                .padding(SwitcherView.inset)
        }
        .clipped()
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .text, .code, .url, .color:
            VStack(alignment: .leading, spacing: 8 * SwitcherView.scale) {
                if item.kind == .color {
                    RoundedRectangle(cornerRadius: 12 * SwitcherView.scale, style: .continuous)
                        .fill(Color(hex: item.text ?? "") ?? .gray)
                        .frame(height: 80 * SwitcherView.scale)
                }
                Text(displayText)
                    .font(pFont(13, .regular, item.kind == .code ? .monospaced : .default))
                    .lineLimit(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .image:
            HStack(alignment: .top, spacing: 16 * SwitcherView.scale) {
                if let image {
                    Color.clear
                        .frame(maxWidth: item.ocrText == nil ? .infinity : 300 * SwitcherView.scale,
                               maxHeight: .infinity)
                        .overlay(
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10 * SwitcherView.scale, style: .continuous))
                }
                if let ocr = item.ocrText {
                    VStack(alignment: .leading, spacing: 6 * SwitcherView.scale) {
                        Label(textMode ? "Recognised text — will paste" : "Recognised text — ↓ to paste it",
                              systemImage: "text.viewfinder")
                            .font(pFont(10, .semibold))
                            .foregroundStyle(item.kind.textAccent)
                        Text(Self.bounded(Self.transformed(ocr, item: item, transforms: transforms)))
                            .font(pFont(12))
                            .lineLimit(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        case .file:
            FileList(paths: item.fileURLs ?? [], limit: 12, iconSize: 20, fontSize: 12, icon: icon)
        }
    }

    private var displayText: String {
        Self.bounded(Self.transformed(item.text ?? "", item: item, transforms: transforms))
    }

    /// Memoised, and run over the *whole* clip. Transforming only the head used to give the peek
    /// different paragraph breaks than the paste, because Reflow's thresholds come from the text it
    /// is handed — so the preview wasn't what would land. Main thread only.
    private static var cache: (key: String, value: String)?

    static func transformed(_ text: String, item: ClipItem, transforms: [Transform]) -> String {
        guard !transforms.isEmpty else { return text }
        let key = "\(item.id)|\(text.count)|\(transforms.map(\.label).joined(separator: ","))"
        if let cache, cache.key == key { return cache.value }
        let out = Transform.apply(transforms, to: text, kind: item.kind)
        cache = (key, out)
        return out
    }

    /// Peek shows at most 16 lines anyway; never hand SwiftUI more than a screenful to lay out.
    static func bounded(_ text: String) -> String {
        let head = text.truncatedToUTF8(32_000)
        let lines = head.lines.prefix(24)
        let joined = lines.joined(separator: "\n")
        return joined.count > 4000 ? String(joined.prefix(4000)) + "…" : joined
    }
}

// MARK: - Shared bits

struct FileList: View {
    let paths: [String]
    var limit: Int = 4
    var iconSize: CGFloat = 14
    var fontSize: CGFloat = 11
    let icon: (String) -> NSImage

    var body: some View {
        VStack(alignment: .leading, spacing: 3 * SwitcherView.scale) {
            ForEach(Array(paths.prefix(limit)), id: \.self) { path in
                HStack(spacing: 5 * SwitcherView.scale) {
                    Image(nsImage: icon(path))
                        .resizable()
                        .frame(width: iconSize * SwitcherView.scale, height: iconSize * SwitcherView.scale)
                    Text((path as NSString).lastPathComponent)
                        .font(pFont(fontSize))
                        .lineLimit(1)
                }
            }
            if paths.count > limit {
                Text("+\(paths.count - limit) more")
                    .font(pFont(10)).foregroundStyle(.secondary)
            }
        }
    }
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.hasPrefix("#") ? String(s.dropFirst()) : s
        if s.count == 3 || s.count == 4 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: Double
        if s.count == 8 {
            r = Double((v >> 24) & 0xFF) / 255; g = Double((v >> 16) & 0xFF) / 255
            b = Double((v >> 8) & 0xFF) / 255;  a = Double(v & 0xFF) / 255
        } else {
            r = Double((v >> 16) & 0xFF) / 255; g = Double((v >> 8) & 0xFF) / 255
            b = Double(v & 0xFF) / 255;         a = 1
        }
        self.init(red: r, green: g, blue: b, opacity: a)
    }
}
