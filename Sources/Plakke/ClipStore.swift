import AppKit
import Combine

/// Recent clips (a ring of `capacity`) followed by pinned clips (kept forever).
/// `items` is always in display order: newest recent first, then pinned in pin order.
///
/// Every mutator runs on the main thread and publishes `items` exactly once, as a whole new array.
/// The old two-step `remove` + `insert` pattern published an intermediate state that the switcher
/// reacted to, which silently moved the highlight onto a neighbouring clip.
final class ClipStore: ObservableObject {
    @Published private(set) var items: [ClipItem] = []
    /// Bumped when a thumbnail or full-size image finishes loading, so the strip can redraw.
    @Published private(set) var imageVersion = 0
    let capacity: Int

    private let dir: URL
    private let io = DispatchQueue(label: "app.plakke.store.io", qos: .utility)
    private var expiryTimer: Timer?
    private var housekeeping: Timer?

    private var thumbs: [UUID: NSImage] = [:]
    private var fulls: [UUID: NSImage] = [:]
    private var thumbOrder: [UUID] = []
    private var fullOrder: [UUID] = []
    private var loadingThumb: Set<UUID> = []
    private var loadingFull: Set<UUID> = []
    private var ocrTasks: [UUID: OCRTask] = [:]
    private var pixelSizes: [UUID: CGSize] = [:]
    /// Ids whose images have been reclaimed; an in-flight decode for one must not repopulate a cache.
    private var forgotten: Set<UUID> = []

    private var saveWork: DispatchWorkItem?
    private var firstPendingSave: Date?
    private var settingsObserver: NSObjectProtocol?

    /// Removals ⌘Z can still take back, oldest first. Their image files are deliberately *not*
    /// deleted yet, which is the whole reason this is separate from `remove`.
    private var trash: [(item: ClipItem, index: Int)] = []

    /// Card images are drawn at 172×136pt; keeping full-resolution screenshots in memory for that
    /// cost hundreds of megabytes.
    private static let thumbMaxPixel: CGFloat = 400
    private static let thumbCacheLimit = 40
    private static let fullCacheLimit = 4
    private static let saveDebounce: TimeInterval = 0.3
    /// However busy the clipboard is, never go longer than this without a durable write.
    private static let saveCeiling: TimeInterval = 2.0

    /// `directory` is only passed by tests; the app always uses Application Support.
    init(capacity: Int, directory: URL? = nil) {
        self.capacity = capacity
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        dir = directory ?? base.appendingPathComponent("Plakke", isDirectory: true)
        do {
            // 0700 on the directory, so the window between an atomic write and the chmod that follows
            // it can't expose the history to other local users.
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            NSLog("Plakke: could not create \(dir.path): \(error) — history will not persist")
        }
        load()
        // The store reacts to the settings it cares about, instead of the menu having to remember to
        // call it after every toggle.
        settingsObserver = NotificationCenter.default.addObserver(
            forName: Settings.changed, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let key = note.object as? String
            if key == nil || key == Settings.autoForget.key { self.forgetStaleClips() }
            if key == nil || key == Settings.rememberSecrets.key,
               !Settings.rememberSecrets.value { self.purgeSecrets() }
        }
        forgetStaleClips()      // anything already past its age when we launched
        // One slow timer: reads the setting each minute rather than needing to be told it changed.
        housekeeping = Timer.plakkeRepeating(60) { [weak self] in self?.forgetStaleClips() }
    }

    deinit {
        housekeeping?.invalidate()
        expiryTimer?.invalidate()
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
    }

    var recents: [ClipItem] { items.filter { !$0.pinned } }
    var pinned: [ClipItem]  { items.filter { $0.pinned } }

    // MARK: mutation

    func push(_ item: ClipItem) {
        assert(Thread.isMainThread)
        var next = items

        // Dedupe against every recent, not just the top one, and treat the re-copy as fresh: the
        // clip moves to the front, its timestamp updates, and a secret's countdown restarts.
        // A re-copy supersedes the same clip sitting in the undo trash; otherwise ⌘Z later restores
        // a twin that `push`'s dedupe can never collapse, and both keep a slot forever.
        trash.removeAll { entry in
            guard entry.item.isSameContent(as: item) else { return false }
            forget(entry.item)
            return true
        }

        if let i = next.firstIndex(where: { !$0.pinned && $0.isSameContent(as: item) }) {
            var existing = next.remove(at: i)
            existing.date = item.date
            if item.isSecret { existing.expiresAt = item.expiresAt }
            next.insert(existing, at: 0)
            commit(next)
            deleteFile(item.imageFile)        // the duplicate PNG we just wrote
            if existing.isSecret { startExpiryTimer() }
            return
        }

        next.insert(item, at: 0)
        let evicted = trimRecents(&next)
        commit(next, forgetting: evicted)
        if item.isSecret { startExpiryTimer() }
        scheduleOCRIfNeeded(item)
    }

    /// The source app wiped the pasteboard (KeePassXC-style auto-clear): honour it immediately.
    /// Looks at every secret, not just the newest clip — one ordinary copy in between used to be
    /// enough for the secret to survive its full lifetime.
    func dropNewestSecret() {
        assert(Thread.isMainThread)
        guard let victim = items.first(where: \.isSecret) else { return }
        remove(victim.id)
    }

    /// Drops unpinned clips older than the "Forget Clips After" setting. Pins are exempt — they were
    /// kept on purpose.
    func forgetStaleClips() {
        assert(Thread.isMainThread)
        let hours = Settings.autoForget.value
        guard hours > 0 else { return }
        purgeTrash()            // undo must not resurrect what age just removed
        let cutoff = Date().addingTimeInterval(-Double(hours) * 3600)
        let stale = items.filter { !$0.pinned && !$0.isSecret && $0.date < cutoff }
        guard !stale.isEmpty else { return }
        let ids = Set(stale.map(\.id))
        commit(items.filter { !ids.contains($0.id) }, forgetting: stale)
    }

    /// Used when an app is added to the ignore list: forget what it already put here. Pinned clips
    /// stay, since pinning one was a deliberate act.
    func purge(sourceBundleID: String) {
        assert(Thread.isMainThread)
        purgeTrash()            // undo must not resurrect what the user just asked to be forgotten
        let key = sourceBundleID.lowercased()
        let doomed = items.filter { !$0.pinned && $0.sourceBundleID?.lowercased() == key }
        guard !doomed.isEmpty else { return }
        let ids = Set(doomed.map(\.id))
        commit(items.filter { !ids.contains($0.id) }, forgetting: doomed)
    }

    /// Turning "Remember Secrets" off should also forget the secret already in the strip.
    func purgeSecrets() {
        assert(Thread.isMainThread)
        purgeTrash()            // undo must not resurrect what the user just asked to be forgotten
        let doomed = items.filter(\.isSecret)
        guard !doomed.isEmpty else { return }
        commit(items.filter { !$0.isSecret }, forgetting: doomed)
    }

    private func startExpiryTimer() {
        guard expiryTimer == nil else { return }
        expiryTimer = Timer.plakkeRepeating(1) { [weak self] in
            guard let self else { return }
            let now = Date()
            let expired = self.items.filter { ($0.expiresAt ?? .distantFuture) <= now }
            if !expired.isEmpty {
                let ids = Set(expired.map(\.id))
                self.commit(self.items.filter { !ids.contains($0.id) }, forgetting: expired)
            }
            if !self.items.contains(where: \.isSecret) {
                self.expiryTimer?.invalidate()
                self.expiryTimer = nil
            }
        }
    }

    func promote(_ id: UUID) {
        assert(Thread.isMainThread)
        guard let i = items.firstIndex(where: { $0.id == id }), i > 0, !items[i].pinned else { return }
        var next = items
        let it = next.remove(at: i)
        next.insert(it, at: 0)
        commit(next)
    }

    func togglePin(_ id: UUID) {
        assert(Thread.isMainThread)
        guard let i = items.firstIndex(where: { $0.id == id }), !items[i].isSecret else { return }   // secrets can't be pinned
        var next = items
        var it = next.remove(at: i)
        it.pinned.toggle()
        var evicted: [ClipItem] = []
        if it.pinned {
            next.append(it)                          // pinned live at the end, in pin order
        } else {
            next.insert(it, at: 0)                   // unpinning makes it the freshest recent
            evicted = trimRecents(&next)
        }
        commit(next, forgetting: evicted)
    }

    func attachOCR(_ text: String, to id: UUID) {
        assert(Thread.isMainThread)
        // Unregister first: a clip removed with ⌫ keeps its task (deliberately, so undo can restore
        // it), and leaving the entry behind both retains the Vision request and blocks any later
        // `scheduleOCRIfNeeded` for that id.
        defer { ocrTasks[id] = nil }
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        var next = items
        next[i].ocrText = text
        next[i].ocrPreview = ClipItem.makePreview(text)
        commit(next)
    }

    var canUndoRemove: Bool { !trash.isEmpty }

    /// ⌫ in the switcher. Keeps the clip (and its PNG) aside so `undoRemove` can put it back.
    func removeRecoverable(_ id: UUID) {
        assert(Thread.isMainThread)
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        var next = items
        let gone = next.remove(at: i)
        trash.append((gone, i))
        items = next          // not `commit`: nothing may be forgotten while undo can still restore it
        save()
    }

    @discardableResult
    func undoRemove() -> ClipItem? {
        assert(Thread.isMainThread)
        guard let (item, index) = trash.popLast() else { return nil }
        var next = items
        // The stored index is only a hint: anything could have landed, been evicted or been pinned
        // since. Reinserting at it blindly could drop a pinned clip in among the recents, which breaks
        // the ordering invariant, draws two dividers, overflows the strip, and makes the next eviction
        // delete a *newer* recent than the oldest.
        let recentCount = next.prefix { !$0.pinned }.count
        let insertAt = item.pinned ? next.count : min(max(0, index), recentCount)
        next.insert(item, at: insertAt)
        let evicted = trimRecents(&next)
        commit(next, forgetting: evicted)
        scheduleOCRIfNeeded(item)        // its recognition may have been cancelled, or never finished
        return item
    }

    /// Ends the undo window — anything still held aside can have its image reclaimed now.
    func purgeTrash() {
        assert(Thread.isMainThread)
        let doomed = trash.map(\.item)
        trash.removeAll()
        doomed.forEach(forget)
    }

    func remove(_ id: UUID) {
        assert(Thread.isMainThread)
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        var next = items
        let gone = next.remove(at: i)
        commit(next, forgetting: [gone])
    }

    /// Clears recents; pinned clips survive.
    func clear() {
        assert(Thread.isMainThread)
        purgeTrash()            // undo must not resurrect what the user just asked to be forgotten
        let doomed = items.filter { !$0.pinned }
        guard !doomed.isEmpty else { return }
        commit(items.filter(\.pinned), forgetting: doomed)
    }

    /// Drops the oldest recents past `capacity` and returns them, so their images can be reclaimed.
    private func trimRecents(_ list: inout [ClipItem]) -> [ClipItem] {
        var evicted: [ClipItem] = []
        while list.filter({ !$0.pinned }).count > capacity,
              let last = list.lastIndex(where: { !$0.pinned }) {
            evicted.append(list.remove(at: last))
        }
        return evicted
    }

    /// One publish, then clean up what left the list, then persist.
    private func commit(_ next: [ClipItem], forgetting gone: [ClipItem] = []) {
        items = next
        gone.forEach(forget)
        save()
    }

    private func forget(_ item: ClipItem) {
        ocrTasks.removeValue(forKey: item.id)?.cancel()
        thumbs[item.id] = nil
        fulls[item.id] = nil
        thumbOrder.removeAll { $0 == item.id }
        fullOrder.removeAll { $0 == item.id }
        pixelSizes[item.id] = nil
        // A load already in flight would otherwise re-insert a cache entry for a clip that is gone.
        loadingThumb.remove(item.id)
        loadingFull.remove(item.id)
        forgotten.insert(item.id)
        deleteFile(item.imageFile)
    }

    // MARK: images

    /// Safe to call from any thread — writes a new, uniquely named file.
    func saveImage(_ png: Data) -> String? {
        let name = UUID().uuidString + ".png"
        let url = dir.appendingPathComponent(name)
        do {
            try png.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            // `history.json` was excluded from backups but the screenshots beside it were not.
            var u = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? u.setResourceValues(values)
            return name
        } catch {
            return nil
        }
    }

    /// Synchronous read, used at paste time only (one read, off the render path).
    func imageData(for item: ClipItem) -> Data? {
        guard let f = item.imageFile else { return nil }
        return try? Data(contentsOf: dir.appendingPathComponent(f))
    }

    /// Full-resolution image with any EXIF orientation already applied.
    ///
    /// The preview and the edge scan go through ImageIO's thumbnail path, which honours orientation;
    /// `Paster` used to crop the raw `CGImageSourceCreateImageAtIndex` result, which does not. For a
    /// 90°-rotated source the axes are transposed, so the framed rectangle came from an unrelated
    /// region of the picture.
    func orientedImage(for item: ClipItem) -> CGImage? {
        guard let f = item.imageFile,
              let src = CGImageSourceCreateWithURL(dir.appendingPathComponent(f) as CFURL, nil)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 20000,   // effectively "full size, but transformed"
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }

    /// Downscaled card image. Returns nil until the load finishes, then bumps `imageVersion`.
    func thumbnail(for item: ClipItem) -> NSImage? {
        assert(Thread.isMainThread)
        if let t = thumbs[item.id] { return t }
        guard let f = item.imageFile, !loadingThumb.contains(item.id) else { return nil }
        loadingThumb.insert(item.id)
        let url = dir.appendingPathComponent(f)
        let limit = Self.thumbMaxPixel
        io.async { [weak self] in
            let image = Self.loadImage(at: url, maxPixel: limit)
            DispatchQueue.main.async {
                guard let self else { return }
                self.loadingThumb.remove(item.id)
                guard let image, !self.forgotten.contains(item.id) else { return }
                self.thumbs[item.id] = image
                self.thumbOrder.append(item.id)
                self.trimCache(&self.thumbs, &self.thumbOrder, limit: Self.thumbCacheLimit)
                self.imageVersion += 1
            }
        }
        return nil
    }

    /// Full-size image for peek, loaded the same way.
    func fullImage(for item: ClipItem) -> NSImage? {
        assert(Thread.isMainThread)
        if let f = fulls[item.id] { return f }
        guard let f = item.imageFile, !loadingFull.contains(item.id) else { return thumbs[item.id] }
        loadingFull.insert(item.id)
        let url = dir.appendingPathComponent(f)
        io.async { [weak self] in
            let image = Self.loadImage(at: url, maxPixel: 1600)
            DispatchQueue.main.async {
                guard let self else { return }
                self.loadingFull.remove(item.id)
                guard let image, !self.forgotten.contains(item.id) else { return }
                self.fulls[item.id] = image
                self.fullOrder.append(item.id)
                self.trimCache(&self.fulls, &self.fullOrder, limit: Self.fullCacheLimit)
                self.imageVersion += 1
            }
        }
        return thumbs[item.id]
    }

    /// A decoded image for one-off analysis, synchronously. The async caches are for drawing; crop
    /// entry can't use them, because on a cold clip they return nil and the edge scan would silently
    /// get nothing to look at. One bounded decode at an explicit keypress is fine.
    func imageForAnalysis(for item: ClipItem) -> CGImage? {
        assert(Thread.isMainThread)
        // Deliberately not `thumbs`: that one is 400px, and the common path into crop mode is pressing
        // X on a card that was just drawn, so reusing it quantised the detected rectangle to 1/400 of
        // the original — about 13px per edge on a 4K screenshot — and made the result depend on whether
        // the user had peeked first.
        if let cached = fulls[item.id],
           let cg = cached.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return cg
        }
        guard let f = item.imageFile else { return nil }
        return Self.loadImage(at: dir.appendingPathComponent(f), maxPixel: 1400)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// True pixel dimensions, read from the file's metadata — no decode, so it's fine to ask for
    /// this on every frame while the crop readout is on screen.
    func pixelSize(for item: ClipItem) -> CGSize? {
        assert(Thread.isMainThread)
        if let cached = pixelSizes[item.id] { return cached.width > 0 ? cached : nil }
        guard let f = item.imageFile,
              let src = CGImageSourceCreateWithURL(dir.appendingPathComponent(f) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              var w = props[kCGImagePropertyPixelWidth] as? Int,
              var h = props[kCGImagePropertyPixelHeight] as? Int else {
            // Remember the failure, or the crop readout re-reads an unreadable file every drag frame.
            pixelSizes[item.id] = .zero
            return nil
        }
        // Orientations 5-8 are the rotated ones; the stored dimensions are pre-rotation, while
        // everything that draws or crops the image sees it rotated.
        if let orientation = props[kCGImagePropertyOrientation] as? Int, orientation >= 5 {
            swap(&w, &h)
        }
        let size = CGSize(width: w, height: h)
        pixelSizes[item.id] = size
        return size
    }

    private func trimCache(_ cache: inout [UUID: NSImage], _ order: inout [UUID], limit: Int) {
        while order.count > limit {
            let oldest = order.removeFirst()
            cache[oldest] = nil
        }
    }

    /// Decodes at a bounded size using ImageIO, so a 4K screenshot never becomes a 4K NSImage.
    private static func loadImage(at url: URL, maxPixel: CGFloat) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private func deleteFile(_ name: String?) {
        guard let name else { return }
        let url = dir.appendingPathComponent(name)
        // On the io queue, so a delete can never overtake the history write that still mentions it.
        io.async { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: OCR

    /// Runs OCR for an image clip that doesn't have text yet — including clips restored from disk,
    /// which previously lost their OCR forever if the app quit before recognition finished.
    func scheduleOCRIfNeeded(_ item: ClipItem) {
        assert(Thread.isMainThread)
        guard item.kind == .image, item.ocrText == nil, item.imageFile != nil,
              ocrTasks[item.id] == nil else { return }
        let id = item.id
        io.async { [weak self] in
            guard let data = self?.imageData(for: item) else { return }
            DispatchQueue.main.async {
                guard let self, self.items.contains(where: { $0.id == id }) else { return }
                self.ocrTasks[id] = OCR.recognize(data) { [weak self] text in
                    guard let self else { return }
                    guard let text else { self.ocrTasks[id] = nil; return }
                    // Recognised text is persisted alongside the clip, so a screenshot of a token
                    // would have put that token in history.json as searchable plaintext — with no
                    // expiry and pinnable — while the same characters typed into a text clip are
                    // treated as a secret. Don't keep it.
                    guard !Sensitive.looksSensitive(text) else {
                        NSLog("Plakke: recognised text looks like a credential — not stored")
                        self.ocrTasks[id] = nil
                        return
                    }
                    self.attachOCR(text, to: id)
                }
            }
        }
    }

    // MARK: persistence

    private var historyURL: URL { dir.appendingPathComponent("history.json") }

    /// Coalesced: a burst of copies used to re-encode and rewrite the whole history once per
    /// mutation, which for rich-text clips meant several megabytes each time.
    private func save() {
        // Coalesced, but with a ceiling: copies arriving faster than the debounce window kept
        // cancelling the only durable write, so a long burst could postpone it indefinitely.
        if let first = firstPendingSave, Date().timeIntervalSince(first) >= Self.saveCeiling {
            saveWork?.cancel()
            saveWork = nil
            writeNow()
            return
        }
        if firstPendingSave == nil { firstPendingSave = Date() }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.writeNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDebounce, execute: work)
    }

    private func writeNow() {
        firstPendingSave = nil
        let snapshot = items.filter { !$0.isSecret }       // secrets never touch the disk
        let url = historyURL
        io.async { Self.write(snapshot, to: url) }
    }

    /// Drains every pending write synchronously. Called at terminate — without it, Clear History
    /// followed by a quick Quit left the "cleared" clips on disk.
    func flush() {
        assert(Thread.isMainThread)
        saveWork?.cancel()
        saveWork = nil
        firstPendingSave = nil
        let snapshot = items.filter { !$0.isSecret }
        let url = historyURL
        io.sync { Self.write(snapshot, to: url) }
    }

    private static func write(_ items: [ClipItem], to url: URL) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Plakke: could not write history: \(error)")
            return
        }
        // The atomic write replaces the file, so these have to be reapplied every time. This file
        // holds everything the user has copied: keep it owner-only and out of backups.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
    }

    private func load() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: historyURL.path) else {
            // No history at all: anything left in the directory really is an orphan.
            sweepOrphanImages()
            return
        }
        guard let data = try? Data(contentsOf: historyURL) else {
            // The file is THERE but unreadable — a permissions problem, a bad restore, a transient I/O
            // error. Sweeping now would treat every PNG it describes as unreferenced and delete the
            // lot, pinned screenshots included, for a condition that may well be temporary.
            NSLog("Plakke: history.json exists but could not be read — leaving images alone")
            return
        }

        // Per-element decoding: one unreadable entry (a `kind` from a newer build, a truncated
        // file) used to discard the entire history — pins included — which the next push then
        // overwrote for good.
        struct Tolerant: Decodable {
            let value: ClipItem?
            init(from decoder: Decoder) throws { value = try? ClipItem(from: decoder) }
        }
        guard let rows = try? JSONDecoder().decode([Tolerant].self, from: data) else {
            // Same reasoning: a shape we don't understand (a newer build, a hand edit) is not licence
            // to delete the images that file refers to.
            NSLog("Plakke: history.json is not a clip array — leaving it and the images alone")
            return
        }
        let decoded = rows.compactMap(\.value)
        if decoded.count != rows.count {
            NSLog("Plakke: skipped \(rows.count - decoded.count) unreadable clip(s)")
        }

        // An image clip whose PNG is gone would clear the pasteboard and paste nothing, so drop it.
        let usable = decoded.filter { item in
            guard item.kind == .image else { return true }
            // An image row with no file name can never be drawn or pasted — it just occupies a slot.
            guard let f = item.imageFile else { return false }
            return fm.fileExists(atPath: dir.appendingPathComponent(f).path)
        }

        // Normalise order in case the file was hand-edited or written by an older build.
        items = Array(usable.filter { !$0.pinned }.prefix(capacity)) + usable.filter(\.pinned)
        if usable.count != decoded.count { writeNow() }

        sweepOrphanImages()
        items.forEach(scheduleOCRIfNeeded)
    }

    /// Deletes PNGs no clip references any more — evictions past `capacity` at load time, and
    /// anything orphaned by a crash, used to accumulate forever.
    private func sweepOrphanImages() {
        let referenced = Set(items.compactMap(\.imageFile))
        let directory = dir
        // `referenced` is a snapshot, and the watcher starts polling right after launch — so only
        // consider files that already existed when the snapshot was taken. A PNG written by a capture
        // that lands mid-sweep is newer than this cutoff and is left alone.
        let cutoff = Date()
        io.async {
            let fm = FileManager.default
            guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
            for name in names where name.hasSuffix(".png") && !referenced.contains(name) {
                let url = directory.appendingPathComponent(name)
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                guard let created, created <= cutoff else { continue }
                try? fm.removeItem(at: url)
            }
        }
    }
}
