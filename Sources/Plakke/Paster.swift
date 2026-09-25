import AppKit

enum Paster {
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Stamped on the keystrokes we synthesise, so our own event tap passes them through instead of
    /// mistaking the ⌘V for the user tapping the trigger key again.
    static let syntheticMarker: Int64 = 0x504C_4B56

    /// What a clip turns into on the pasteboard. Built *before* anything is cleared: every early
    /// return below used to leave the pasteboard wiped and then fire ⌘V into a no-op, destroying
    /// whatever the user actually had.
    private enum Payload {
        case text(String, rtf: Data?, html: Data?)
        case image(png: Data, tiff: Data?)
        case files([URL])
    }

    /// Puts `item` back on the pasteboard and sends ⌘V to the frontmost app.
    /// Returns false when there was nothing to write, so the caller can say so on screen.
    @discardableResult
    static func paste(_ item: ClipItem, plain: Bool, transforms: [Transform],
                      crop: ImageCrop? = nil,
                      store: ClipStore, watcher: ClipboardWatcher) -> Bool {
        guard place(item, plain: plain, transforms: transforms, crop: crop,
                    store: store, watcher: watcher) else {
            return false
        }
        // ⇧ is part of the plain-paste gesture itself, so waiting for it to come up just added
        // ~430 ms and then fired ⌘V with ⇧ still down — which is Paste and Match Style in many apps.
        sendCommandVWhenModifiersClear(ignoringShift: plain,
                                       deadline: Date().addingTimeInterval(0.4))
        return true
    }

    /// Writes the clip to the pasteboard without synthesising anything. Shared with the menu bar,
    /// whose own copy of this logic had drifted — it omitted the concealed re-flag entirely.
    @discardableResult
    static func place(_ item: ClipItem, plain: Bool, transforms: [Transform],
                      crop: ImageCrop? = nil,
                      store: ClipStore, watcher: ClipboardWatcher) -> Bool {
        guard let payload = payload(for: item, plain: plain, transforms: transforms,
                                    crop: crop, store: store) else {
            NSLog("Plakke: nothing to paste for \(item.kind.label) clip — leaving the pasteboard alone")
            return false
        }

        let pb = NSPasteboard.general
        pb.clearContents()
        // The return values matter: the payload-first rewrite closed the "returned early with an empty
        // pasteboard" hole but still reported success when the write itself failed, so ⌘V was fired
        // into a document with nothing to paste.
        var wrote: Bool
        switch payload {
        case let .text(text, rtf, html):
            wrote = pb.setString(text, forType: .string)
            if let rtf { wrote = pb.setData(rtf, forType: .rtf) && wrote }
            if let html { wrote = pb.setData(html, forType: .html) && wrote }
        case let .image(png, tiff):
            wrote = pb.setData(png, forType: .png)
            if let tiff { _ = pb.setData(tiff, forType: .tiff) }   // targets that only ask for TIFF
        case let .files(urls):
            wrote = pb.writeObjects(urls.map { $0 as NSURL })
        }
        guard wrote else {
            NSLog("Plakke: the pasteboard refused the \(item.kind.label) clip")
            return false
        }

        if item.isSecret {   // tell other clipboard managers to look away, as the source app did
            pb.setData(Data(), forType: concealedType)
        }
        watcher.syncChangeCount()
        store.promote(item.id)
        return true
    }

    private static func payload(for item: ClipItem, plain: Bool, transforms: [Transform],
                               crop: ImageCrop?, store: ClipStore) -> Payload? {
        // A transform (or ⇧ on an image) turns the clip into plain text.
        if !transforms.isEmpty, let out = Transform.apply(transforms, to: item), !out.isEmpty {
            return .text(out, rtf: nil, html: nil)
        }
        if plain, item.kind == .image, let ocr = item.ocrText, !ocr.isEmpty {
            return .text(ocr, rtf: nil, html: nil)
        }

        switch item.kind {
        case .image:
            // Non-empty AND decodable: a source app can advertise `public.png` with no bytes, and
            // `saveImage` will happily write the 0-byte file. Writing that cleared the real clipboard
            // and pasted nothing — the very failure the payload-first design exists to prevent.
            guard let data = store.imageData(for: item), !data.isEmpty,
                  let probe = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetStatusAtIndex(probe, 0) == .statusComplete else { return nil }
            // The crop is applied to the full-resolution original, once, here — never to the
            // stored file, which stays untouched so the clip can be pasted whole again later.
            if let crop, !crop.isFull {
                // `orientedImage` so the rectangle the user framed lands on the same pixels they saw.
                guard let full = store.orientedImage(for: item),
                      let cut = crop.cropped(full),
                      let png = NSBitmapImageRep(cgImage: cut).representation(using: .png, properties: [:])
                else { return nil }
                return .image(png: png, tiff: tiffRepresentation(of: png))
            }
            return .image(png: data, tiff: tiffRepresentation(of: data))
        case .file:
            // ⇧ on a Files clip means "the names, as text" — it used to paste the files anyway.
            if plain, let t = item.text, !t.isEmpty { return .text(t, rtf: nil, html: nil) }
            let urls = (item.fileURLs ?? []).map { URL(fileURLWithPath: $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            if urls.isEmpty {
                guard let t = item.text, !t.isEmpty else { return nil }
                return .text(t, rtf: nil, html: nil)     // moved or deleted: paste the names
            }
            return .files(urls)
        default:
            guard let t = item.text, !t.isEmpty else { return nil }
            return .text(t, rtf: plain ? nil : item.rtf, html: plain ? nil : item.html)
        }
    }

    /// Decoding a huge screenshot just to offer TIFF isn't worth it; PNG alone covers almost everything.
    private static let maxTIFFSource = 8 * 1024 * 1024

    private static func tiffRepresentation(of png: Data) -> Data? {
        guard png.count <= maxTIFFSource else { return nil }
        return NSBitmapImageRep(data: png)?.tiffRepresentation
    }

    /// The user may still be holding ⌥ on the way up. Some apps read hardware modifier state,
    /// so wait — briefly — for a clean keyboard before synthesising ⌘V.
    private static func sendCommandVWhenModifiersClear(ignoringShift: Bool, deadline: Date) {
        var watched: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]
        if !ignoringShift { watched.insert(.maskShift) }

        let live = CGEventSource.flagsState(.combinedSessionState)
        if live.intersection(watched).isEmpty || Date() > deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { sendCommandV() }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                sendCommandVWhenModifiersClear(ignoringShift: ignoringShift, deadline: deadline)
            }
        }
    }

    private static func sendCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)

        func stamp(_ e: CGEvent) {
            e.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        }

        // Paired modifier events around the keystroke. Clients that track ⌘ from modifier
        // transitions rather than per-event flags (VM and remote-desktop guests, some Java and
        // Electron apps) saw a bare "v" without these and typed the letter instead of pasting.
        //
        // All four are required together: posting a ⌘-down without its matching release would leave
        // ⌘ stuck down in the target app, turning every later keystroke into a shortcut.
        guard let modDown = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(Key.command), keyDown: true),
              let modUp = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(Key.command), keyDown: false),
              let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(Key.v), keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(Key.v), keyDown: false)
        else { return }

        // Explicit flags, so a ⇧ the user is still physically holding doesn't turn this into ⌘⇧V.
        modDown.flags = .maskCommand
        down.flags = .maskCommand
        up.flags = .maskCommand
        // The closing event announces what is *genuinely* still held, minus ⌘. Sending a bare `[]`
        // claimed every modifier had been released — so a transition-tracking client was left with the
        // ⇧ the user is still holding stuck in the up position, with no re-press ever coming.
        modUp.flags = CGEventSource.flagsState(.combinedSessionState).subtracting(.maskCommand)

        for event in [modDown, down, up, modUp] {
            stamp(event)
            event.post(tap: .cghidEventTap)
        }
    }
}
