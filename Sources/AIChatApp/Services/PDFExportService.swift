import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Exports a chat session to a multi-page PDF.
///
/// Zero dependencies: `ImageRenderer` (macOS 13+) draws a real SwiftUI view
/// tree into a `CGPDFContext`, so the export reuses `MarkdownText` verbatim —
/// syntax-highlighted code cards, SwiftMath formulas, tables and the Claude
/// palette all come out exactly as rendered in the app, and the text stays
/// **vector** (selectable / searchable in the PDF) rather than a screenshot.
///
/// Pagination is **block-level**: the transcript is split into independent
/// blocks (header / each message / footer), every block is measured and then
/// placed WHOLE onto a page. Page breaks therefore only happen between
/// messages — a line of text is never chopped mid-line by a fixed band cut
/// (“腰斩”). Blocks taller than one page are expanded into page-height bands
/// so no content is lost.
@MainActor
enum PDFExportService {

    /// US-Letter at 72 dpi (matches SwiftUI's point coordinate space).
    private static let pageSize = CGSize(width: 612, height: 792)

    /// Page margins in points.
    private static let margin: CGFloat = 40

    /// Vertical gap between blocks (matches the in-document spacing look).
    private static let blockGap: CGFloat = 14

    // MARK: - Public API

    /// Shows a save panel and writes the session as a PDF.
    ///
    /// - Returns: The written file URL, or `nil` when the user cancelled.
    @discardableResult
    static func export(
        session: ChatSession,
        appearance: AppearanceStore,
        localization: LocalizationManager
    ) throws -> URL? {
        let panel = NSSavePanel()
        panel.title = L("export.pdf")
        panel.prompt = L("export.pdf")
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(safeFilename(session.title)).pdf"

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        let data = try pdfData(
            session: session,
            appearance: appearance,
            localization: localization
        )
        try data.write(to: url)
        return url
    }

    // MARK: - Rendering

    /// 一个可排版单元：一块内容（或超高块切出的一个页带）。
    private struct PageUnit {
        let block: TranscriptBlock
        /// 本单元在页面上占用的可见高度。
        let visibleHeight: CGFloat
        /// 超高块页带相对块顶的下移量（普通块为 0）。
        let bandShift: CGFloat
    }

    /// Renders the session into PDF data.
    static func pdfData(
        session: ChatSession,
        appearance: AppearanceStore,
        localization: LocalizationManager
    ) throws -> Data {
        let contentWidth = pageSize.width - margin * 2
        let usableHeight = pageSize.height - margin * 2

        let document = TranscriptDocument(
            session: session,
            appearance: appearance,
            localization: localization
        )
        let blocks = document.blocks

        // 1) 逐块测量高度（只取布局尺寸，不取绘制闭包）。
        var blockHeights: [CGFloat] = []
        for block in blocks {
            let view = block.makeView(session: session, appearance: appearance)
                .environmentObject(appearance)
                .frame(width: contentWidth)
                .background(Color.white)
            let renderer = ImageRenderer(content: view)
            renderer.proposedSize = ProposedViewSize(width: contentWidth, height: nil)
            renderer.render { size, _ in
                blockHeights.append(max(0, size.height))
            }
        }

        // 2) 展开超高块为页带，保证内容不丢失。
        var units: [PageUnit] = []
        for (index, height) in blockHeights.enumerated() {
            let block = blocks[index]
            if height > usableHeight {
                let bandCount = Int(ceil(height / usableHeight))
                for k in 0..<bandCount {
                    units.append(PageUnit(
                        block: block,
                        visibleHeight: min(usableHeight, height - CGFloat(k) * usableHeight),
                        bandShift: max(0, height - CGFloat(k + 1) * usableHeight)
                    ))
                }
            } else {
                units.append(PageUnit(block: block, visibleHeight: height, bandShift: 0))
            }
        }

        // 3) 整块打包：当前页放不下就开新页。
        var pages: [[PageUnit]] = []
        var currentPage: [PageUnit] = []
        var used: CGFloat = 0
        for unit in units {
            let slot = unit.visibleHeight + blockGap
            if !currentPage.isEmpty && used + slot > usableHeight {
                pages.append(currentPage)
                currentPage = []
                used = 0
            }
            currentPage.append(unit)
            used += slot
        }
        if !currentPage.isEmpty {
            pages.append(currentPage)
        }

        // 4) 逐页绘制。
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output) else {
            throw ExportError.contextCreationFailed
        }

        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ExportError.contextCreationFailed
        }

        for page in pages {
            context.beginPDFPage(nil)
            context.saveGState()

            // 先裁切到文本区，内容不会溢进页边距。
            context.clip(to: CGRect(
                x: margin,
                y: margin,
                width: contentWidth,
                height: usableHeight
            ))


            // 块在内容区自上而下摆放；每块独立渲染（向量文字），
            // 平移 CTM 把块放进自己的槽位（超高页带额外下移对齐）。
            var y: CGFloat = 0
            for unit in page {
                let blockView = unit.block.makeView(session: session, appearance: appearance)
                    .environmentObject(appearance)
                    .frame(width: contentWidth)
                    .background(Color.white)
                let renderer = ImageRenderer(content: blockView)
                renderer.proposedSize = ProposedViewSize(width: contentWidth, height: nil)
                renderer.render { _, drawInContext in
                    context.saveGState()
                    context.translateBy(
                        x: margin,
                        y: margin + usableHeight - y - unit.visibleHeight
                    )
                    if unit.bandShift > 0 {
                        context.translateBy(x: 0, y: -unit.bandShift)
                    }
                    drawInContext(context)
                    context.restoreGState()
                }
                y += unit.visibleHeight + blockGap
            }

            context.restoreGState()
            context.endPDFPage()
        }

        context.closePDF()
        return output as Data
    }

    // MARK: - Helpers

    /// Strips characters that are illegal (or annoying) in filenames.
    private static func safeFilename(_ title: String) -> String {
        let cleaned = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\\n\\r\\t"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = cleaned.isEmpty ? "AIChat" : String(cleaned.prefix(60))
        return trimmed
    }

    /// Errors surfaced to the UI.
    enum ExportError: LocalizedError {
        case contextCreationFailed

        var errorDescription: String? {
            switch self {
            case .contextCreationFailed:
                return L("export.pdf.failed")
            }
        }
    }
}

