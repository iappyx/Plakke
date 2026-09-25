import AppKit
import Foundation
import Vision

/// A running recognition. Cancel it when the clip it belongs to is evicted.
final class OCRTask {
    fileprivate let request = VNRecognizeTextRequest()
    private let lock = NSLock()
    private var cancelled = false
    private var finished = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        request.cancel()
    }

    /// Returns true exactly once, so a failure reported through both the request handler and a
    /// thrown `perform` can't deliver two callbacks.
    fileprivate func claimCompletion() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if finished || cancelled { return false }
        finished = true
        return true
    }
}

enum OCR {
    /// Serial: every captured image used to get its own global-queue block, so a burst of
    /// screenshots meant a burst of simultaneous Vision requests and a thread explosion.
    private static let queue = DispatchQueue(label: "app.plakke.ocr", qos: .utility)

    /// Recognition gets no better above this, and a 10000×10000 capture pegs a core for seconds.
    private static let maxPixels = 8_000_000

    /// Recognizes text in a PNG off the main thread; calls back on main with joined lines (or nil).
    @discardableResult
    static func recognize(_ png: Data, completion: @escaping (String?) -> Void) -> OCRTask {
        let task = OCRTask()
        let request = task.request
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        func finish(_ text: String?) {
            guard task.claimCompletion() else { return }
            DispatchQueue.main.async { completion(text) }
        }

        queue.async {
            guard !task.isCancelled else { return }
            guard let image = downscaledCGImage(from: png) else { return finish(nil) }

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
                guard !task.isCancelled else { return }
                let observations = request.results ?? []
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                finish(text.isEmpty ? nil : text)
            } catch {
                finish(nil)
            }
        }
        return task
    }

    /// Longest edge handed to Vision. `maxPixels` at a 1:1 aspect.
    private static let maxEdge = 2800

    /// Decodes the PNG *already bounded*, via ImageIO's thumbnail path.
    ///
    /// The previous version materialised the full bitmap and only then checked the pixel cap, so a
    /// flat-colour 20000×20000 PNG — a few megabytes on disk, comfortably under the image size limit —
    /// decoded to about 1.6 GB before anything looked at it. It also built the downscale context with
    /// the source's own colour space, which is an unsupported combination for grayscale, indexed and
    /// CMYK images: the context came back nil and the un-downscaled image went to Vision anyway,
    /// which is exactly the case (scanned documents) where the cap mattered most.
    private static func downscaledCGImage(from png: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
