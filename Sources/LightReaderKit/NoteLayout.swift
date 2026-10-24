import AppKit
import PDFKit

/// PDFKit's FreeText baseline differs slightly from TextKit's baseline. Measure
/// baseline and line spacing once per font so editing matches the saved PDF.
enum NoteLayout {
    private struct Metrics { let inset: NSSize; let lineSpacing: CGFloat }
    private static var cached: [String: Metrics] = [:]

    static func inset(for font: NSFont) -> NSSize { metrics(for: font).inset }

    static func paragraph(for font: NSFont, alignment: NSTextAlignment = .left) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineSpacing = metrics(for: font).lineSpacing
        return paragraph
    }

    private static func metrics(for font: NSFont) -> Metrics {
        let key = "\(font.fontName):\(font.pointSize)"
        if let metrics = cached[key] { return metrics }
        let size = ceil(max(32, font.pointSize * 4))
        let resolution: CGFloat = 4
        let pixels = Int(size * resolution)
        func inkRows(_ draw: (CGContext) -> Void) -> (first: Int, last: Int)? {
            guard let context = CGContext(data: nil, width: pixels, height: pixels,
                bitsPerComponent: 8, bytesPerRow: pixels * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
            context.scaleBy(x: resolution, y: resolution)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            draw(context)
            NSGraphicsContext.restoreGraphicsState()
            guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
            var first: Int?, last = 0
            for y in 0..<pixels {
                for x in 0..<pixels where data[(y * pixels + x) * 4] < 128 {
                    if first == nil { first = y }
                    last = y
                    break
                }
            }
            return first.map { ($0, last) }
        }
        func nativeRows(_ content: String) -> (first: Int, last: Int)? {
            inkRows { context in
                let sample = PDFAnnotation(bounds: NSRect(x: 0, y: 0, width: size, height: size), forType: .freeText, withProperties: nil)
                sample.contents = content
                sample.font = font
                sample.fontColor = .black
                sample.color = .clear
                let border = PDFBorder(); border.lineWidth = 0; sample.border = border
                sample.draw(with: .cropBox, in: context)
            }
        }
        func editingRows(_ content: String) -> (first: Int, last: Int)? {
            inkRows { context in
                context.translateBy(x: 0, y: size)
                context.scaleBy(x: 1, y: -1)
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                let storage = NSTextStorage(string: content, attributes: [.font: font, .foregroundColor: NSColor.black])
                let layout = NSLayoutManager()
                let container = NSTextContainer(containerSize: NSSize(width: size, height: size))
                container.lineFragmentPadding = 0
                storage.addLayoutManager(layout)
                layout.addTextContainer(container)
                layout.drawGlyphs(forGlyphRange: layout.glyphRange(for: container), at: .zero)
            }
        }
        let native = nativeRows("H"), editing = editingRows("H")
        let top = native.flatMap { n in editing.map { CGFloat(n.first - $0.first) / resolution } } ?? 2
        var spacing: CGFloat = 0
        if let native, let editing, let nativeTwo = nativeRows("H\nH"), let editingTwo = editingRows("H\nH") {
            spacing = CGFloat((nativeTwo.last - native.last) - (editingTwo.last - editing.last)) / resolution
        }
        let metrics = Metrics(inset: NSSize(width: 2, height: max(0, top)), lineSpacing: spacing)
        cached[key] = metrics
        return metrics
    }
}
