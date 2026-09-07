import Foundation
import PDFKit
import AppKit

/// Prepares uploaded PDF documents for an AI request.
///
/// Depending on the active model:
/// - **Vision models** receive rendered page images as OpenAI `image_url`
///   content parts, so the model can actually "read" the document layout,
///   tables, diagrams, math, etc.
/// - **Text-only models** receive the extracted text, injected into the
///   message content.
///
/// Both paths are CPU-heavy, so callers should run them off the main thread
/// (see `OpenAIService` which wraps them in `Task.detached`).
enum PDFProcessor {

    /// Longest edge (points) used when rasterizing a page for vision models.
    static let maxImageDimension: CGFloat = 1200

    /// UserDefaults key for the configurable page-render limit.
    static let maxRenderPagesKey = "pdf.maxRenderPages"

    /// 用户可调参数：视觉模型最多渲染的 PDF 页数（0 = 全部页）。
    /// 由设置界面写入，OpenAIService 渲染时读取。
    static var maxRenderPages: Int {
        let stored = UserDefaults.standard.integer(forKey: maxRenderPagesKey)
        return max(stored, 0)
    }

    // MARK: - Public API

    /// Number of pages in the PDF (0 when the data is not a valid PDF).
    static func pageCount(from data: Data) -> Int {
        PDFDocument(data: data)?.pageCount ?? 0
    }

    /// Extracts the document's text layer (fast; used by text-only models).
    static func extractText(from data: Data) -> String {
        guard let document = PDFDocument(data: data) else { return "" }
        return document.string ?? ""
    }

    /// Renders pages of the PDF to PNG `Data` (downscaled for vision models).
    ///
    /// - Parameter maxPages: 上限页数；`nil` 或 `<= 0` = 渲染全部页。
    /// - Returns: 每页一张 PNG；无效 PDF 返回空数组。
    static func renderPages(from data: Data, maxPages: Int? = nil) -> [Data] {
        guard let document = PDFDocument(data: data) else { return [] }
        let count: Int
        if let maxPages, maxPages > 0 {
            count = min(document.pageCount, maxPages)
        } else {
            count = document.pageCount
        }
        var images: [Data] = []
        for index in 0..<count {
            guard let page = document.page(at: index),
                  let png = render(page) else { continue }
            images.append(png)
        }
        return images
    }

    // MARK: - Page rendering

    /// Renders a page to PNG `Data`, downscaled so the longest edge stays
    /// within `maxImageDimension`.
    ///
    /// Uses `PDFPage.thumbnail(of:for:)` instead of a manual `CGContext`
    /// flip: PDFKit's renderer is rotation-aware and maps the media/crop box
    /// correctly, so pages with `/Rotate` or a non-zero box origin no longer
    /// have their edge text chopped ("腰斩").
    private static func render(_ page: PDFPage) -> Data? {
        let media = page.bounds(for: .mediaBox)
        let rotated = page.rotation == 90 || page.rotation == 270
        let pageWidth = rotated ? media.height : media.width
        let pageHeight = rotated ? media.width : media.height

        let longest = max(pageWidth, pageHeight)
        let scale = min(1, maxImageDimension / longest)
        let width = max(1, Int(pageWidth * scale))
        let height = max(1, Int(pageHeight * scale))

        // 与页面旋转后纵横比一致的尺寸 → 无变形、无黑边。
        let thumbnail = page.thumbnail(
            of: NSSize(width: CGFloat(width), height: CGFloat(height)),
            for: .mediaBox
        )
        let thumbSize = thumbnail.size

        // PDF 页面默认透明：铺白底后再输出 PNG。
        let canvas = NSImage(size: thumbSize)
        canvas.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: thumbSize).fill()
        thumbnail.draw(in: NSRect(origin: .zero, size: thumbSize))
        canvas.unlockFocus()

        guard let tiff = canvas.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
