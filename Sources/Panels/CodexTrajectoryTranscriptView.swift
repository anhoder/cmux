import AppKit
import CodexTrajectory
import SwiftUI

struct CodexTrajectoryTranscriptView: NSViewRepresentable {
    var items: [CodexAppServerTranscriptItem]

    func makeNSView(context: Context) -> CodexTrajectoryTranscriptScrollView {
        CodexTrajectoryTranscriptScrollView()
    }

    func updateNSView(_ nsView: CodexTrajectoryTranscriptScrollView, context: Context) {
        nsView.update(blocks: items.map(\.trajectoryBlock))
    }
}

private extension CodexAppServerTranscriptItem {
    var trajectoryBlock: CodexTrajectoryBlock {
        CodexTrajectoryBlock(
            id: id.uuidString,
            kind: trajectoryKind,
            title: title,
            text: body,
            isStreaming: isStreaming,
            createdAt: date
        )
    }

    var trajectoryKind: CodexTrajectoryBlockKind {
        switch role {
        case .user:
            return .userText
        case .assistant:
            return .assistantText
        case .event:
            return .systemEvent
        case .stderr:
            return .stderr
        case .error:
            return .stderr
        }
    }
}

final class CodexTrajectoryTranscriptScrollView: NSScrollView {
    private let trajectoryView = CodexTrajectoryTranscriptDocumentView()
    private var blocks: [CodexTrajectoryBlock] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        borderType = .noBorder
        documentView = trajectoryView
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        reloadPreservingScroll(stickToBottom: isScrolledNearBottom)
    }

    func update(blocks: [CodexTrajectoryBlock]) {
        let shouldStickToBottom = isScrolledNearBottom || blocks.count > self.blocks.count
        self.blocks = blocks
        reloadPreservingScroll(stickToBottom: shouldStickToBottom)
    }

    private var documentWidth: CGFloat {
        max(1, contentView.bounds.width)
    }

    private var isScrolledNearBottom: Bool {
        let visibleMaxY = contentView.bounds.maxY
        let documentHeight = trajectoryView.frame.height
        return documentHeight - visibleMaxY < 48
    }

    private func reloadPreservingScroll(stickToBottom: Bool) {
        guard documentWidth > 1 else { return }
        trajectoryView.update(blocks: blocks, width: documentWidth)
        if stickToBottom {
            scrollToBottom()
        }
    }

    private func scrollToBottom() {
        let maxY = max(0, trajectoryView.frame.height - contentView.bounds.height)
        contentView.scroll(to: NSPoint(x: 0, y: maxY))
        reflectScrolledClipView(contentView)
    }
}

private final class CodexTrajectoryTranscriptDocumentView: NSView {
    private struct PageEntry {
        var block: CodexTrajectoryBlock
        var page: CodexTrajectoryLayoutPage
    }

    private struct LayoutCacheKey: Hashable {
        var block: CodexTrajectoryBlock
        var width: Int
        var themeIdentifier: String
    }

    private struct CachedLayout {
        var block: CodexTrajectoryBlock
        var layout: CodexTrajectoryBlockLayout
    }

    private let layoutEngine = CodexTrajectoryLayoutEngine()
    private let renderer = CodexTrajectoryRenderer()
    private var blocks: [CodexTrajectoryBlock] = []
    private var entries: [PageEntry] = []
    private var heightIndex = CodexTrajectoryHeightIndex()
    private var cachedLayouts: [LayoutCacheKey: CachedLayout] = [:]
    private var documentWidth: CGFloat = 1
    private let horizontalInset: CGFloat = 14
    private let verticalInset: CGFloat = 10
    private let rowSpacing: CGFloat = 10

    override var isFlipped: Bool {
        true
    }

    override var wantsUpdateLayer: Bool {
        false
    }

    func update(blocks: [CodexTrajectoryBlock], width: CGFloat) {
        let normalizedWidth = max(1, width)
        guard blocks != self.blocks || abs(normalizedWidth - documentWidth) > 0.5 else { return }
        self.blocks = blocks
        documentWidth = normalizedWidth
        rebuildLayout()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        backgroundColor.setFill()
        NSBezierPath(rect: dirtyRect).fill()

        let range = heightIndex.indexRange(
            intersectingOffset: dirtyRect.minY,
            length: dirtyRect.height,
            overscan: 480
        )
        guard !range.isEmpty else { return }

        let theme = Self.theme(for: effectiveAppearance)
        for index in range {
            let y = heightIndex.prefixSum(upTo: index)
            let entry = entries[index]
            let pageRect = CGRect(
                x: horizontalInset,
                y: y + verticalInset / 2,
                width: max(1, documentWidth - horizontalInset * 2),
                height: entry.page.measuredSize.height
            )
            drawBackground(for: entry.block.kind, in: pageRect, context: context)
            renderer.draw(
                block: entry.block,
                page: entry.page,
                in: context,
                rect: pageRect,
                theme: theme,
                coordinates: .yDown
            )
        }
    }

    private var backgroundColor: NSColor {
        .textBackgroundColor
    }

    private func rebuildLayout() {
        let theme = Self.theme(for: effectiveAppearance)
        let layoutWidth = max(1, documentWidth - horizontalInset * 2)
        let configuration = CodexTrajectoryLayoutConfiguration(width: layoutWidth)
        entries.removeAll(keepingCapacity: true)
        var heights: [CGFloat] = []

        for block in blocks {
            let cacheKey = LayoutCacheKey(
                block: block,
                width: Int(layoutWidth.rounded()),
                themeIdentifier: theme.identifier
            )
            let layout: CodexTrajectoryBlockLayout
            if let cached = cachedLayouts[cacheKey] {
                layout = cached.layout
            } else {
                layout = layoutEngine.layout(
                    block: block,
                    configuration: configuration,
                    theme: theme
                )
                cachedLayouts[cacheKey] = CachedLayout(block: block, layout: layout)
            }

            for page in layout.pages {
                entries.append(PageEntry(block: block, page: page))
                heights.append(page.measuredSize.height + rowSpacing)
            }
        }

        if cachedLayouts.count > max(256, blocks.count * 2) {
            pruneLayoutCache()
        }

        heightIndex.replaceAll(with: heights)
        setFrameSize(NSSize(width: documentWidth, height: max(1, heightIndex.totalHeight)))
        needsDisplay = true
    }

    private func pruneLayoutCache() {
        let activeIDs = Set(blocks.map(\.id))
        cachedLayouts = cachedLayouts.filter { _, value in
            activeIDs.contains(value.block.id)
        }
    }

    private func drawBackground(
        for kind: CodexTrajectoryBlockKind,
        in rect: CGRect,
        context: CGContext
    ) {
        let fill = Self.backgroundColor(for: kind, appearance: effectiveAppearance)
        context.saveGState()
        context.setFillColor(fill.cgColor)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil))
        context.fillPath()
        context.restoreGState()
    }

    private static func theme(for appearance: NSAppearance) -> CodexTrajectoryTheme {
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let textFont = CTFontCreateUIFontForLanguage(.system, 13, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, 13, nil)
        let monoFont = CTFontCreateUIFontForLanguage(.userFixedPitch, 12, nil)
            ?? CTFontCreateWithName("Menlo" as CFString, 12, nil)
        let primary = color(.labelColor, appearance: appearance)
        let muted = color(.secondaryLabelColor, appearance: appearance)
        let error = color(isDark ? NSColor.systemRed : NSColor.systemRed, appearance: appearance)
        let fallback = CodexTrajectoryBlockStyle(font: textFont, foregroundColor: primary.cgColor)

        return CodexTrajectoryTheme(
            identifier: isDark ? "cmux-dark" : "cmux-light",
            contentInsets: CodexTrajectoryInsets(top: 9, left: 10, bottom: 9, right: 10),
            stylesByKind: [
                .userText: CodexTrajectoryBlockStyle(font: textFont, foregroundColor: primary.cgColor),
                .assistantText: CodexTrajectoryBlockStyle(font: textFont, foregroundColor: primary.cgColor),
                .commandOutput: CodexTrajectoryBlockStyle(font: monoFont, foregroundColor: primary.cgColor),
                .toolCall: CodexTrajectoryBlockStyle(font: monoFont, foregroundColor: muted.cgColor),
                .fileChange: CodexTrajectoryBlockStyle(font: monoFont, foregroundColor: primary.cgColor),
                .approvalRequest: CodexTrajectoryBlockStyle(font: textFont, foregroundColor: primary.cgColor),
                .status: CodexTrajectoryBlockStyle(font: textFont, foregroundColor: muted.cgColor),
                .stderr: CodexTrajectoryBlockStyle(font: monoFont, foregroundColor: error.cgColor),
                .systemEvent: CodexTrajectoryBlockStyle(font: monoFont, foregroundColor: muted.cgColor),
            ],
            fallbackStyle: fallback
        )
    }

    private static func backgroundColor(
        for kind: CodexTrajectoryBlockKind,
        appearance: NSAppearance
    ) -> NSColor {
        switch kind {
        case .userText:
            return color(NSColor.controlAccentColor.withAlphaComponent(0.10), appearance: appearance)
        case .assistantText:
            return color(.controlBackgroundColor, appearance: appearance)
        case .stderr:
            return color(NSColor.systemRed.withAlphaComponent(0.10), appearance: appearance)
        case .commandOutput, .toolCall, .fileChange, .systemEvent, .status, .approvalRequest:
            return color(.windowBackgroundColor, appearance: appearance)
        }
    }

    private static func color(_ color: NSColor, appearance: NSAppearance) -> NSColor {
        var resolved = color
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return resolved.usingColorSpace(.sRGB) ?? resolved
    }
}
