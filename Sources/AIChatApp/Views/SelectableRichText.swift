import SwiftUI
import AppKit

/// 只读 `NSTextView` 封装——macOS 上唯一可靠的「跨段落拖选复制」方案。
///
/// SwiftUI 的 `Text`（即使单个视图内含换行）在 macOS 上仍按段落分内部容器，
/// 光标拖选跨不过段落边界；MarkdownUI 更是每段一个独立 `Text`。NSTextView
/// 原生支持任意跨段选择 + Cmd/Ctrl+C + 右键菜单复制。
///
/// 视图不包 `NSScrollView`，滚轮事件直通外层消息列表滚动。
struct SelectableRichText: NSViewRepresentable {

    let attributed: NSAttributedString

    // MARK: - Coordinator（链接点击）

    final class Coordinator: NSObject, NSTextViewDelegate {
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL {
                NSWorkspace.shared.open(url)
            }
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: - NSView

    func makeNSView(context: Context) -> NSTextView {
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.isRichText = true
        tv.importsGraphics = false
        tv.allowsUndo = false
        tv.usesFindPanel = false
        tv.textContainerInset = .zero
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.heightTracksTextView = false
        tv.textContainer?.lineFragmentPadding = 0
        tv.delegate = context.coordinator
        return tv
    }

    func updateNSView(_ tv: NSTextView, context: Context) {
        if tv.attributedString() != attributed {
            tv.textStorage?.setAttributedString(attributed)
        }
    }

    /// 高度 = 文本在给定宽度下的实际布局高度（多段落、列表、标题都正确）。
    ///
    /// 复用 `nsView` 自己的布局管理器：`updateNSView` 已写入文本并触发布局，
    /// 宽度不变时 `ensureLayout` 是缓存命中，避免每次新建 NSLayoutManager
    /// 做全量排版（流式渲染时 layout 会被反复询问，这是卡顿来源之一）。
    func sizeThatFits(_ proposal: ProposedViewSize,
                      nsView: NSTextView,
                      context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.frame.width
        guard width > 0 else { return nil }
        nsView.textContainer?.containerSize = NSSize(
            width: width,
            height: CGFloat.greatestFiniteMagnitude
        )
        nsView.textContainer?.widthTracksTextView = true
        nsView.layoutManager?.ensureLayout(for: nsView.textContainer!)
        let height = ceil(nsView.layoutManager!.usedRect(for: nsView.textContainer!).height) + 1
        return CGSize(width: width, height: height)
    }
}

// MARK: - 纯散文 Markdown → NSAttributedString

/// 把「纯散文」Markdown（无代码围栏 / 表格 / LaTeX / 图片）构建成单个
/// `NSAttributedString`，交给 `SelectableRichText` 渲染。保留真实换行（段落 /
/// 列表项按 `\n` 换段），行内样式（加粗 / 斜体 / 行内代码 / 链接）由
/// `AttributedString` 行内解析提供，块级结构（标题 / 引用 / 列表符号）用
/// `NSParagraphStyle` / `NSTextList` 显式渲染——不依赖 NSTextView 对
/// `presentationIntent` 的支持。
enum PlainMarkdownBuilder {

    static func build(
        markdown: String,
        baseFont: NSFont,
        codeColor: NSColor,
        quoteColor: NSColor
    ) -> NSAttributedString {
        let out = NSMutableAttributedString()

        func addInline(_ text: String,
                       font: NSFont,
                       style: NSMutableParagraphStyle,
                       color: NSColor) {
            let inline = (try? AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString(text)

            var base = inline
            for run in base.runs {
                var container = AttributeContainer()
                let intent = run.inlinePresentationIntent
                var f = font
                if intent?.contains(.code) == true {
                    f = NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.9,
                                                    weight: .regular)
                }
                if intent?.contains(.stronglyEmphasized) == true {
                    f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask)
                }
                if intent?.contains(.emphasized) == true {
                    f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask)
                }
                container.font = f
                if intent?.contains(.code) == true {
                    container.foregroundColor = codeColor
                }
                base[run.range].mergeAttributes(container)
            }

            let piece = NSMutableAttributedString(base)
            piece.addAttribute(
                .paragraphStyle,
                value: style,
                range: NSRange(location: 0, length: piece.length)
            )
            out.append(piece)
        }

        func paraStyle() -> NSMutableParagraphStyle {
            let ps = NSMutableParagraphStyle()
            ps.lineSpacing = 1.5
            ps.paragraphSpacing = baseFont.pointSize * 0.45
            return ps
        }

        /// 在块之间插入空行（已是空行结尾时不重复）。
        func paragraphBreak() {
            if out.length > 0, !out.string.hasSuffix("\n\n") {
                out.append(NSAttributedString(string: "\n\n"))
            }
        }

        let lines = markdown.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { i += 1; continue }

            // ---- 标题 ----
            if trimmed.hasPrefix("#") {
                var level = 0
                var idx = trimmed.startIndex
                while idx < trimmed.endIndex, trimmed[idx] == "#" {
                    level += 1
                    idx = trimmed.index(after: idx)
                }
                // CommonMark：`#标题`（无空格）不是标题，当作正文。
                guard idx < trimmed.endIndex, trimmed[idx] == " " || trimmed[idx] == "\t" else {
                    // 落入下方普通段落分支
                    var paragraphLines = [trimmed]
                    i += 1
                    while i < lines.count {
                        let r = lines[i]
                        let t = r.trimmingCharacters(in: .whitespaces)
                        if t.isEmpty { break }
                        if t.hasPrefix("#") || t.hasPrefix(">") || listMarker(t) != nil { break }
                        paragraphLines.append(t)
                        i += 1
                    }
                    paragraphBreak()
                    addInline(paragraphLines.joined(separator: " "),
                              font: baseFont,
                              style: paraStyle(),
                              color: .labelColor)
                    continue
                }
                let text = String(trimmed[trimmed.index(after: idx)...])
                paragraphBreak()
                let ps = paraStyle()
                ps.paragraphSpacing = baseFont.pointSize * 0.8
                ps.paragraphSpacingBefore = baseFont.pointSize * 0.9
                let ratios: [CGFloat] = [1.4, 1.25, 1.12, 1.0, 0.92, 0.85]
                let size = baseFont.pointSize * (level >= 1 && level <= 6 ? ratios[level - 1] : 1)
                let headingFont = NSFontManager.shared.convert(
                    NSFont.systemFont(ofSize: size),
                    toHaveTrait: .boldFontMask
                )
                addInline(text, font: headingFont, style: ps, color: .labelColor)
                i += 1
                continue
            }

            // ---- 引用 ----
            if trimmed.hasPrefix(">") {
                var text = Substring(trimmed).dropFirst()
                if text.hasPrefix(" ") { text = text.dropFirst() }
                paragraphBreak()
                let ps = paraStyle()
                ps.headIndent = baseFont.pointSize * 1.1
                ps.firstLineHeadIndent = baseFont.pointSize * 0.3
                ps.paragraphSpacing = baseFont.pointSize * 0.5
                addInline(String(text), font: baseFont, style: ps, color: quoteColor)
                i += 1
                continue
            }


            // ---- 列表（连续列表项成组） ----
            if listMarker(trimmed) != nil {
                var group: [(level: Int, text: String, decimal: Bool)] = []
                while i < lines.count {
                    let r = lines[i]
                    if r.trimmingCharacters(in: .whitespaces).isEmpty { break }
                    let t = r.drop(while: { $0 == " " || $0 == "\t" })
                    guard let marker = listMarker(String(t)) else { break }
                    group.append((level: r.count - t.count,
                                  text: marker.rest,
                                  decimal: marker.fmt == .decimal))
                    i += 1
                }
                paragraphBreak()
                for (index, item) in group.enumerated() {
                    if index > 0 { out.append(NSAttributedString(string: "\n")) }
                    let ps = paraStyle()
                    ps.paragraphSpacing = baseFont.pointSize * 0.15
                    // 由外层到内层建列表，再反转成「textLists[0] 为最内层」。
                    let fmt = item.decimal
                        ? NSTextList.MarkerFormat.decimal
                        : NSTextList.MarkerFormat.disc
                    var lists: [NSTextList] = []
                    for _ in 0...item.level {
                        lists.append(NSTextList(markerFormat: fmt, options: 0))
                    }
                    ps.textLists = lists.reversed()
                    ps.headIndent = CGFloat(item.level + 1) * baseFont.pointSize * 1.1
                    addInline(item.text, font: baseFont, style: ps, color: .labelColor)
                }
                continue
            }

            // ---- 普通段落（连续行用空格软连接） ----
            var paragraphLines = [trimmed]
            i += 1
            while i < lines.count {
                let r = lines[i]
                let t = r.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { break }
                if t.hasPrefix("#") || t.hasPrefix(">") || listMarker(t) != nil { break }
                paragraphLines.append(t)
                i += 1
            }
            paragraphBreak()
            addInline(paragraphLines.joined(separator: " "),
                      font: baseFont,
                      style: paraStyle(),
                      color: .labelColor)
        }

        return out
    }

    /// 识别列表项前缀：`- ` / `* ` / `+ `（无序）与 `1. ` / `1) `（有序）。
    private static func listMarker(_ s: String) -> (fmt: NSTextList.MarkerFormat, rest: String)? {
        for prefix in ["- ", "* ", "+ "] where s.hasPrefix(prefix) {
            return (.disc, String(s.dropFirst(2)))
        }
        var j = s.startIndex
        while j < s.endIndex, s[j].isNumber { j = s.index(after: j) }
        if j > s.startIndex, j < s.endIndex, s[j] == "." || s[j] == ")" {
            let rest = String(s.suffix(from: s.index(after: j)))
            if rest.isEmpty || rest.hasPrefix(" ") {
                let text = rest.hasPrefix(" ") ? String(rest.dropFirst()) : rest
                return (.decimal, text)
            }
        }
        return nil
    }
}

