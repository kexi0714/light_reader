import PDFKit

extension PDFSelection {
    static func combining(_ selections: [PDFSelection], in document: PDFDocument) -> PDFSelection {
        let result = PDFSelection(document: document)
        for page in selections.flatMap({ $0.pages }).sorted(by: { document.index(for: $0) < document.index(for: $1) }) {
            // Visit each page only once; gather every fragment before merging overlap.
            if result.pages.contains(where: { $0 === page }) { continue }
            let ranges = selections.flatMap { selection in
                (0..<selection.numberOfTextRanges(on: page)).map { selection.range(at: $0, on: page) }
            }.filter { $0.location != NSNotFound && $0.length > 0 }.sorted { $0.location < $1.location }
            var merged: [NSRange] = []
            for range in ranges {
                if let last = merged.last, range.location <= NSMaxRange(last) {
                    merged[merged.count - 1] = NSUnionRange(last, range)
                } else { merged.append(range) }
            }
            for range in merged {
                if let fragment = page.selection(for: range) { result.add(fragment) }
            }
        }
        return result
    }

    /// Ranges are normalized in document order and joined continuously for translation.
    /// Normalize each contiguous range independently while preserving a natural word gap.
    var translationText: String {
        pages.flatMap { page in
            (0..<numberOfTextRanges(on: page)).compactMap { index -> String? in
                guard let text = page.selection(for: range(at: index, on: page))?.string else { return nil }
                let normalized = TextPreparation.normalizeSelection(text)
                return normalized.isEmpty ? nil : normalized
            }
        }.joined(separator: " ")
    }
}
