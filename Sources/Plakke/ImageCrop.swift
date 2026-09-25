import AppKit
import CoreGraphics

/// A crop, held as a fraction of the image rather than in pixels, so the small preview, the big peek
/// editor and the full-resolution paste all agree on exactly the same rectangle.
struct ImageCrop: Equatable {
    /// Unit rect, origin top-left, clamped to 0...1.
    var rect: CGRect

    static let full = ImageCrop(rect: CGRect(x: 0, y: 0, width: 1, height: 1))

    /// Smallest crop we allow, as a fraction — stops a stray drag producing a 1px image.
    static let minSide: CGFloat = 0.02

    init(rect: CGRect) {
        self.rect = Self.clamp(rect)
    }

    var isFull: Bool {
        rect.minX <= 0.0005 && rect.minY <= 0.0005 && rect.maxX >= 0.9995 && rect.maxY >= 0.9995
    }

    static func clamp(_ r: CGRect) -> CGRect {
        var out = r.standardized
        out.origin.x = min(max(0, out.origin.x), 1 - minSide)
        out.origin.y = min(max(0, out.origin.y), 1 - minSide)
        out.size.width = min(max(minSide, out.size.width), 1 - out.origin.x)
        out.size.height = min(max(minSide, out.size.height), 1 - out.origin.y)
        return out
    }

    /// Pixel rect for an image of `size`, rounded once so every consumer lands on the same pixels —
    /// rounding separately per consumer is how you get a one-pixel seam of the border you just cut.
    func pixelRect(in size: CGSize) -> CGRect {
        // `cropped()` short-circuits on `isFull`, so the readout and the card have to agree with that
        // or they would promise a trim the paste silently skips.
        guard !isFull else { return CGRect(origin: .zero, size: size) }
        let w = size.width, h = size.height
        let x0 = (rect.minX * w).rounded()
        let y0 = (rect.minY * h).rounded()
        let x1 = (rect.maxX * w).rounded()
        let y1 = (rect.maxY * h).rounded()
        return CGRect(x: min(max(0, x0), w - 1),
                      y: min(max(0, y0), h - 1),
                      width: max(1, min(x1 - x0, w - x0)),
                      height: max(1, min(y1 - y0, h - y0)))
    }

    /// `CGImage.cropping(to:)` takes a rect in the image's own top-left-origin space, which is the
    /// same convention `rect` uses.
    func cropped(_ image: CGImage) -> CGImage? {
        guard !isFull else { return image }
        let size = CGSize(width: image.width, height: image.height)
        return image.cropping(to: pixelRect(in: size))
    }

    func pixelSize(in size: CGSize) -> (width: Int, height: Int) {
        let r = pixelRect(in: size)
        return (Int(r.width), Int(r.height))
    }
}
