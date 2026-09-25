import AppKit
import SwiftUI
import Combine

/// Owns the floating switcher panel and the "which clip is highlighted" state.
final class SwitcherController: ObservableObject {
    @Published private(set) var items: [ClipItem] = []
    @Published private(set) var selected: Int = 0
    @Published private(set) var isPeeking = false
    /// Armed transforms, kept in the canonical pipeline order.
    @Published private(set) var transforms: [Transform] = []
    /// Set by ↑/↓ on an image clip. The *effective* mode is `textMode`, which also accounts for an
    /// armed transform — a transform always pastes text, so the card has to show text too.
    @Published private(set) var explicitTextMode = false
    /// The slice of `items` currently drawn; slides to keep `selected` on screen.
    @Published private(set) var visibleRange: Range<Int> = 0..<0
    @Published private(set) var isActive = false
    /// Bumped when an image finishes loading, so the strip redraws.
    @Published private(set) var imageVersion = 0
    /// Set when a paste couldn't happen: the strip stays up briefly and says why, instead of just
    /// closing and silently doing nothing.
    @Published private(set) var failureMessage: String?
    /// True while the trigger key is autorepeating faster than the selection spring can settle.
    @Published private(set) var fastCycling = false
    /// Whether ⌘Z has a removal to take back (this session only).
    @Published private(set) var canUndo = false
    /// Non-nil while crop mode is open. The rectangle is fractional, so the card, the editor and the
    /// full-resolution paste all agree.
    @Published private(set) var crop: ImageCrop?
    /// True while the session is latched: the event tap has stopped treating a ⌥ release as a paste,
    /// so ⏎ and esc are the only ways out. Crop mode latches; leaving crop mode does not unlatch.
    @Published private(set) var isLatched = false

    /// Called when the switcher closes itself (⌫ emptying the strip), so the event tap can drop out
    /// of its cycling state too.
    var onSelfDismiss: (() -> Void)?
    /// Fired on every crop adjustment so the event tap can re-arm its idle timeout; mouse work produces no
    /// key events of its own.
    var onCropActivity: (() -> Void)?
    /// Fired when `toggleCropMode` could not enter crop mode, so the tap can drop its latch.
    var onCropUnavailable: (() -> Void)?

    let store: ClipStore
    private let watcher: ClipboardWatcher
    private var panel: NSPanel!
    private var hosting: NSHostingView<SwitcherView>!
    private var iconCache: [String: NSImage] = [:]
    private var fileIconCache: [String: NSImage] = [:]
    private var subs: Set<AnyCancellable> = []
    /// Guards the fade-out completion: it used to order the panel out unconditionally, which could
    /// hide a panel that a new session had just shown — leaving the switcher armed but invisible.
    private var showGeneration = 0
    private var lastStep = Date.distantPast

    var isCropping: Bool { crop != nil }

    /// Cropping needs an image with a file behind it. Secrets are excluded — they're blurred for a
    /// reason, and a crop editor would show the contents full size.
    var canEnterCropMode: Bool {
        guard let item = selectedItem else { return false }
        return item.kind == .image && !item.isSecret && item.imageFile != nil
    }

    init(store: ClipStore, watcher: ClipboardWatcher) {
        self.store = store
        self.watcher = watcher
        buildPanel()
        // Keep the strip live while it's open (e.g. OCR text arriving, a new copy landing).
        store.$items
            .sink { [weak self] new in
                guard let self, self.isActive else { return }
                let selID = self.selectedItem?.id
                self.items = new
                if let selID, let i = new.firstIndex(where: { $0.id == selID }) {
                    self.selected = i
                } else {
                    // The clip under the cursor is gone (evicted by a new copy, cleared from the menu,
                    // aged out). The index now points at a DIFFERENT clip, so anything armed against
                    // the old one has to go — a crop especially, since ⏎ would otherwise apply that
                    // rectangle to an image the user never framed.
                    self.selected = min(self.selected, max(new.count - 1, 0))
                    self.exitCropMode()
                    self.transforms = []
                    self.explicitTextMode = false
                }
                self.updateWindow()
                self.resize()
            }
            .store(in: &subs)
        store.$imageVersion
            .sink { [weak self] _ in
                guard let self, self.isActive else { return }
                self.imageVersion += 1
            }
            .store(in: &subs)
        // "Larger Cards" changes every layout constant, so a visible strip has to be re-measured.
        NotificationCenter.default.publisher(for: Settings.changed)
            .sink { [weak self] _ in
                guard let self, self.isActive else { return }
                // `maxVisible` is a function of the card width, so the visible range has to be
                // recomputed — resizing alone produced a panel wider than the screen with the leading
                // cards pushed off the left edge.
                self.updateWindow()
                self.resize()
            }
            .store(in: &subs)
    }

    var selectedItem: ClipItem? {
        items.indices.contains(selected) ? items[selected] : nil
    }

    var visibleItems: ArraySlice<ClipItem> {
        items[visibleRange.clamped(to: 0..<items.count)]     // never trust a stale window
    }

    /// What will actually land: an armed transform forces text, whatever the card was showing.
    var textMode: Bool {
        guard let item = selectedItem, item.kind == .image, item.ocrText != nil else { return false }
        return explicitTextMode || !transforms.isEmpty
    }

    // MARK: state machine (called from the event tap, on the main run loop)

    func begin() {
        items = store.items
        // Like ⌘Tab, the first tap selects the *previous* clip — the previous **recent**, since the
        // pinned section is a different list and landing there isn't what the gesture means.
        let recentCount = items.filter { !$0.pinned }.count
        selected = recentCount > 1 ? 1 : 0
        isPeeking = false
        transforms = []
        explicitTextMode = false
        visibleRange = 0..<0
        failureMessage = nil
        fastCycling = false
        lastStep = .distantPast
        crop = nil
        isLatched = false
        panel.ignoresMouseEvents = true
        canUndo = store.canUndoRemove
        isActive = true
        updateWindow()
        show()
        announceSelection(prefix: "Clipboard switcher.")
    }

    /// Drops transforms that don't apply to the newly selected clip.
    ///
    /// `C` armed on a colour and then stepped onto a styled text clip used to stay armed: the
    /// conversion returned the text unchanged, but a non-empty chain forces the plain-text payload, so
    /// the paste silently lost its formatting.
    private func pruneTransforms() {
        guard let item = selectedItem else { transforms = []; return }
        guard let text = item.plainText else { transforms = []; return }
        transforms = transforms.filter { $0.applies(to: text) }
    }

    func step(_ delta: Int) {
        guard !items.isEmpty else { return }
        // Held-down cycling arrives every ~0.14s, faster than the 0.22s selection spring can settle,
        // so the view switches to a short crossfade while that's happening.
        let now = Date()
        fastCycling = now.timeIntervalSince(lastStep) < 0.2
        lastStep = now
        selected = ((selected + delta) % items.count + items.count) % items.count
        explicitTextMode = false
        pruneTransforms()
        if crop != nil { exitCropMode() }      // the crop belonged to the clip you just left
        updateWindow()
        resize()
        announceSelection()
    }

    func select(_ index: Int) {
        guard items.indices.contains(index) else { return }
        fastCycling = false
        selected = index
        explicitTextMode = false
        pruneTransforms()
        if crop != nil { exitCropMode() }
        updateWindow()
        resize()
        announceSelection()
    }

    /// ↑/↓ on an image clip that has recognised text: flip between pasting the image and the text.
    func toggleTextMode() {
        guard let item = selectedItem, item.kind == .image, item.ocrText != nil else { return }
        explicitTextMode.toggle()
        announce(textMode ? "Will paste recognised text" : "Will paste the image")
    }

    func togglePeek() {
        guard !items.isEmpty else { return }
        isPeeking.toggle()
        resize()
        announce(isPeeking ? "Preview open" : "Preview closed")
    }

    func togglePin() {
        guard let item = selectedItem, !item.isSecret else { return }
        let willPin = !item.pinned
        store.togglePin(item.id)          // store subscription updates items/selected/window/size
        announce(willPin ? "Pinned" : "Unpinned")
    }

    func toggleTransform(_ t: Transform) {
        guard let item = selectedItem, let text = item.plainText else { return }
        // C on something that isn't a colour, J on something that isn't JSON: nothing to arm.
        guard t.applies(to: text) || transforms.contains(t) else { return }
        if let i = transforms.firstIndex(of: t) {
            transforms.remove(at: i)
        } else {
            if let c = t.conflicts { transforms.removeAll { $0 == c } }
            transforms.append(t)
            transforms = Transform.ordered(transforms)   // pills show the order they'll actually run in
        }
        resize()
        announce(transforms.isEmpty
                 ? "No transforms"
                 : "Transforms: " + transforms.map(\.label).joined(separator: ", "))
    }

    /// X. Entering runs the edge scan and starts from what it found; if it finds nothing the
    /// rectangle starts at the full image, ready to drag — refusing to open on a photo would be
    /// maddening.
    func toggleCropMode() {
        if crop != nil {
            exitCropMode()
            return
        }
        guard canEnterCropMode, let item = selectedItem else {
            onCropUnavailable?()
            return
        }
        isPeeking = true                       // you can't frame what you can't see
        explicitTextMode = false
        transforms = []                        // text transforms and a crop are mutually exclusive
        let detected = detectContentRect(for: item)
        crop = ImageCrop(rect: detected ?? CGRect(x: 0, y: 0, width: 1, height: 1))
        panel.ignoresMouseEvents = false       // only while cropping; inert the rest of the time
        resize()
        announceCrop(detected != nil ? "Crop mode, trimmed to content." : "Crop mode.")
    }

    /// Called by the event tap when the session latches or unlatches.
    func setLatched(_ value: Bool) {
        guard isLatched != value else { return }
        isLatched = value
        resize()
    }

    func exitCropMode() {
        guard crop != nil else { return }
        crop = nil
        panel.ignoresMouseEvents = true
        resize()
        announce("Full image")
    }

    /// Called by the editor on every drag step.
    func updateCrop(_ next: ImageCrop) {
        guard crop != nil else { return }
        crop = next
        onCropActivity?()
    }

    private func detectContentRect(for item: ClipItem) -> CGRect? {
        // The "too small to bother cropping" test belongs on the real image: applied to the decoded
        // copy it rejected genuinely large wide images (a 2560×384 banner decodes to 400×60).
        if let real = store.pixelSize(for: item),
           min(real.width, real.height) < CGFloat(EdgeScan.minImageEdge) { return nil }
        // Synchronous on purpose: the drawing caches fill in asynchronously, so on a clip whose
        // preview hasn't arrived yet they'd hand back nothing and the scan would find nothing.
        guard let cg = store.imageForAnalysis(for: item) else { return nil }
        return EdgeScan.contentRect(in: cg)
    }

    /// Real output dimensions, for the editor's readout.
    func cropPixelSize(for item: ClipItem) -> CGSize {
        store.pixelSize(for: item) ?? CGSize(width: 1, height: 1)
    }

    private func announceCrop(_ prefix: String) {
        guard let item = selectedItem, let crop else { return }
        let (w, h) = crop.pixelSize(in: cropPixelSize(for: item))
        announce("\(prefix) \(w) by \(h) pixels. Return to paste, escape to cancel.")
    }

    func removeSelected() {
        guard let item = selectedItem else { return }
        // A secret is removed for good; anything else can be taken back with ⌘Z while the strip is up.
        if item.isSecret {
            store.remove(item.id)
        } else {
            store.removeRecoverable(item.id)
        }
        canUndo = store.canUndoRemove
        if items.isEmpty {
            hide()
            onSelfDismiss?()
        } else {
            announce("Removed. Command Z to undo.")
        }
    }

    /// ⌘Z while the switcher is up. The undo window closes when the strip does.
    func undoRemove() {
        guard let restored = store.undoRemove() else {
            announce("Nothing to undo")
            return
        }
        canUndo = store.canUndoRemove
        if let i = items.firstIndex(where: { $0.id == restored.id }) {
            selected = i
            updateWindow()
            resize()
        }
        announce("Restored. " + describe(restored))
    }

    func commit(plain: Bool) {
        guard let item = selectedItem else {
            // The strip emptied underneath the session (Clear History, an expiry, auto-forget).
            if !items.isEmpty || !isActive { hide(); return }
            showFailure(message: "Nothing left to paste")
            return
        }
        let asText = plain || textMode
        if Paster.paste(item, plain: asText, transforms: transforms, crop: crop,
                        store: store, watcher: watcher) {
            hide()
        } else {
            showFailure(for: item)
        }
    }

    /// Keeps the panel up for a moment with an explanation. The generation check stops a late
    /// dismissal from closing a session the user has since started.
    private func showFailure(for item: ClipItem) {
        switch item.kind {
        case .image: showFailure(message: "That image could not be read")
        case .file:  showFailure(message: "Those files have moved or been deleted")
        default:     showFailure(message: "Nothing to paste from this clip")
        }
    }

    private func showFailure(message: String) {
        failureMessage = message
        // The session has already ended in the tap, so tidy the interactive state up now rather than
        // in the deferred hide: otherwise a borderless panel keeps swallowing clicks meant for the app
        // underneath for the next 1.6 seconds.
        crop = nil
        panel.ignoresMouseEvents = true
        announce(message)
        resize()
        let generation = showGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, self.showGeneration == generation else { return }
            self.failureMessage = nil
            self.hide()
        }
    }

    func cancel() {
        hide()
    }

    // MARK: VoiceOver

    /// The panel never takes focus and has no controls, so a screen reader has nothing to walk.
    /// Announcements are the only way a VoiceOver user can tell what is selected.
    private func announce(_ message: String) {
        guard NSWorkspace.shared.isVoiceOverEnabled, let panel else { return }
        NSAccessibility.post(element: panel, notification: .announcementRequested, userInfo: [
            .announcement: message,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    private func announceSelection(prefix: String? = nil) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        guard let item = selectedItem else {
            announce([prefix, "Nothing to paste yet"].compactMap { $0 }.joined(separator: " "))
            return
        }
        var parts: [String] = []
        if let prefix { parts.append(prefix) }
        parts.append(describe(item))
        parts.append("\(selected + 1) of \(items.count)")
        if item.pinned { parts.append("pinned") }
        if !transforms.isEmpty { parts.append(transforms.map(\.label).joined(separator: ", ")) }
        announce(parts.joined(separator: ", "))
    }

    /// Kind plus a short excerpt — never the contents of a secret.
    private func describe(_ item: ClipItem) -> String {
        if item.isSecret {
            let seconds = Int((item.expiresAt?.timeIntervalSinceNow ?? 0).rounded(.up))
            return "Secret from \(item.sourceBundleID ?? "an unknown app"), \(max(0, seconds)) seconds left"
        }
        let body: String
        switch item.kind {
        case .image: body = item.ocrText.map { "image with text, \($0.prefix(60))" } ?? "image"
        case .file:  body = item.title
        default:     body = String((item.preview ?? "").prefix(80))
        }
        return "\(item.kind.label), \(body)"
    }

    // MARK: helpers for the view

    /// The card image, cropped when a crop is armed on that clip — "what's showing is what pastes"
    /// has to hold at 172pt as well as in peek.
    func thumbnail(for item: ClipItem) -> NSImage? {
        let base = store.thumbnail(for: item)
        guard let crop, !crop.isFull, item.id == selectedItem?.id, let base,
              let cg = base.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let cut = crop.cropped(cg) else { return base }
        return NSImage(cgImage: cut, size: NSSize(width: cut.width, height: cut.height))
    }
    func fullImage(for item: ClipItem) -> NSImage? { store.fullImage(for: item) }

    func appIcon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = iconCache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[bundleID] = icon
        return icon
    }

    /// Cached: the file cards used to hit `NSWorkspace.icon(forFile:)` for every path on every
    /// render, and the 1 Hz clock made that once a second.
    func fileIcon(for path: String) -> NSImage {
        if let cached = fileIconCache[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        if fileIconCache.count > 200 { fileIconCache.removeAll() }
        fileIconCache[path] = icon
        return icon
    }

    // MARK: window

    /// The screen the user is working on — `NSScreen.main` follows keyboard focus, which is where
    /// the paste is going. The mouse's screen is only a fallback.
    private var screen: NSScreen? {
        NSScreen.main
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.screens.first
    }

    /// How many cards fit on the current screen with room for the edge indicators.
    private var maxVisible: Int {
        let width = (screen?.visibleFrame.width ?? 1440) - 120
        let usable = width - 2 * (SwitcherView.inset + SwitcherView.margin) - 2 * SwitcherView.edgeWidth
        return max(1, Int(usable / (SwitcherView.cardWidth + SwitcherView.spacing)))
    }

    private func updateWindow() {
        let n = items.count
        let cap = maxVisible
        if n <= cap { visibleRange = 0..<n; return }
        var start = visibleRange.lowerBound
        if selected < start { start = selected }
        if selected >= start + cap { start = selected - cap + 1 }
        start = min(max(0, start), n - cap)
        visibleRange = start..<(start + cap)
    }

    // MARK: panel

    private func buildPanel() {
        panel = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        // Above normal and full-screen windows, but not above system alerts and notifications the
        // way `.screenSaver` was.
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        hosting = NSHostingView(rootView: SwitcherView(model: self))
        panel.contentView = hosting
    }

    /// 0 when the user has asked for less motion, so the panel appears and disappears outright.
    private var fadeDuration: TimeInterval {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
    }

    private func show() {
        showGeneration += 1
        guard screen?.visibleFrame.width ?? 0 > 0 else {
            // No usable screen (display asleep, none attached): arming the tap behind an invisible
            // panel would swallow every keystroke with nothing to show for it.
            NSLog("Plakke: no screen available — not showing the switcher")
            isActive = false
            onSelfDismiss?()
            return
        }
        resize()
        guard fadeDuration > 0 else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            return
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = fadeDuration
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        guard isActive else { return }
        isActive = false
        failureMessage = nil
        crop = nil
        panel.ignoresMouseEvents = true
        // The undo window closes with the strip: the images of anything still in the trash can go.
        store.purgeTrash()
        canUndo = false
        showGeneration += 1
        let generation = showGeneration
        guard fadeDuration > 0 else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = fadeDuration * 0.85
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.showGeneration == generation else { return }   // a new session took over
            self.panel.orderOut(nil)
        })
    }

    /// The strip's bottom edge stays put; peek grows upward from it.
    private func resize() {
        guard let frame = screen?.visibleFrame, frame.width > 0 else { return }
        let layout = SwitcherView.Layout(visible: Array(visibleItems),
                                         moreLeft: visibleRange.lowerBound,
                                         moreRight: max(0, items.count - visibleRange.upperBound),
                                         transforms: transforms,
                                         hints: SwitcherView.hintSpecs(for: self),
                                         failure: failureMessage)
        let base = SwitcherView.size(layout: layout, peeking: false)
        let size = SwitcherView.size(layout: layout, peeking: isPeeking)
        let bottom = frame.midY - base.height / 2 + 40
        let origin = NSPoint(x: frame.midX - size.width / 2, y: bottom)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}
