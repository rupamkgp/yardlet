import AppKit
import ImageIO
import PDFKit
import SwiftUI

/// An image or a PDF in the Files panel, as the Codex and Claude apps show one beside the
/// conversation: an image fitted to the panel and never past its own size, a PDF's pages one under
/// another at the panel's width.
struct WorkspaceFileMediaView: View {
    let media: WorkspaceFileMedia

    var body: some View {
        switch media.kind {
        case .image: FileImageView(url: media.url)
        case .pdf: FilePDFView(url: media.url)
        }
    }
}

private struct FileImageView: View {
    let url: URL
    @State private var image: DecodedImage?
    @State private var isUnavailable = false

    var body: some View {
        Group {
            if let image {
                Image(decorative: image.cgImage, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement()
                    .accessibilityLabel(url.lastPathComponent)
                    .accessibilityAddTraits(.isImage)
            } else if isUnavailable {
                WorkSurfaceEmptyState(title: L10n.string("Preview unavailable for this file"), systemName: "photo")
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            image = nil
            isUnavailable = false
            let url = url
            image = await Task.detached(priority: .userInitiated) { DecodedImage(url) }.value
            isUnavailable = image == nil
        }
    }
}

/// An image decoded off the main thread, at most `longSidePixels` on its longer side, with the size
/// in points its own resolution gives it.
private struct DecodedImage: @unchecked Sendable {
    static let longSidePixels = 4_096
    let cgImage: CGImage
    let size: CGSize

    init?(_ url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              var height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
              width > 0, height > 0 else { return nil }
        // EXIF orientations 5 to 8 turn the picture a quarter.
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, orientation >= 5 { swap(&width, &height) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(Int(max(width, height)), Self.longSidePixels)
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // A screenshot saved at 144 dpi is drawn at half its pixels, as Preview draws it.
        let dpi = (properties[kCGImagePropertyDPIWidth] as? CGFloat).flatMap { $0 > 0 ? $0 : nil } ?? 72
        cgImage = image
        size = CGSize(width: width * 72 / dpi, height: height * 72 / dpi)
    }
}

/// A PDF's pages one under another at the panel's width, each drawn by PDFKit as it scrolls into view.
/// PDFKit's own `PDFView` draws only in a window on screen, so the panel could not be checked unshown.
private struct FilePDFView: View {
    let url: URL
    @State private var document: PDFDocument?
    @State private var isUnavailable = false

    var body: some View {
        Group {
            if let document {
                GeometryReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(0..<document.pageCount, id: \.self) { index in
                                if let page = document.page(at: index) {
                                    PDFPageImage(page: page, width: max(1, proxy.size.width - 32))
                                }
                            }
                        }
                        .padding(16)
                    }
                }
                .accessibilityLabel(url.lastPathComponent)
            } else if isUnavailable {
                WorkSurfaceEmptyState(title: L10n.string("Preview unavailable for this file"), systemName: "doc.richtext")
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            document = PDFDocument(url: url)
            isUnavailable = document == nil || document?.pageCount == 0
        }
    }
}

private struct PDFPageImage: View {
    let page: PDFPage
    let width: CGFloat
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let bounds = page.bounds(for: .cropBox)
        // A page turned a quarter is as wide as it is tall unturned.
        let turned = page.rotation % 180 != 0
        let height = width * (turned ? bounds.width : bounds.height) / max(1, turned ? bounds.height : bounds.width)
        Image(nsImage: page.thumbnail(of: NSSize(width: width * displayScale, height: height * displayScale), for: .cropBox))
            .resizable()
            .frame(width: width, height: height)
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
    }
}
