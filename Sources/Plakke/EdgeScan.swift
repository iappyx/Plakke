import CoreGraphics
import Foundation

/// Finds the content rectangle of an image by trimming uniform or transparent borders — the opening
/// guess when you enter crop mode.
///
/// Two passes, in this order, because the most common thing people crop isn't a uniform border:
/// a macOS window screenshot comes with a soft drop *shadow*, which is a semi-transparent gradient.
/// A strict "is this row all one colour" test fails on exactly those. So transparency goes first,
/// then uniform colour within whatever is left.
enum EdgeScan {
    /// Scanning a downscaled copy is plenty: the result is a fractional rect, so it maps back to any
    /// size. Keeps a 6000px screenshot well under a millisecond.
    static let maxSampleEdge = 1024
    /// Below ~15% alpha counts as border. Covers window shadows and transparent padding.
    static let alphaThreshold = 38
    /// Per-channel slack, for JPEG artefacts and subtle gradients.
    static let colorTolerance = 6
    /// One stray antialiased pixel shouldn't stop the scan.
    static let rowMatchRatio = 0.99
    /// Never colour-trim more than this off one edge, or a near-uniform photo collapses to nothing.
    /// Applies to the colour pass only — see `contentRect`.
    static let maxTrimFraction = 0.45
    /// Smaller than this and cropping is a silly thing to offer (favicons, emoji, sprites).
    static let minImageEdge = 64
    /// A crop that barely changes anything isn't worth proposing.
    static let minAreaReduction = 0.10
    static let minResultPixels = 8
    static let sampleStride = 4

    /// Unit rect (0...1, **origin top-left**) of the content, or nil when there's nothing worth
    /// trimming. The top-left convention is asserted by the crop suite, which renders the editor and
    /// samples the result — not assumed from the buffer layout.
    static func contentRect(in image: CGImage) -> CGRect? {
        guard min(image.width, image.height) >= minImageEdge else { return nil }
        guard let raster = Raster(image: image) else { return nil }
        let full = Box(left: 0, top: 0, right: raster.width, bottom: raster.height)
        guard full.width >= minResultPixels * 2, full.height >= minResultPixels * 2 else { return nil }

        // Transparency is definitive — a transparent pixel is certainly not content — so this pass
        // gets no guard rail. A tall thin window on a transparent canvas *should* trim 80% away.
        var box = full
        trimTransparent(raster, &box)
        let afterAlpha = box

        // Colour matching is a heuristic, so the colour pass does get one. It also can't tell
        // "uniform border" from "uniform content": a white window is entirely one colour once its
        // shadow is gone, and trimming that would consume the very thing we just found — so if it
        // collapses the box, it found nothing.
        trimUniform(raster, &box)
        if box.width < minResultPixels || box.height < minResultPixels { box = afterAlpha }
        guard box.width >= minResultPixels, box.height >= minResultPixels else { return nil }

        let maxX = Int(Double(afterAlpha.width) * maxTrimFraction)
        let maxY = Int(Double(afterAlpha.height) * maxTrimFraction)
        box.left = min(box.left, afterAlpha.left + maxX)
        box.top = min(box.top, afterAlpha.top + maxY)
        box.right = max(box.right, afterAlpha.right - maxX)
        box.bottom = max(box.bottom, afterAlpha.bottom - maxY)

        let before = Double(full.width * full.height)
        let after = Double(box.width * box.height)
        guard before > 0, (before - after) / before >= minAreaReduction else { return nil }

        return CGRect(x: Double(box.left) / Double(raster.width),
                      y: Double(box.top) / Double(raster.height),
                      width: Double(box.width) / Double(raster.width),
                      height: Double(box.height) / Double(raster.height))
    }

    /// Inclusive-left, exclusive-right pixel bounds, in raster rows (row 0 is the image's top).
    private struct Box {
        var left: Int, top: Int, right: Int, bottom: Int
        var width: Int { max(0, right - left) }
        var height: Int { max(0, bottom - top) }
    }

    private static func trimTransparent(_ r: Raster, _ box: inout Box) {
        // The stride skips up to three pixels at the far end of every span, which is enough to miss a
        // hairline rule or a one-pixel caret sitting in the margin — so the last index is always
        // sampled explicitly.
        func rowIsClear(_ y: Int) -> Bool {
            var x = box.left
            while x < box.right {
                if Int(r.alpha(x, y)) > alphaThreshold { return false }
                x += sampleStride
            }
            return Int(r.alpha(box.right - 1, y)) <= alphaThreshold
        }
        func colIsClear(_ x: Int) -> Bool {
            var y = box.top
            while y < box.bottom {
                if Int(r.alpha(x, y)) > alphaThreshold { return false }
                y += sampleStride
            }
            return Int(r.alpha(x, box.bottom - 1)) <= alphaThreshold
        }
        while box.top < box.bottom, rowIsClear(box.top) { box.top += 1 }
        while box.bottom > box.top, rowIsClear(box.bottom - 1) { box.bottom -= 1 }
        while box.left < box.right, colIsClear(box.left) { box.left += 1 }
        while box.right > box.left, colIsClear(box.right - 1) { box.right -= 1 }
    }

    private static func trimUniform(_ r: Raster, _ box: inout Box) {
        guard box.width > 0, box.height > 0 else { return }
        // All four corners are tried, not just the top-left: on a rounded-corner window screenshot the
        // top-left pixel is antialiased and under the opacity threshold, which aborted the whole pass
        // and left letterboxing or a page margin inside that window untrimmed.
        let candidates = [r.pixel(box.left, box.top), r.pixel(box.right - 1, box.top),
                          r.pixel(box.left, box.bottom - 1), r.pixel(box.right - 1, box.bottom - 1)]
        guard let corner = candidates.first(where: { Int($0.a) >= 250 }) else { return }

        func matches(_ p: Pixel) -> Bool {
            Int(p.a) >= 250
                && abs(Int(p.r) - Int(corner.r)) <= colorTolerance
                && abs(Int(p.g) - Int(corner.g)) <= colorTolerance
                && abs(Int(p.b) - Int(corner.b)) <= colorTolerance
        }
        func rowIsBorder(_ y: Int) -> Bool {
            var hits = 0, total = 0
            var x = box.left
            while x < box.right {
                if matches(r.pixel(x, y)) { hits += 1 }
                total += 1
                x += sampleStride
            }
            if matches(r.pixel(box.right - 1, y)) { hits += 1 }
            total += 1
            return total > 0 && Double(hits) / Double(total) >= rowMatchRatio
        }
        func colIsBorder(_ x: Int) -> Bool {
            var hits = 0, total = 0
            var y = box.top
            while y < box.bottom {
                if matches(r.pixel(x, y)) { hits += 1 }
                total += 1
                y += sampleStride
            }
            if matches(r.pixel(x, box.bottom - 1)) { hits += 1 }
            total += 1
            return total > 0 && Double(hits) / Double(total) >= rowMatchRatio
        }
        while box.top < box.bottom, rowIsBorder(box.top) { box.top += 1 }
        while box.bottom > box.top, rowIsBorder(box.bottom - 1) { box.bottom -= 1 }
        while box.left < box.right, colIsBorder(box.left) { box.left += 1 }
        while box.right > box.left, colIsBorder(box.right - 1) { box.right -= 1 }
    }

    fileprivate struct Pixel {
        var r: UInt8, g: UInt8, b: UInt8, a: UInt8
    }

    /// The image redrawn into a known sRGB RGBA8 buffer. Sampling a `CGImage`'s own bytes would mean
    /// guessing its colour space, byte order and alpha layout; redrawing removes all of that.
    fileprivate struct Raster {
        let pixels: [UInt8]
        let width: Int
        let height: Int
        let bytesPerRow: Int

        init?(image: CGImage) {
            let longest = max(image.width, image.height)
            let scale = longest > EdgeScan.maxSampleEdge
                ? Double(EdgeScan.maxSampleEdge) / Double(longest)
                : 1
            let w = max(1, Int((Double(image.width) * scale).rounded()))
            let h = max(1, Int((Double(image.height) * scale).rounded()))
            let bpr = w * 4
            var buffer = [UInt8](repeating: 0, count: bpr * h)
            guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

            let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
                guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                          bitsPerComponent: 8, bytesPerRow: bpr, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard drawn else { return nil }

            self.pixels = buffer
            self.width = w
            self.height = h
            self.bytesPerRow = bpr
        }

        func pixel(_ x: Int, _ y: Int) -> Pixel {
            let i = y * bytesPerRow + x * 4
            return Pixel(r: pixels[i], g: pixels[i + 1], b: pixels[i + 2], a: pixels[i + 3])
        }

        func alpha(_ x: Int, _ y: Int) -> UInt8 {
            pixels[y * bytesPerRow + x * 4 + 3]
        }
    }
}
