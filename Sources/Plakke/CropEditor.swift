import AppKit
import SwiftUI

/// The crop surface inside peek. AppKit rather than SwiftUI gestures on purpose: the panel is a
/// non-activating, never-key `NSPanel`, where `DragGesture`, hover and cursor rects are all
/// unreliable. An `NSView` that handles its own mouse has no such doubts.
struct CropEditor: NSViewRepresentable {
    let image: NSImage
    let crop: ImageCrop
    /// Real pixel dimensions of the source, for the readout.
    let fullSize: CGSize
    let onChange: (ImageCrop) -> Void

    func makeNSView(context: Context) -> CropEditorView {
        let view = CropEditorView()
        view.onChange = onChange
        view.configure(image: image, crop: crop, fullSize: fullSize)
        return view
    }

    func updateNSView(_ view: CropEditorView, context: Context) {
        view.onChange = onChange
        view.configure(image: image, crop: crop, fullSize: fullSize)
    }
}

final class CropEditorView: NSView {
    var onChange: ((ImageCrop) -> Void)?

    private var image: NSImage?
    private var crop = ImageCrop.full
    private var fullSize = CGSize(width: 1, height: 1)
    private var drag: Drag?
    private var hoverHandle: Handle?

    /// Top-left origin, so view coordinates and the crop's unit rect share a convention.
    override var isFlipped: Bool { true }

    /// Room under the image for the pixel readout.
    private let footer: CGFloat = 26
    private let grab: CGFloat = 12

    func configure(image: NSImage, crop: ImageCrop, fullSize: CGSize) {
        self.image = image
        self.crop = crop
        self.fullSize = fullSize
        needsDisplay = true
    }

    // MARK: geometry

    /// The image, aspect-fitted into the area above the footer.
    private var displayRect: CGRect {
        guard let image, image.size.width > 0, image.size.height > 0 else { return .zero }
        let area = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - footer))
            .insetBy(dx: 4, dy: 4)
        guard area.width > 0, area.height > 0 else { return .zero }
        let scale = min(area.width / image.size.width, area.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    private var cropRect: CGRect {
        let d = displayRect
        return CGRect(x: d.minX + crop.rect.minX * d.width,
                      y: d.minY + crop.rect.minY * d.height,
                      width: crop.rect.width * d.width,
                      height: crop.rect.height * d.height)
    }

    private func unitPoint(_ p: CGPoint) -> CGPoint {
        let d = displayRect
        guard d.width > 0, d.height > 0 else { return .zero }
        return CGPoint(x: min(max(0, (p.x - d.minX) / d.width), 1),
                       y: min(max(0, (p.y - d.minY) / d.height), 1))
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let image, displayRect.width > 0 else { return }
        let d = displayRect
        let c = cropRect

        // `respectFlipped` is not optional here: this view is flipped so that its coordinates share
        // the crop rect's top-left origin, and the plain `draw(in:)` ignores that and renders the
        // image upside down — the selection then frames the opposite end of the picture from the one
        // it appears to.
        image.draw(in: d, from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: nil)

        // Everything outside the selection dims, using one even-odd path so the corners are exact.
        let mask = NSBezierPath(rect: d)
        mask.append(NSBezierPath(rect: c))
        mask.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.55).setFill()
        mask.fill()

        // Rule-of-thirds guides — the conventional cue that you're framing, not just selecting.
        NSColor.white.withAlphaComponent(0.25).setStroke()
        let guides = NSBezierPath()
        guides.lineWidth = 0.5
        for i in 1...2 {
            let x = c.minX + c.width * CGFloat(i) / 3
            let y = c.minY + c.height * CGFloat(i) / 3
            guides.move(to: CGPoint(x: x, y: c.minY)); guides.line(to: CGPoint(x: x, y: c.maxY))
            guides.move(to: CGPoint(x: c.minX, y: y)); guides.line(to: CGPoint(x: c.maxX, y: y))
        }
        guides.stroke()

        // A dark hairline under a white one, so the frame reads on light and dark images alike.
        NSColor.black.withAlphaComponent(0.45).setStroke()
        let outer = NSBezierPath(rect: c.insetBy(dx: -0.5, dy: -0.5))
        outer.lineWidth = 1
        outer.stroke()
        NSColor.white.setStroke()
        let frame = NSBezierPath(rect: c)
        frame.lineWidth = 1
        frame.stroke()

        drawHandles(in: c)
        drawReadout()
    }

    /// L-shaped corner marks and short edge bars, the way Preview and Photos do it — lighter than
    /// eight filled squares.
    private func drawHandles(in c: CGRect) {
        let arm = min(22, min(c.width, c.height) / 3)
        guard arm > 2 else { return }
        NSColor.white.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 3
        path.lineCapStyle = .round

        func corner(_ p: CGPoint, _ dx: CGFloat, _ dy: CGFloat) {
            path.move(to: CGPoint(x: p.x + dx * arm, y: p.y))
            path.line(to: p)
            path.line(to: CGPoint(x: p.x, y: p.y + dy * arm))
        }
        corner(CGPoint(x: c.minX, y: c.minY), 1, 1)
        corner(CGPoint(x: c.maxX, y: c.minY), -1, 1)
        corner(CGPoint(x: c.minX, y: c.maxY), 1, -1)
        corner(CGPoint(x: c.maxX, y: c.maxY), -1, -1)

        let bar = min(18, min(c.width, c.height) / 4)
        if bar > 2 {
            path.move(to: CGPoint(x: c.midX - bar / 2, y: c.minY))
            path.line(to: CGPoint(x: c.midX + bar / 2, y: c.minY))
            path.move(to: CGPoint(x: c.midX - bar / 2, y: c.maxY))
            path.line(to: CGPoint(x: c.midX + bar / 2, y: c.maxY))
            path.move(to: CGPoint(x: c.minX, y: c.midY - bar / 2))
            path.line(to: CGPoint(x: c.minX, y: c.midY + bar / 2))
            path.move(to: CGPoint(x: c.maxX, y: c.midY - bar / 2))
            path.line(to: CGPoint(x: c.maxX, y: c.midY + bar / 2))
        }

        NSColor.black.withAlphaComponent(0.35).setStroke()
        let shadow = path.copy() as! NSBezierPath
        shadow.lineWidth = 5
        shadow.stroke()
        NSColor.white.setStroke()
        path.stroke()
    }

    /// Output dimensions in real pixels — the number that actually tells you whether the crop is
    /// right, which a fraction never does.
    private func drawReadout() {
        let (w, h) = crop.pixelSize(in: fullSize)
        let text = "\(w) × \(h) px"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let size = s.size()
        s.draw(at: CGPoint(x: bounds.midX - size.width / 2,
                           y: bounds.height - footer + (footer - size.height) / 2))
    }

    // MARK: mouse

    private enum Handle {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    private enum Drag {
        case handle(Handle)
        /// A possible new rectangle. Nothing is applied until the pointer has actually moved — a plain
        /// click used to replace the detected crop with a 2%×2% sliver, which on a small rect was then
        /// impossible to drag back out of.
        case fresh(anchor: CGPoint, started: Bool)
    }

    /// How far the pointer must move before a click becomes a new rectangle.
    private let dragThreshold: CGFloat = 3

    /// The panel is never the key window, so without this the first click would be swallowed.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var mouseDownPoint: CGPoint = .zero

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        mouseDownPoint = p
        if let h = handle(at: p) {
            drag = .handle(h)
        } else {
            drag = .fresh(anchor: unitPoint(p), started: false)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let unit = unitPoint(p)
        switch drag {
        case let .handle(h):
            apply(move(h, to: unit))
        case let .fresh(anchor, started):
            let moved = hypot(p.x - mouseDownPoint.x, p.y - mouseDownPoint.y)
            guard started || moved >= dragThreshold else { return }
            drag = .fresh(anchor: anchor, started: true)
            apply(CGRect(x: min(anchor.x, unit.x), y: min(anchor.y, unit.y),
                         width: abs(unit.x - anchor.x), height: abs(unit.y - anchor.y)))
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let h = handle(at: p)
        if h != nil || hoverHandle != nil { cursor(for: h).set() }
        hoverHandle = h
    }

    override func mouseEntered(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    /// Leaving crop mode removes the view with the pointer still inside it, so no `mouseExited` ever
    /// arrives and the crosshair would persist over whatever is underneath.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { NSCursor.arrow.set() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                      options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
                                      owner: self, userInfo: nil))
    }

    private func cursor(for handle: Handle?) -> NSCursor {
        switch handle {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        case .none: return .crosshair
        default: return .crosshair          // macOS exposes no public diagonal resize cursor
        }
    }

    /// Picks the *nearest* edge on each axis rather than preferring left/top.
    ///
    /// With a fixed preference order, a rectangle narrower than twice the grab margin had every point
    /// satisfying both edge tests — so only the left/top handles were ever returned, none of which can
    /// grow the rectangle, and the crop was wedged at its minimum size with no way out.
    private func handle(at p: CGPoint) -> Handle? {
        let c = cropRect
        guard c.insetBy(dx: -grab, dy: -grab).contains(p) else { return nil }

        let dLeft = abs(p.x - c.minX), dRight = abs(p.x - c.maxX)
        let dTop = abs(p.y - c.minY), dBottom = abs(p.y - c.maxY)
        let horizontal: Handle? = min(dLeft, dRight) <= grab ? (dLeft <= dRight ? .left : .right) : nil
        let vertical: Handle? = min(dTop, dBottom) <= grab ? (dTop <= dBottom ? .top : .bottom) : nil

        switch (horizontal, vertical) {
        case (.left, .top):     return .topLeft
        case (.right, .top):    return .topRight
        case (.left, .bottom):  return .bottomLeft
        case (.right, .bottom): return .bottomRight
        case let (h?, nil):     return h
        case let (nil, v?):     return v
        default:                return nil
        }
    }

    private func move(_ handle: Handle, to unit: CGPoint) -> CGRect {
        var r = crop.rect
        func setLeft()   { let d = r.maxX; r.origin.x = min(unit.x, d - ImageCrop.minSide); r.size.width = d - r.origin.x }
        func setRight()  { r.size.width = max(ImageCrop.minSide, unit.x - r.minX) }
        func setTop()    { let d = r.maxY; r.origin.y = min(unit.y, d - ImageCrop.minSide); r.size.height = d - r.origin.y }
        func setBottom() { r.size.height = max(ImageCrop.minSide, unit.y - r.minY) }

        switch handle {
        case .topLeft:     setLeft(); setTop()
        case .top:         setTop()
        case .topRight:    setRight(); setTop()
        case .right:       setRight()
        case .bottomRight: setRight(); setBottom()
        case .bottom:      setBottom()
        case .bottomLeft:  setLeft(); setBottom()
        case .left:        setLeft()
        }
        return r
    }

    private func apply(_ rect: CGRect) {
        let next = ImageCrop(rect: rect)
        crop = next
        needsDisplay = true
        onChange?(next)
    }
}
