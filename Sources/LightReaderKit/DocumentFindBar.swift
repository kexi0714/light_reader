import PDFKit
import SwiftUI

struct DocumentFindBar: View {
    let reader: ReaderState
    let request: UUID
    @State private var query = ""
    @State private var matches: [PDFSelection] = []
    @State private var index = 0
    @State private var searching = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("在文献中查找", text: $query)
                .textFieldStyle(.plain).focused($focused)
                .onSubmit { move(by: 1) }
            if !query.isEmpty {
                Text(searching ? "查找中…" : matches.isEmpty ? "无匹配" : "\(index + 1) / \(matches.count)")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Group {
                Button { move(by: -1) } label: { Image(systemName: "chevron.up") }
                    .accessibilityLabel("上一个匹配")
                Button { move(by: 1) } label: { Image(systemName: "chevron.down") }
                    .accessibilityLabel("下一个匹配")
            }.disabled(matches.isEmpty)
            Button("完成", action: close)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16).frame(height: 34)
        .onChange(of: request, initial: true) { _, _ in focused = true }
        .onExitCommand(perform: close)
        .task(id: query) { await search(query) }
        .onDisappear { reader.canvas?.highlightedSelections = nil }
    }

    @MainActor private func search(_ term: String) async {
        matches = []
        index = 0
        reader.canvas?.highlightedSelections = nil
        searching = !term.isEmpty
        guard !term.isEmpty, let pdf = reader.pdf else { return }
        do {
            try await Task.sleep(for: .milliseconds(150))
            let found = try await Self.find(term, in: pdf)
            try Task.checkCancellation()
            matches = found
            searching = false
            if !matches.isEmpty { move(by: 0) }
        } catch { /* The replacement query or closing the bar cancels this search. */ }
    }

    @MainActor static func find(_ term: String, in pdf: PDFDocument) async throws -> [PDFSelection] {
        guard !term.isEmpty else { return [] }
        var matches: [PDFSelection] = []
        for number in 0..<pdf.pageCount {
            await Task.yield()
            try Task.checkCancellation()
            guard let page = pdf.page(at: number), let text = page.string as NSString? else { continue }
            var start = 0
            while start < text.length {
                let range = text.range(of: term, options: .caseInsensitive,
                                       range: NSRange(location: start, length: text.length - start))
                guard range.location != NSNotFound, range.length > 0 else { break }
                if let selection = page.selection(for: range) { matches.append(selection) }
                start = NSMaxRange(range)
            }
        }
        return matches
    }

    private func move(by offset: Int) {
        guard !matches.isEmpty, let canvas = reader.canvas else { return }
        index = (index + offset + matches.count) % matches.count
        let selection = matches[index]
        selection.color = NSColor.systemYellow.withAlphaComponent(0.55)
        canvas.highlightedSelections = [selection]
        canvas.go(to: selection)
    }

    private func close() {
        reader.findRequest = nil
        if let canvas = reader.canvas { canvas.window?.makeFirstResponder(canvas) }
    }
}
