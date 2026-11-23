import PDFKit

/// Selection bounds include typographic leading. Highlight the visible glyphs
/// instead, leaving the whitespace between adjacent lines unpainted.
enum TextMarkupGeometry {
    static func glyphBounds(on page: PDFPage) -> [CGRect] {
        (0..<page.numberOfCharacters).compactMap { index in
            let rect = page.characterBounds(at: index)
            return usable(rect) ? rect : nil
        }
    }

    static func highlightBounds(for line: PDFSelection, on page: PDFPage, glyphs: [CGRect]) -> CGRect {
        let selection = line.bounds(for: page)
        guard usable(selection) else { return selection }
        // Match geometrically: PDFKit's character indices can differ from its
        // selection ranges for PDFs with synthesized whitespace or ligatures.
        let ink = glyphs.filter { selection.contains(CGPoint(x: $0.midX, y: $0.midY)) }
            .reduce(CGRect.null) { $0.union($1) }
        guard usable(ink) else { return selection }
        // Keep the selected width (including spaces), and preserve descenders,
        // accents and superscripts. Padding scales down for small text.
        let padding = min(0.5, ink.height * 0.04)
        let bottom = max(selection.minY, ink.minY - padding)
        let top = min(selection.maxY, ink.maxY + padding)
        guard top > bottom else { return selection }
        return CGRect(x: selection.minX, y: bottom, width: selection.width, height: top - bottom)
    }

    static func quadrilateralPoints(for bounds: CGRect) -> [NSValue] {
        // PDFKit takes Z-ordered points relative to the annotation origin.
        [CGPoint(x: 0, y: bounds.height), CGPoint(x: bounds.width, y: bounds.height),
         CGPoint(x: 0, y: 0), CGPoint(x: bounds.width, y: 0)].map { NSValue(point: $0) }
    }

    private static func usable(_ rect: CGRect) -> Bool {
        !rect.isEmpty && !rect.isNull && !rect.isInfinite &&
        rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite
    }
}
