import AppKit

/// Transient selection feedback, kept outside the PDF annotations and saved file.
final class MarkupSelectionOverlay: NSView {
    var selectionRects: [NSRect] = [] {
        didSet {
            isHidden = selectionRects.isEmpty
            needsDisplay = true
        }
    }

    // Let clicks and drags reach the PDF text and annotation handlers beneath us.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // A light neutral tint signals selection without competing with the
        // highlight color or adding a border around the text.
        NSColor.black.withAlphaComponent(0.08).setFill()
        for rect in selectionRects where rect.intersects(dirtyRect) {
            NSBezierPath(rect: rect).fill()
        }
    }
}
