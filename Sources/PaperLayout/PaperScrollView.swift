import SwiftUI
import AppKit

/// An AppKit NSScrollView wrapper that provides real frame-based scrolling.
/// Unlike SwiftUI's ScrollView which uses CALayer transforms (invisible to
/// NSView.convert(_:to:)), this uses NSScrollView's boundsOrigin which
/// properly updates the coordinate system for all subviews.
struct PaperScrollView<Content: View>: NSViewRepresentable {
    let contentWidth: CGFloat
    let scrollOffset: CGFloat
    let animationDuration: Double
    let onScrollComplete: (() -> Void)?
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> PaperNSScrollView {
        let scrollView = PaperNSScrollView()
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = .init()

        let hostingView = NSHostingView(rootView: content())
        scrollView.documentView = hostingView

        context.coordinator.scrollView = scrollView
        context.coordinator.hostingView = hostingView

        return scrollView
    }

    func updateNSView(_ scrollView: PaperNSScrollView, context: Context) {
        // Update the hosted SwiftUI content
        if let hostingView = context.coordinator.hostingView {
            hostingView.rootView = content()
            // Set the document view size to the full canvas width
            let scrollFrame = scrollView.frame
            hostingView.frame = NSRect(
                x: 0, y: 0,
                width: max(contentWidth, scrollFrame.width),
                height: scrollFrame.height
            )
        }

        // Scroll to the target offset
        let targetPoint = NSPoint(x: scrollOffset, y: 0)
        let currentOrigin = scrollView.contentView.bounds.origin

        if abs(currentOrigin.x - targetPoint.x) > 0.5 {
            if animationDuration > 0 && context.coordinator.hasAppeared {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = animationDuration
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    ctx.allowsImplicitAnimation = true
                    scrollView.contentView.animator().setBoundsOrigin(targetPoint)
                } completionHandler: {
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                    onScrollComplete?()
                }
            } else {
                scrollView.contentView.scroll(to: targetPoint)
                scrollView.reflectScrolledClipView(scrollView.contentView)
                onScrollComplete?()
            }
        }

        context.coordinator.hasAppeared = true
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var scrollView: PaperNSScrollView?
        var hostingView: NSHostingView<Content>?
        var hasAppeared = false
    }
}

/// Custom NSScrollView that disables user scrolling but allows programmatic scrolling.
class PaperNSScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        // Don't handle scroll wheel events - let them pass through
        // to the terminal views for their own scrollback
        nextResponder?.scrollWheel(with: event)
    }
}
