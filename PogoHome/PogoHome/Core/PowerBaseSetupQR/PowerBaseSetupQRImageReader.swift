import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Finds the QR codes in a picture the user chose -- on the device, with Vision. The picture is
/// decoded in memory, looked at and dropped: nothing is written anywhere and nothing is sent.
///
/// A chosen file is not trusted to be small or even to be a picture, so before anything is
/// decoded: the file may have at most `maxFileBytes` bytes, and the picture, by its own header,
/// at most `maxPixels` pixels and `maxSidePixels` on a side. It is then decoded *reduced* to at
/// most `passes` pixels on its longer side (first the smaller size; the larger one only when no
/// QR code was found and the picture is larger than that), upright as its orientation says, so
/// the memory used is bounded by the reduced size, not by the file.
nonisolated enum PowerBaseSetupQRImageReader {
    struct Limits: Equatable, Sendable {
        /// 32 MiB: above any photo or screenshot a phone makes.
        var maxFileBytes = 32 * 1024 * 1024
        /// 64 megapixels: a 48-megapixel photo fits.
        var maxPixels = 64_000_000
        var maxSidePixels = 16_384
        /// Longer side, in pixels, of each attempt: at most 4096 x 4096 x 4 bytes (64 MiB) are
        /// ever decoded at once.
        var passes = [2048, 4096]

        static let standard = Limits()
    }

    /// The picture a photo picker handed over (`nil`: it handed over nothing).
    static func read(_ data: Data?, limits: Limits = .standard) async -> PowerBaseSetupQRReading {
        await Task.detached(priority: .userInitiated) { scan(data, limits: limits) }.value
    }

    /// The file a file panel handed over. Its size is checked before it is read.
    static func read(fileAt url: URL, limits: Limits = .standard) async -> PowerBaseSetupQRReading {
        await Task.detached(priority: .userInitiated) { scan(fileAt: url, limits: limits) }.value
    }

    static func scan(fileAt url: URL, limits: Limits = .standard) -> PowerBaseSetupQRReading {
        // A file outside the sandbox the user picked in a panel.
        let isScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isScoped { url.stopAccessingSecurityScopedResource() }
        }
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
              let size = values.fileSize else { return .unreadableImage }
        guard size <= limits.maxFileBytes else { return .imageTooLarge }
        return scan(try? Data(contentsOf: url), limits: limits)
    }

    /// Synchronous: call it off the main thread.
    static func scan(_ data: Data?, limits: Limits = .standard) -> PowerBaseSetupQRReading {
        guard let data, !data.isEmpty else { return .unreadableImage }
        guard data.count <= limits.maxFileBytes else { return .imageTooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) >= 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?,
              let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return .unreadableImage }
        guard width <= limits.maxSidePixels, height <= limits.maxSidePixels, width <= limits.maxPixels / height else { return .imageTooLarge }

        for longerSide in limits.passes {
            guard let image = uprightImage(from: source, longerSide: longerSide), let symbols = symbols(in: image) else { return .unreadableImage }
            if !symbols.isEmpty || max(width, height) <= longerSide { return .symbols(symbols) }
        }
        return .symbols([])
    }

    /// The picture as it is meant to be seen -- turned and mirrored as its orientation says --
    /// decoded at no more than `longerSide` pixels on its longer side (never enlarged).
    static func uprightImage(from source: CGImageSource, longerSide: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longerSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Vision's first barcode detector, the one that needs no machine-learning hardware.
    private static let fallbackRevision = 1

    /// The text of every QR symbol Vision finds; `nil` when Vision could not look.
    ///
    /// Vision's current detector is asked first. Where it cannot run at all -- it throws "could not
    /// create inference context" in an iOS simulator, as do revisions 2 to 4 there -- the first
    /// detector is asked instead. A detector that ran and found nothing is believed.
    private static func symbols(in image: CGImage) -> [String?]? {
        for revision in [nil, fallbackRevision] {
            let request = VNDetectBarcodesRequest()
            if let revision {
                guard VNDetectBarcodesRequest.supportedRevisions.contains(revision) else { continue }
                request.revision = revision
            }
            request.symbologies = [.qr]
            do {
                try VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]).perform([request])
            } catch {
                continue
            }
            return (request.results ?? []).filter { $0.symbology == .qr }.map(\.payloadStringValue)
        }
        return nil
    }
}
