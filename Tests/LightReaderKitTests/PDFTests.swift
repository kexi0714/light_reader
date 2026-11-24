import AppKit
import PDFKit
import CoreText
import SwiftUI
@testable import LightReaderKit

final class PDFTests {
    private func makePDF() throws -> PDFDocument {
        let buffer = NSMutableData()
        let consumer = try require(CGDataConsumer(data: buffer))
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        let text = NSAttributedString(string: "Scientific research improves our understanding.\nA second line supports annotation tests.", attributes: [.font: NSFont.systemFont(ofSize: 16)])
        let setter = CTFramesetterCreateWithAttributedString(text)
        let path = CGPath(rect: CGRect(x: 50, y: 600, width: 500, height: 100), transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil), context)
        context.endPDFPage()
        context.closePDF()
        return try require(PDFDocument(data: buffer as Data))
    }

    @MainActor func testDocumentFind() async throws {
        let owner = ReaderDocument()
        let pdf = try makePDF()
        let second = try require(try makePDF().page(at: 0))
        pdf.insert(second, at: 1)
        owner.reader.pdf = pdf
        let canvas = PDFCanvas(frame: CGRect(x: 0, y: 0, width: 500, height: 500))
        canvas.document = pdf
        owner.reader.canvas = canvas
        owner.showDocumentFind(nil)
        let request = try require(owner.reader.findRequest)
        let fieldHost = NSHostingView(rootView: DocumentFindBar(reader: owner.reader, request: request))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 540),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        fieldHost.frame = CGRect(x: 0, y: 500, width: 500, height: 40)
        window.contentView?.addSubview(canvas)
        window.contentView?.addSubview(fieldHost)
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        for _ in 0..<50 where !(window.firstResponder is NSTextView) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let field = try require(window.firstResponder as? NSTextView)
        field.insertText("RESEARCH", replacementRange: NSRange(location: NSNotFound, length: 0))
        for _ in 0..<100 where canvas.highlightedSelections?.first == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        expectEqual(canvas.highlightedSelections?.first?.string, "research")
        expect(canvas.highlightedSelections?.first?.pages.first === pdf.page(at: 0))
        field.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await Task.sleep(for: .milliseconds(50))
        expect(canvas.highlightedSelections?.first?.pages.first === second)
        expect(!owner.isDocumentEdited)
    }

    @MainActor func testSelectionAcrossScroll() throws {
        let pdf = try makePDF()
        let first = try require(pdf.page(at: 0))
        let second = try require(first.copy() as? PDFPage)
        pdf.insert(second, at: 1)
        let owner = ReaderDocument()
        owner.reader.pdf = pdf
        defer { owner.reader.cancelTranslation() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 320),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let canvas = PDFCanvas(frame: window.contentView!.bounds)
        window.contentView = canvas
        canvas.reader = owner.reader
        owner.reader.canvas = canvas
        canvas.document = pdf
        canvas.displayMode = .singlePageContinuous
        canvas.scaleFactor = 1
        window.makeKeyAndOrderFront(nil)
        canvas.layoutSubtreeIfNeeded()
        canvas.go(to: first)
        let word = try require(pdf.findString("research", withOptions: []).first).bounds(for: first)
        let start = canvas.convert(canvas.convert(NSPoint(x: word.minX + 1, y: word.midY), from: first), to: nil)
        let end = canvas.convert(canvas.convert(NSPoint(x: word.maxX - 1, y: word.midY), from: first), to: nil)
        func send(_ kind: NSEvent.EventType, _ point: NSPoint) throws {
            let event = try require(NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            NSApp.postEvent(event, atStart: true)
            NSApp.sendEvent(try require(NSApp.nextEvent(matching: NSEvent.EventTypeMask(rawValue: 1 << kind.rawValue),
                until: .distantPast, inMode: .default, dequeue: true)))
        }
        try send(.leftMouseDown, start)
        try send(.leftMouseDragged, end)
        expectEqual(canvas.currentSelection?.translationText, "research")
        // A wheel moves the clip while the pointer stays at the same window coordinates.
        let scroll = try require(canvas.documentView?.enclosingScrollView)
        let clip = scroll.contentView
        let next = clip.convert(canvas.convert(word.origin, from: second), from: canvas)
        let prev = clip.convert(canvas.convert(word.origin, from: first), from: canvas)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + next.y - prev.y))
        scroll.reflectScrolledClipView(clip)
        expectEqual(canvas.currentSelection?.pages.count, 2)
        try send(.leftMouseUp, end)
        expectEqual(owner.reader.selectedText, canvas.currentSelection?.translationText)
    }

    @MainActor func testDiscontinuousSelection() throws {
        let pdf = try makePDF()
        let first = try require(pdf.findString("Scientific research", withOptions: []).first)
        let second = try require(pdf.findString("annotation tests", withOptions: []).first)
        var combined = PDFSelection.combining([second, first, first], in: pdf)
        expectEqual(combined.translationText, "Scientific research annotation tests")
        let overlap = try require(pdf.findString("research improves", withOptions: []).first)
        combined = PDFSelection.combining([combined, overlap], in: pdf)
        expectEqual(combined.translationText, "Scientific research improves annotation tests")
        expect(!combined.translationText.contains("understanding"))
        let page = try require(pdf.page(at: 0))
        let owner = ReaderDocument()
        owner.reader.pdf = pdf
        let canvas = PDFCanvas(frame: NSRect(x: 0, y: 0, width: 800, height: 1000))
        canvas.document = pdf
        canvas.reader = owner.reader
        owner.reader.canvas = canvas
        canvas.scaleFactor = 1
        canvas.layoutSubtreeIfNeeded()
        canvas.setCurrentSelection(first, animate: false)
        func send(_ type: NSEvent.EventType, _ point: NSPoint) throws {
            let location = canvas.convert(canvas.convert(point, from: page), to: nil)
            let event = try require(NSEvent.mouseEvent(with: type, location: location,
                modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
            switch type {
            case .leftMouseDown: canvas.mouseDown(with: event)
            case .leftMouseDragged: canvas.mouseDragged(with: event)
            default: canvas.mouseUp(with: event)
            }
        }
        let bounds = second.bounds(for: page)
        try send(.leftMouseDown, NSPoint(x: bounds.minX + 1, y: bounds.midY))
        try send(.leftMouseDragged, NSPoint(x: bounds.maxX - 1, y: bounds.midY))
        try send(.leftMouseUp, NSPoint(x: bounds.maxX - 1, y: bounds.midY))
        defer { owner.reader.cancelTranslation() }
        expectEqual(owner.reader.selectedText, "Scientific research annotation tests")
        expectEqual(canvas.currentSelection?.translationText, owner.reader.selectedText)
        expect(page.annotations.isEmpty)
        let escape = try require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53))
        canvas.keyDown(with: escape)
        expect(canvas.currentSelection == nil)
        // A fresh selection replaces the accumulated source, and another document stays isolated.
        canvas.setCurrentSelection(second, animate: false)
        owner.reader.acceptSelection(canvas.currentSelection)
        expectEqual(owner.reader.selectedText, "annotation tests")
        expectEqual(ReaderDocument().reader.selectedText, "")
        let nextPage = try require(page.copy() as? PDFPage)
        pdf.insert(nextPage, at: 1)
        let secondPageText = try require(nextPage.selection(for: second.range(at: 0, on: page)))
        let acrossPages = PDFSelection.combining([secondPageText, first], in: pdf)
        expectEqual(acrossPages.translationText, "Scientific research annotation tests")
        expectEqual(acrossPages.pages.count, 2)
    }

    @MainActor func testAnnotationsRoundTripAsStandardPDF() throws {
        let pdf = try makePDF()
        let page = try require(pdf.page(at: 0))
        let owner = ReaderDocument()
        owner.reader.pdf = pdf
        let selection = try require(pdf.findString("Scientific research", withOptions: []).first)
        owner.reader.highlight(selection, color: .green)
        let note = PDFAnnotation(bounds: CGRect(x: 50, y: 430, width: 220, height: 90), forType: .freeText, withProperties: nil)
        note.contents = "中文笔记：需要验证实验结果。\nEnglish note."
        note.font = .systemFont(ofSize: 14)
        note.fontColor = .black
        note.color = .clear
        owner.reader.replaceAnnotations(removing: [], adding: [.init(page: page, annotation: note)], action: "添加笔记")
        let data = try owner.data(ofType: "PDF Document")
        let restored = try require(PDFDocument(data: data))
        let annotations = try require(restored.page(at: 0)).annotations
        expectEqual(annotations.count, 2)
        expectEqual(annotations.first(where: { $0.type == "FreeText" })?.contents, note.contents)
        expectNotNil(annotations.first(where: { $0.type == "Highlight" }))
        expect(restored.string?.contains("Scientific research") == true)
    }
    @MainActor func testAnnotationUndoRedoAndDocumentIsolation() throws {
        let first = ReaderDocument()
        let second = ReaderDocument()
        first.reader.pdf = try makePDF()
        second.reader.pdf = try makePDF()
        let page = try require(first.reader.pdf?.page(at: 0))
        let note = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 100, height: 40), forType: .freeText, withProperties: nil)
        note.contents = "Test"
        let undo = try require(first.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        first.reader.replaceAnnotations(removing: [], adding: [.init(page: page, annotation: note)], action: "添加笔记")
        undo.endUndoGrouping()
        expectEqual(page.annotations.count, 1)
        expectEqual(second.reader.pdf?.page(at: 0)?.annotations.count, 0)
        undo.undo()
        expect(page.annotations.isEmpty)
        expect(!first.isDocumentEdited)
        undo.redo()
        expectEqual(page.annotations.count, 1)
        expect(first.isDocumentEdited)
    }
    @MainActor func testMultilineHighlightAndRotatedPageSurviveSave() throws {
        let owner = ReaderDocument()
        let pdf = try makePDF()
        owner.reader.pdf = pdf
        let page = try require(pdf.page(at: 0))
        page.rotation = 90
        let selection = try require(page.selection(for: page.bounds(for: .mediaBox)))
        owner.reader.highlight(selection, color: .blue)
        let restored = try require(PDFDocument(data: require(pdf.dataRepresentation())))
        expectEqual(restored.page(at: 0)?.rotation, 90)
        expectAtLeast(restored.page(at: 0)?.annotations.count ?? 0, 2)
        for annotation in page.annotations { expect(page.bounds(for: .mediaBox).contains(annotation.bounds)) }
    }
    @MainActor func testHighlightFitsGlyphsAndLeavesLineGaps() throws {
        let owner = ReaderDocument()
        let pdf = try makePDF()
        owner.reader.pdf = pdf
        let page = try require(pdf.page(at: 0))
        let selection = try require(page.selection(for: page.bounds(for: .mediaBox)))
        let lines = selection.selectionsByLine().sorted { $0.bounds(for: page).midY > $1.bounds(for: page).midY }
        expectEqual(lines.count, 2)
        let undo = try require(owner.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        owner.reader.highlight(selection, color: .green)
        undo.endUndoGrouping()
        let highlights = page.annotations.sorted { $0.bounds.midY > $1.bounds.midY }
        expectEqual(highlights.count, 2)
        for (line, highlight) in zip(lines, highlights) {
            let original = line.bounds(for: page)
            expect(highlight.bounds.height < original.height - 1)
            expectEqual(highlight.bounds.minX, original.minX)
            expectEqual(highlight.bounds.width, original.width)
            expectEqual(highlight.quadrilateralPoints?.count, 4)
        }
        let upper = try require(highlights.first).bounds
        let lower = try require(highlights.last).bounds
        expect(upper.minY - lower.maxY > 2)
        let gap = CGRect(x: max(upper.minX, lower.minX) + 10, y: lower.maxY + 0.5,
                         width: min(upper.maxX, lower.maxX) - max(upper.minX, lower.minX) - 20,
                         height: upper.minY - lower.maxY - 1)
        func coloredPixels(in region: CGRect, annotations: [PDFAnnotation]) throws -> Int {
            let scale: CGFloat = 3
            let width = Int(ceil(region.width * scale)), height = Int(ceil(region.height * scale))
            let context = try require(CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -region.minX, y: -region.minY)
            for annotation in annotations { annotation.draw(with: .mediaBox, in: context) }
            let bytes = try require(context.data).assumingMemoryBound(to: UInt8.self)
            return (0..<(width * height)).filter { bytes[$0 * 4] < 240 || bytes[$0 * 4 + 2] < 240 }.count
        }
        try expectEqual(coloredPixels(in: gap, annotations: highlights), 0)
        let broadHighlights = lines.map { line in
            let annotation = PDFAnnotation(bounds: line.bounds(for: page), forType: .highlight, withProperties: nil)
            annotation.color = HighlightColor.green.color
            return annotation
        }
        let previouslyPaintedGap = try coloredPixels(in: gap, annotations: broadHighlights)
        expect(previouslyPaintedGap > 0)
        // Standard PDF serialization must keep the tight quads and clear gap.
        let restored = try require(PDFDocument(data: owner.data(ofType: "PDF Document")))
        let restoredAnnotations = try require(restored.page(at: 0)).annotations
        try expectEqual(coloredPixels(in: gap, annotations: restoredAnnotations), 0)
        for annotation in restoredAnnotations { expectEqual(annotation.quadrilateralPoints?.count, 4) }
        owner.reader.undo()
        expect(page.annotations.isEmpty)
        owner.reader.redo()
        expectEqual(page.annotations.count, 2)
        // Tightening highlights must not move existing underline geometry.
        undo.beginUndoGrouping()
        owner.reader.underline(selection)
        undo.endUndoGrouping()
        let underlines = page.annotations.filter { $0.type == "Underline" }.sorted { $0.bounds.midY > $1.bounds.midY }
        for (line, underline) in zip(lines, underlines) { expectEqual(underline.bounds, line.bounds(for: page)) }
    }

    @MainActor func testUnderlineSaveUndoAndMinimalMenu() throws {
        let owner = ReaderDocument()
        let pdf = try makePDF()
        owner.reader.pdf = pdf
        let page = try require(pdf.page(at: 0))
        let selection = try require(page.selection(for: page.bounds(for: .mediaBox)))
        let canvas = PDFCanvas(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        canvas.reader = owner.reader
        canvas.document = pdf
        let event = try require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        let emptyMenu = try require(canvas.menu(for: event))
        expectEqual(emptyMenu.items.map(\.title), ["复制", "高亮", "下划线"])
        expect(!emptyMenu.allowsContextMenuPlugIns)
        expect(emptyMenu.items.allSatisfy { !$0.isEnabled })
        canvas.setCurrentSelection(selection, animate: false)
        let menu = try require(canvas.menu(for: event))
        expectEqual(menu.items.map(\.title), ["复制", "高亮", "下划线"])
        expect(menu.items.allSatisfy(\.isEnabled))
        expect(menu.items.first?.submenu == nil)
        expectNotNil(menu.items.first?.action)
        NSPasteboard.general.clearContents()
        _ = canvas.perform(try require(menu.items[0].action), with: menu.items[0])
        expectEqual(NSPasteboard.general.string(forType: .string), selection.string)
        let undo = try require(owner.undoManager)
        undo.removeAllActions()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        let underlineItem = menu.items[2]
        _ = canvas.perform(try require(underlineItem.action), with: underlineItem)
        undo.endUndoGrouping()
        expectAtLeast(page.annotations.count, 2)
        expect(page.annotations.allSatisfy { $0.type == "Underline" })
        expect(canvas.currentSelection == nil)
        let restored = try require(PDFDocument(data: owner.data(ofType: "PDF Document")))
        expectEqual(restored.page(at: 0)?.annotations.count, page.annotations.count)
        expect(restored.page(at: 0)?.annotations.allSatisfy { $0.type == "Underline" } == true)
        undo.undo()
        expect(page.annotations.isEmpty)
        undo.redo()
        expectAtLeast(page.annotations.count, 2)
    }

    @MainActor func testCompactSingleUseNoteAndToolbarUndo() throws {
        let owner = ReaderDocument()
        let pdf = try makePDF()
        owner.reader.pdf = pdf
        let page = try require(pdf.page(at: 0))
        let canvas = PDFCanvas(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        canvas.reader = owner.reader
        owner.reader.canvas = canvas
        canvas.document = pdf
        canvas.scaleFactor = 1
        let undo = try require(owner.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        owner.reader.highlight(try require(pdf.findString("Scientific", withOptions: []).first), color: .green)
        undo.endUndoGrouping()
        expect(owner.reader.canUndo)
        owner.reader.setTool(.note)
        canvas.beginEditing(page: page, point: NSPoint(x: 60, y: 500), annotation: nil)
        expectEqual(owner.reader.tool, .select)
        expect(owner.reader.isEditingNote)
        expect(!owner.reader.canUndo)
        func findEditor(_ view: NSView) -> NoteTextView? {
            if let editor = view as? NoteTextView { return editor }
            return view.subviews.compactMap { findEditor($0) }.first
        }
        let text = try require(findEditor(canvas))
        let scroll = try require(text.enclosingScrollView)
        expect(scroll.frame.width <= 241)
        expect(scroll.frame.height < 40)
        expect(!text.drawsBackground)
        let textUndo = try require(text.undoManager)
        textUndo.groupsByEvent = false
        textUndo.beginUndoGrouping()
        text.insertText("笔记测试\nSecond line\nThird line", replacementRange: NSRange(location: 0, length: 0))
        textUndo.endUndoGrouping()
        expect(owner.reader.canUndo)
        expect(scroll.frame.height > 40)
        owner.reader.undo()
        expectEqual(text.string, "")
        expectEqual(page.annotations.count, 1)
        expect(owner.reader.canRedo)
        owner.reader.redo()
        expect(text.string.contains("Third line"))
        undo.beginUndoGrouping()
        canvas.finishEditing(commit: true)
        undo.endUndoGrouping()
        expect(!owner.reader.isEditingNote)
        expectEqual(owner.reader.tool, .select)
        expectEqual(page.annotations.count, 2)
        owner.reader.undo()
        expectEqual(page.annotations.count, 1)
        owner.reader.redo()
        expectEqual(page.annotations.count, 2)
    }

    @MainActor func testLiveNoteComposition() throws {
        let owner = ReaderDocument()
        let pdf = try makePDF()
        let page = try require(pdf.page(at: 0))
        let canvas = PDFCanvas(frame: NSRect(x: 0, y: 0, width: 900, height: 900))
        canvas.reader = owner.reader
        owner.reader.pdf = pdf
        canvas.document = pdf
        canvas.beginEditing(page: page, point: NSPoint(x: 60, y: 500), annotation: nil)
        defer { canvas.finishEditing(commit: false) }
        let box = try require(canvas.documentView?.subviews.compactMap { $0 as? NoteEditorBox }.first)
        let text = try require(box.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? NoteTextView }.first)
        let layout = try require(text.layoutManager)
        let container = try require(text.textContainer)
        let initial = box.textRect.size
        func checkSingleLine() {
            layout.ensureLayout(for: container)
            var lines = 0
            layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, _, _ in lines += 1 }
            expectEqual(lines, 1)
            expectEqual(box.textRect.height, initial.height)
        }
        let automatic = NSRange(location: NSNotFound, length: 0)
        text.insertText("笔记 ", replacementRange: automatic)
        var syllables = ""
        for letter in "lianxushurupinyin" {
            syllables.append(letter)
            text.setMarkedText(NSAttributedString(string: syllables),
                selectedRange: NSRange(location: syllables.utf16.count, length: 0), replacementRange: automatic)
            expect(text.hasMarkedText())
            expectEqual(text.string, "笔记 " + syllables)
            checkSingleLine()
        }
        expect(box.textRect.width > initial.width)
        text.insertText("连续输入拼音", replacementRange: automatic)
        expectEqual(text.string, "笔记 连续输入拼音")
        expect(!text.hasMarkedText())
        checkSingleLine()
    }

    @MainActor func testEditingNoteMoveAndResize() throws {
        func findEditor(_ view: NSView) -> NoteTextView? {
            if let editor = view as? NoteTextView { return editor }
            return view.subviews.compactMap { findEditor($0) }.first
        }
        func close(_ actual: NSRect, _ expected: NSRect) {
            for (a, b) in [(actual.minX, expected.minX), (actual.minY, expected.minY),
                           (actual.width, expected.width), (actual.height, expected.height)] {
                expect(abs(a - b) < 0.01)
            }
        }
        for zoom in [0.75, 1.0, 2.2, 3.0] {
            let owner = ReaderDocument()
            let pdf = try makePDF()
            owner.reader.pdf = pdf
            let page = try require(pdf.page(at: 0))
            let canvas = PDFCanvas(frame: NSRect(x: 0, y: 0, width: 2400, height: 2600))
            canvas.reader = owner.reader
            owner.reader.canvas = canvas
            canvas.document = pdf
            canvas.scaleFactor = zoom
            canvas.beginEditing(page: page, point: NSPoint(x: 80, y: 500), annotation: nil)
            let text = try require(findEditor(canvas))
            let box = try require(text.enclosingScrollView?.superview as? NoteEditorBox)
            func bounds() -> NSRect { canvas.convert(box.convert(box.textRect, to: canvas), to: page) }
            func drag(_ local: NSPoint, dx: CGFloat, dy: CGFloat) throws {
                let start = canvas.convert(box.convert(local, to: canvas), to: page)
                // The border intercepts the pointer; the text area keeps normal text editing.
                expect(canvas.hitTest(box.convert(local, to: canvas)) === box)
                for (kind, point) in [(NSEvent.EventType.leftMouseDown, start),
                                      (.leftMouseDragged, NSPoint(x: start.x + dx, y: start.y + dy)),
                                      (.leftMouseUp, NSPoint(x: start.x + dx, y: start.y + dy))] {
                    let location = canvas.convert(canvas.convert(point, from: page), to: nil)
                    let event = try require(NSEvent.mouseEvent(with: kind, location: location,
                        modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                        eventNumber: 0, clickCount: 1, pressure: 1))
                    switch kind {
                    case .leftMouseDown: box.mouseDown(with: event)
                    case .leftMouseDragged: box.mouseDragged(with: event)
                    default: box.mouseUp(with: event)
                    }
                }
            }
            let initial = bounds()
            // New notes should start compactly while remaining resizable.
            expect(abs(initial.width - 45) < 0.01)
            expect(abs(initial.height - NoteLayout.singleLineHeight(for: NoteStyle.font(ofSize: 10))) < 0.01)
            expectEqual(text.defaultParagraphStyle?.lineHeightMultiple, 1)
            expectEqual(text.defaultParagraphStyle?.lineSpacing, 0)
            expectEqual(text.defaultParagraphStyle?.paragraphSpacing, 0)
            // Even a newly created empty frame moves, without finishing the editor.
            try drag(NSPoint(x: box.moveRect.midX, y: box.moveRect.midY), dx: 30, dy: 20)
            close(bounds(), initial.offsetBy(dx: 30, dy: 20))
            expect(owner.reader.isEditingNote)
            expect(page.annotations.isEmpty)
            expect(canvas.hitTest(box.convert(NSPoint(x: box.textRect.midX, y: box.textRect.midY), to: canvas)) !== box)
            text.insertText("This note should fit on one line when widened.", replacementRange: NSRange(location: 0, length: 0))
            let autoSized = bounds()
            expect(autoSized.width > initial.width)
            expect(abs(autoSized.minX - (initial.minX + 30)) < 0.01)
            expect(abs(autoSized.height - initial.height) < 0.01)
            try drag(NSPoint(x: box.bounds.maxX - 0.5, y: box.bounds.midY), dx: initial.width - autoSized.width, dy: 0)
            let wrapped = bounds()
            expect(wrapped.height > autoSized.height)
            expect(abs(wrapped.width - initial.width) < 0.01)
            try drag(NSPoint(x: box.bounds.maxX - 0.5, y: box.bounds.midY), dx: 220, dy: 0)
            expect(abs(bounds().width - (initial.width + 220)) < 0.01)
            expect(bounds().height < wrapped.height)
            expect(abs(bounds().maxY - wrapped.maxY) < 0.01)
            let layout = try require(text.layoutManager)
            let container = try require(text.textContainer)
            layout.ensureLayout(for: container)
            var lineCount = 0
            layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, _, _ in lineCount += 1 }
            expectEqual(lineCount, 1)

            // Bottom-right controls both dimensions, and manual height survives commit.
            let wide = bounds()
            try drag(NSPoint(x: box.bounds.maxX - 0.5, y: box.bounds.minY + 0.5), dx: -60, dy: -50)
            close(bounds(), NSRect(x: wide.minX, y: wide.minY - 50, width: wide.width - 60, height: wide.height + 50))
            let resized = bounds()
            let undo = try require(owner.undoManager)
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            canvas.finishEditing(commit: true)
            undo.endUndoGrouping()
            let saved = try require(page.annotations.first)
            close(saved.bounds, resized)
            expectEqual(saved.contents, "This note should fit on one line when widened.")
            let reopened = try require(PDFDocument(data: owner.data(ofType: "PDF Document")))
            close(try require(reopened.page(at: 0)?.annotations.first).bounds, resized)

            // Geometry-only changes must save and undo even if text is unchanged.
            canvas.beginEditing(page: page, point: saved.bounds.origin, annotation: saved)
            let newText = try require(findEditor(canvas))
            let newBox = try require(newText.enclosingScrollView?.superview as? NoteEditorBox)
            let start = newBox.convert(NSPoint(x: newBox.moveRect.midX, y: newBox.moveRect.midY), to: nil)
            for (kind, location) in [(NSEvent.EventType.leftMouseDown, start),
                                      (.leftMouseDragged, NSPoint(x: start.x + 10 * zoom, y: start.y)),
                                      (.leftMouseUp, NSPoint(x: start.x + 10 * zoom, y: start.y))] {
                let event = try require(NSEvent.mouseEvent(with: kind, location: location,
                    modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                switch kind {
                case .leftMouseDown: newBox.mouseDown(with: event)
                case .leftMouseDragged: newBox.mouseDragged(with: event)
                default: newBox.mouseUp(with: event)
                }
            }
            let moved = canvas.convert(newBox.convert(newBox.textRect, to: canvas), to: page)
            expect(moved != resized)
            undo.beginUndoGrouping()
            canvas.finishEditing(commit: true)
            undo.endUndoGrouping()
            close(try require(page.annotations.first).bounds, moved)
            owner.reader.undo()
            close(try require(page.annotations.first).bounds, resized)
            owner.reader.redo()
            close(try require(page.annotations.first).bounds, moved)
            let beforeCancel = try require(page.annotations.first)
            canvas.beginEditing(page: page, point: beforeCancel.bounds.origin, annotation: beforeCancel)
            let cancelText = try require(findEditor(canvas))
            let cancelBox = try require(cancelText.enclosingScrollView?.superview as? NoteEditorBox)
            let corner = cancelBox.convert(NSPoint(x: cancelBox.bounds.maxX - 0.5, y: cancelBox.bounds.minY + 0.5), to: nil)
            for (kind, location) in [(NSEvent.EventType.leftMouseDown, corner),
                                      (.leftMouseDragged, NSPoint(x: corner.x + 2000 * zoom, y: corner.y - 2000 * zoom)),
                                      (.leftMouseUp, NSPoint(x: corner.x + 2000 * zoom, y: corner.y - 2000 * zoom))] {
                let event = try require(NSEvent.mouseEvent(with: kind, location: location,
                    modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                switch kind {
                case .leftMouseDown: cancelBox.mouseDown(with: event)
                case .leftMouseDragged: cancelBox.mouseDragged(with: event)
                default: cancelBox.mouseUp(with: event)
                }
            }
            let expanded = canvas.convert(cancelBox.convert(cancelBox.textRect, to: canvas), to: page)
            let crop = page.bounds(for: .cropBox)
            expect(abs(expanded.maxX - crop.maxX) < 0.01)
            expect(abs(expanded.minY - crop.minY) < 0.01)
            canvas.finishEditing(commit: false)
            close(beforeCancel.bounds, moved)
            expect(beforeCancel.shouldDisplay)

            canvas.beginEditing(page: page, point: NSPoint(x: crop.maxX - 60, y: crop.midY), annotation: nil)
            let edgeText = try require(findEditor(canvas))
            let edgeBox = try require(edgeText.enclosingScrollView?.superview as? NoteEditorBox)
            edgeText.insertText("输入长句时在页面右边缘自动换行", replacementRange: edgeText.selectedRange())
            let edgeBounds = canvas.convert(edgeBox.convert(edgeBox.textRect, to: canvas), to: page)
            expect(abs(edgeBounds.maxX - crop.maxX) < 0.01)
            expect(edgeBounds.height > initial.height)
            canvas.finishEditing(commit: false)
        }
    }

    @MainActor func testNoteFontSizeEditingAndPersistence() throws {
        func findEditor(_ view: NSView) -> NoteTextView? {
            if let editor = view as? NoteTextView { return editor }
            return view.subviews.compactMap { findEditor($0) }.first
        }
        let owner = ReaderDocument()
        let pdf = try makePDF()
        owner.reader.pdf = pdf
        let page = try require(pdf.page(at: 0))
        let canvas = PDFCanvas(frame: NSRect(x: 0, y: 0, width: 1000, height: 1200))
        canvas.reader = owner.reader
        owner.reader.canvas = canvas
        canvas.document = pdf
        expectEqual(owner.reader.noteFontSize, 10)
        canvas.beginEditing(page: page, point: NSPoint(x: 80, y: 500), annotation: nil)
        let text = try require(findEditor(canvas))
        expectEqual(text.font?.pointSize, 10)
        text.insertText("Hello 中文字号测试", replacementRange: NSRange(location: 0, length: 0))
        let selection = NSRange(location: 6, length: 2)
        text.setSelectedRange(selection)
        let textUndo = try require(text.undoManager)
        textUndo.groupsByEvent = false
        textUndo.beginUndoGrouping()
        owner.reader.setNoteFontSize(24)
        textUndo.endUndoGrouping()
        expectEqual(text.font?.pointSize, 24)
        expectEqual((text.typingAttributes[.font] as? NSFont)?.pointSize, 24)
        expectEqual(text.selectedRange(), selection)
        expectEqual(owner.reader.currentNoteFontSize, 24)
        expect(owner.reader.isEditingNote)
        owner.reader.undo()
        expectEqual(text.font?.pointSize, 10)
        expectEqual(owner.reader.currentNoteFontSize, 10)
        owner.reader.redo()
        expectEqual(text.font?.pointSize, 24)
        expectEqual(text.string, "Hello 中文字号测试")
        let undo = try require(owner.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        canvas.finishEditing(commit: true)
        undo.endUndoGrouping()
        let saved = try require(page.annotations.first)
        expectEqual(saved.font?.pointSize, 24)
        let restored = try require(PDFDocument(data: owner.data(ofType: "PDF Document")))
        expectEqual(restored.page(at: 0)?.annotations.first?.font?.pointSize, 24)
        // The toolbar reads the selected annotation and also changes saved notes.
        expectEqual(owner.reader.currentNoteFontSize, 24)
        undo.beginUndoGrouping()
        owner.reader.setNoteFontSize(18)
        undo.endUndoGrouping()
        expectEqual(page.annotations.first?.font?.pointSize, 18)
        expectEqual(page.annotations.first?.bounds, saved.bounds)
        owner.reader.undo()
        expectEqual(page.annotations.first?.font?.pointSize, 24)
        owner.reader.redo()
        let resized = try require(page.annotations.first)
        expectEqual(resized.font?.pointSize, 18)
        canvas.beginEditing(page: page, point: resized.bounds.origin, annotation: resized)
        expectEqual(owner.reader.currentNoteFontSize, 18)
        owner.reader.setNoteFontSize(32)
        canvas.finishEditing(commit: false)
        expectEqual(resized.font?.pointSize, 18)
        expect(resized.shouldDisplay)
        owner.reader.setNoteFontSize(.nan)
        expect(owner.reader.noteFontSize.isFinite)
    }

    @MainActor func testNoteEditorScreenSizedTargets() throws {
        for zoom in [0.2, 0.75, 1.0, 2.2, 5.0] {
            let box = NoteEditorBox(frame: .zero)
            box.setTextGeometry(frame: NSRect(x: 100, y: 200, width: 240 * zoom, height: 26 * zoom),
                                size: NSSize(width: 240, height: 26))
            let textFrame = box.convert(box.textRect, to: nil)
            expect(abs(textFrame.minX - 100) < 0.001)
            expect(abs(textFrame.minY - 200) < 0.001)
            expect(abs(textFrame.width - 240 * zoom) < 0.001)
            expect(abs(box.convert(box.moveRect, to: nil).height - 12) < 0.001)
            if case .move? = box.interaction(at: NSPoint(x: box.moveRect.midX, y: box.moveRect.midY)) {} else { fail("Header must move the note") }
            // All ten screen points of the edge target work, at every PDF zoom.
            for distance in [1.0, 5.0, 9.0] {
                let left = NSPoint(x: box.bounds.minX + distance / zoom, y: box.textRect.midY)
                if case .resize(let edges)? = box.interaction(at: left) { expectEqual(edges, .left) }
                else { fail("Left resize target missing at zoom \(zoom)") }
                let top = NSPoint(x: (box.textRect.minX + box.moveRect.minX) / 2, y: box.bounds.maxY - distance / zoom)
                if case .resize(let edges)? = box.interaction(at: top) { expectEqual(edges, .top) }
                else { fail("Top resize target missing") }
                let corner = NSPoint(x: box.bounds.maxX - distance / zoom, y: box.bounds.minY + distance / zoom)
                if case .resize(let edges)? = box.interaction(at: corner) { expectEqual(edges, [.right, .bottom]) }
                else { fail("Corner resize target missing") }
            }
            let rect = box.textRect
            let dx = min(2 / zoom, rect.width / 12), dy = min(2 / zoom, rect.height / 12)
            let innerEdges: [(NSPoint, NoteEditorBox.Edges)] = [
                (NSPoint(x: rect.minX + dx, y: rect.midY), .left),
                (NSPoint(x: rect.maxX - dx, y: rect.midY), .right)
            ]
            expect(box.interaction(at: NSPoint(x: rect.midX, y: rect.minY + dy)) == nil)
            expect(box.interaction(at: NSPoint(x: rect.midX, y: rect.maxY - dy)) == nil)
            for (point, expected) in innerEdges {
                if case .resize(let edges)? = box.interaction(at: point) { expectEqual(edges, expected) }
                else { fail("Missing inner resize target at zoom \(zoom)") }
            }
            expect(box.interaction(at: NSPoint(x: rect.midX, y: rect.midY)) == nil)
            expect(box.interaction(at: NSPoint(x: rect.minX + min(5 / zoom, rect.width / 4),
                                               y: rect.minY + min(5 / zoom, rect.height / 4))) == nil)
        }
    }

    @MainActor func testClickSavedNoteToResumeEditing() throws {
        let source = try makePDF()
        let sourcePage = try require(source.page(at: 0))
        let bounds = NSRect(x: 60, y: 460, width: 160, height: 30)
        let note = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
        note.contents = "原来的笔记"
        note.font = .systemFont(ofSize: 14)
        sourcePage.addAnnotation(note)
        // Newer markup must not intercept clicks on the saved note beneath it.
        sourcePage.addAnnotation(PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil))
        let pdf = try require(PDFDocument(data: require(source.dataRepresentation())))
        let page = try require(pdf.page(at: 0))
        let owner = ReaderDocument()
        owner.reader.pdf = pdf
        let canvas = PDFCanvas(frame: NSRect(x: 0, y: 0, width: 800, height: 1000))
        canvas.reader = owner.reader
        owner.reader.canvas = canvas
        canvas.document = pdf
        canvas.scaleFactor = 1.2
        canvas.layoutSubtreeIfNeeded()
        let undo = try require(owner.undoManager)
        undo.groupsByEvent = false
        func send(_ type: NSEvent.EventType, at point: NSPoint) throws {
            let local = canvas.convert(point, from: page)
            let location = canvas.convert(local, to: nil)
            let event = try require(NSEvent.mouseEvent(with: type, location: location,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
            switch type {
            case .leftMouseDown: canvas.mouseDown(with: event)
            case .leftMouseDragged: canvas.mouseDragged(with: event)
            default: canvas.mouseUp(with: event)
            }
        }
        func findEditor(_ view: NSView) -> NoteTextView? {
            if let editor = view as? NoteTextView { return editor }
            return view.subviews.compactMap { findEditor($0) }.first
        }
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        try send(.leftMouseDown, at: center)
        try send(.leftMouseDragged, at: NSPoint(x: center.x + 1, y: center.y))
        try send(.leftMouseUp, at: center)
        expect(owner.reader.isEditingNote)
        expectEqual(owner.reader.tool, .select)
        let editor = try require(findEditor(canvas))
        expectEqual(editor.string, "原来的笔记")
        editor.string += "，继续编辑"
        undo.beginUndoGrouping()
        canvas.finishEditing(commit: true)
        undo.endUndoGrouping()
        expectEqual(page.annotations.count, 2)
        expectEqual(page.annotations.first { $0.type == "FreeText" }?.contents, "原来的笔记，继续编辑")
        owner.reader.undo()
        expectEqual(page.annotations.first { $0.type == "FreeText" }?.contents, "原来的笔记")
        owner.reader.redo()
        let updated = try require(page.annotations.first { $0.type == "FreeText" })
        let oldBounds = updated.bounds
        let moved = NSPoint(x: center.x + 30, y: center.y + 20)
        undo.beginUndoGrouping()
        try send(.leftMouseDown, at: center)
        try send(.leftMouseDragged, at: moved)
        try send(.leftMouseUp, at: moved)
        undo.endUndoGrouping()
        expect(!owner.reader.isEditingNote)
        expectEqual(page.annotations.count, 2)
        expect(page.annotations.first { $0.type == "FreeText" }?.bounds != oldBounds)
        owner.reader.undo()
        expectEqual(page.annotations.first { $0.type == "FreeText" }?.bounds, oldBounds)
        try send(.leftMouseDown, at: center)
        try send(.leftMouseUp, at: center)
        expectEqual(findEditor(canvas)?.string, "原来的笔记，继续编辑")
        canvas.finishEditing(commit: false)
    }

    @MainActor func testMarkupContextMenuDeletesAnnotation() throws {
        for underline in [false, true] {
            let owner = ReaderDocument()
            let pdf = try makePDF()
            owner.reader.pdf = pdf
            let page = try require(pdf.page(at: 0))
            let canvas = PDFCanvas(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
            canvas.reader = owner.reader
            owner.reader.canvas = canvas
            canvas.document = pdf
            canvas.layoutSubtreeIfNeeded()
            let selection = try require(page.selection(for: page.bounds(for: .mediaBox)))
            if underline { owner.reader.underline(selection) }
            else { owner.reader.highlight(selection, color: .green) }
            let group = page.annotations
            expectAtLeast(group.count, 2)
            let annotation = try require(group.last)
            let point = canvas.convert(NSPoint(x: annotation.bounds.midX, y: annotation.bounds.midY), from: page)
            let event = try require(NSEvent.mouseEvent(with: .rightMouseDown, location: point,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
            let menu = try require(canvas.menu(for: event))
            expectEqual(menu.items.map(\.title), ["删除标记"])
            expect(canvas.reader?.selectedAnnotation === annotation)
            let undo = try require(owner.undoManager)
            undo.removeAllActions()
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            _ = canvas.perform(try require(menu.items[0].action), with: menu.items[0])
            undo.endUndoGrouping()
            expect(page.annotations.isEmpty)
            owner.reader.undo()
            expectEqual(page.annotations.count, group.count)
            expect(group.allSatisfy { original in page.annotations.contains { $0 === original } })
            owner.reader.redo()
            expect(page.annotations.isEmpty)
        }
    }

    @MainActor func testMarkupGroupsSurviveSaveAcrossPages() throws {
        for underline in [false, true] {
            let owner = ReaderDocument()
            let pdf = try makePDF()
            let first = try require(pdf.page(at: 0))
            let second = try require(first.copy() as? PDFPage)
            pdf.insert(second, at: 1)
            owner.reader.pdf = pdf
            let selection = try require(first.selection(for: first.bounds(for: .mediaBox)))
            selection.add(try require(second.selection(for: second.bounds(for: .mediaBox))))
            if underline { owner.reader.underline(selection) }
            else { owner.reader.highlight(selection, color: .green) }
            let groupCounts = [first.annotations.count, second.annotations.count]
            expect(groupCounts.allSatisfy { $0 >= 2 })
            // A separate operation overlaps exactly, with the same color and subtype.
            let otherSelection = try require(pdf.findString("Scientific research", withOptions: []).first)
            if underline { owner.reader.underline(otherSelection) }
            else { owner.reader.highlight(otherSelection, color: .green) }
            let otherCount = first.annotations.count - groupCounts[0]
            expectAtLeast(otherCount, 1)

            let reopened = ReaderDocument()
            try reopened.read(from: owner.data(ofType: "PDF Document"), ofType: "PDF Document")
            let savedPDF = try require(reopened.reader.pdf)
            let savedFirst = try require(savedPDF.page(at: 0))
            let savedSecond = try require(savedPDF.page(at: 1))
            let unrelated = Array(savedFirst.annotations.suffix(otherCount))
            let undo = try require(reopened.undoManager)
            undo.groupsByEvent = false
            reopened.reader.selectedAnnotation = try require(savedSecond.annotations.last)
            undo.beginUndoGrouping()
            reopened.reader.deleteSelectedAnnotation()
            undo.endUndoGrouping()
            expect(savedSecond.annotations.isEmpty)
            expectEqual(savedFirst.annotations.count, otherCount)
            expect(unrelated.allSatisfy { original in savedFirst.annotations.contains { $0 === original } })
            reopened.reader.undo()
            expectEqual(savedFirst.annotations.count, groupCounts[0] + otherCount)
            expectEqual(savedSecond.annotations.count, groupCounts[1])
            reopened.reader.redo()
            expectEqual(savedFirst.annotations.count, otherCount)
            expect(savedSecond.annotations.isEmpty)
        }
    }

    @MainActor func testUngroupedAnnotationsDeleteIndividually() throws {
        for type: PDFAnnotationSubtype in [.highlight, .underline, .freeText] {
            let owner = ReaderDocument()
            let pdf = try makePDF()
            owner.reader.pdf = pdf
            let page = try require(pdf.page(at: 0))
            let bounds = NSRect(x: 50, y: 600, width: 200, height: 20)
            let first = PDFAnnotation(bounds: bounds, forType: type, withProperties: nil)
            let second = PDFAnnotation(bounds: bounds, forType: type, withProperties: nil)
            page.addAnnotation(first)
            page.addAnnotation(second)
            owner.reader.selectedAnnotation = first
            owner.reader.deleteSelectedAnnotation()
            expectEqual(page.annotations.count, 1)
            expect(page.annotations.first === second)
        }
    }

    @MainActor func testRecolorSavedMarkupGroups() throws {
        for underline in [false, true] {
            let owner = ReaderDocument()
            let pdf = try makePDF()
            let first = try require(pdf.page(at: 0))
            let second = try require(first.copy() as? PDFPage)
            pdf.insert(second, at: 1)
            owner.reader.pdf = pdf
            let selection = try require(first.selection(for: first.bounds(for: .mediaBox)))
            selection.add(try require(second.selection(for: second.bounds(for: .mediaBox))))
            if underline { owner.reader.underline(selection) }
            else { owner.reader.highlight(selection, color: .green) }
            let groupCount = first.annotations.count
            let overlapping = try require(pdf.findString("Scientific research", withOptions: []).first)
            if underline { owner.reader.underline(overlapping) }
            else { owner.reader.highlight(overlapping, color: .green) }

            let restored = ReaderDocument()
            try restored.read(from: owner.data(ofType: "PDF Document"), ofType: "PDF Document")
            let savedPDF = try require(restored.reader.pdf)
            let page = try require(savedPDF.page(at: 0))
            let next = try require(savedPDF.page(at: 1))
            let group = Array(page.annotations.prefix(groupCount)) + next.annotations
            let other = Array(page.annotations.dropFirst(groupCount))
            let originalBounds = group.map(\.bounds)
            let originalQuads = group.map(\.quadrilateralPoints)
            let canvas = PDFCanvas(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
            canvas.reader = restored.reader
            restored.reader.canvas = canvas
            canvas.document = savedPDF
            canvas.layoutSubtreeIfNeeded()
            let annotation = try require(group.prefix(groupCount).last)
            let point = canvas.convert(NSPoint(x: annotation.bounds.midX, y: annotation.bounds.midY), from: page)
            let event = try require(NSEvent.mouseEvent(with: .rightMouseDown, location: point,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
            let menu = try require(canvas.menu(for: event))
            expectEqual(menu.items.map(\.title), ["删除标记"])
            let undo = try require(restored.undoManager)
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            restored.reader.selectHighlight(.blue)
            undo.endUndoGrouping()
            let recolored = page.annotations.filter { candidate in !other.contains { $0 === candidate } } + next.annotations
            expectEqual(recolored.count, group.count)
            expect(recolored.allSatisfy { HighlightColor.blue.matches($0.color) })
            expect(other.allSatisfy { HighlightColor.green.matches($0.color) })
            expectEqual(recolored.map(\.bounds), originalBounds)
            expectEqual(recolored.map(\.quadrilateralPoints), originalQuads)
            expect(restored.isDocumentEdited)
            restored.reader.undo()
            expect(group.allSatisfy { original in original.page != nil && HighlightColor.green.matches(original.color) })
            restored.reader.redo()
            expect(recolored.allSatisfy { $0.page != nil && HighlightColor.blue.matches($0.color) })
            let savedAgain = try require(PDFDocument(data: restored.data(ofType: "PDF Document")))
            let all = (0..<savedAgain.pageCount).flatMap { savedAgain.page(at: $0)?.annotations ?? [] }
            expectEqual(all.filter { HighlightColor.blue.matches($0.color) }.count, group.count)
            expectEqual(all.filter { HighlightColor.green.matches($0.color) }.count, other.count)

            undo.removeAllActions()
            // The primary workflow is a page click followed by a toolbar swatch.
            canvas.setCurrentSelection(try require(page.selection(for: page.bounds(for: .mediaBox))), animate: false)
            for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let click = try require(NSEvent.mouseEvent(with: kind, location: point,
                    modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1))
                if kind == .leftMouseDown { canvas.mouseDown(with: click) }
                else { canvas.mouseUp(with: click) }
            }
            expect(restored.reader.selectedAnnotation === recolored[groupCount - 1])
            expect(canvas.currentSelection == nil)
            expectEqual(restored.reader.currentHighlightColor, .blue)
            restored.reader.selectHighlight(.blue)
            expect(!undo.canUndo) // Choosing the current color is not a document edit.
            undo.beginUndoGrouping()
            restored.reader.selectHighlight(.orange)
            undo.endUndoGrouping()
            expectEqual(restored.reader.currentHighlightColor, .orange)
            expectEqual((page.annotations + next.annotations).filter { HighlightColor.orange.matches($0.color) }.count, group.count)
            restored.reader.undo()
            restored.reader.selectedAnnotation = recolored.first
            restored.reader.locked = true
            restored.reader.selectHighlight(.orange)
            expect(recolored.allSatisfy { HighlightColor.blue.matches($0.color) })
            expect(!undo.canUndo)
            restored.reader.locked = false
            // A drag that starts inside a highlight still selects PDF text.
            let end = NSPoint(x: point.x + 50, y: point.y)
            for (kind, location, count) in [(NSEvent.EventType.leftMouseDown, point, 1),
                                            (.leftMouseDragged, end, 0), (.leftMouseUp, end, 1)] {
                let event = try require(NSEvent.mouseEvent(with: kind, location: location,
                    modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                    eventNumber: 0, clickCount: count, pressure: 1))
                switch kind {
                case .leftMouseDown: canvas.mouseDown(with: event)
                case .leftMouseDragged: canvas.mouseDragged(with: event)
                default: canvas.mouseUp(with: event)
                }
            }
            expect(restored.reader.selectedAnnotation == nil)
            expect(!(canvas.currentSelection?.string ?? "").isEmpty)
            restored.reader.selectHighlight(.orange)
            expect(recolored.allSatisfy { HighlightColor.blue.matches($0.color) })
            expect(!undo.canUndo)
            restored.reader.cancelTranslation()
        }

        // Legacy annotations without a LiRe group only change individually.
        let owner = ReaderDocument()
        owner.reader.pdf = try makePDF()
        let page = try require(owner.reader.pdf?.page(at: 0))
        let bounds = NSRect(x: 50, y: 600, width: 100, height: 20)
        let legacy = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
        let other = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
        legacy.color = HighlightColor.green.color
        other.color = HighlightColor.green.color
        page.addAnnotation(legacy)
        page.addAnnotation(other)
        owner.reader.selectedAnnotation = legacy
        owner.reader.selectHighlight(.orange)
        expectEqual(page.annotations.count, 2)
        expectEqual(page.annotations.filter { HighlightColor.orange.matches($0.color) }.count, 1)
        expectEqual(other.color, HighlightColor.green.color)
    }

    @MainActor func testHighlightColorsRenderOpaqueAndUnchangedAcrossSave() throws {
        let owner = ReaderDocument()
        let pdf = try makePDF()
        owner.reader.pdf = pdf
        let page = try require(pdf.page(at: 0))

        func components(_ color: NSColor) -> [CGFloat] {
            guard let srgb = color.usingColorSpace(.sRGB) else { return [] }
            return [srgb.redComponent, srgb.greenComponent, srgb.blueComponent, srgb.alphaComponent]
        }

        func rgb255(_ color: NSColor) -> [Int] {
            components(color).prefix(3).map { Int(($0 * 255).rounded()) }
        }

        func dominantTint(_ annotation: PDFAnnotation) throws -> [Int] {
            let scale: CGFloat = 4
            let bounds = annotation.bounds.insetBy(dx: -2, dy: -2)
            let width = Int(ceil(bounds.width * scale)), height = Int(ceil(bounds.height * scale))
            let context = try require(CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            annotation.draw(with: .mediaBox, in: context)
            let bytes = try require(context.data).assumingMemoryBound(to: UInt8.self)
            var counts: [Int: Int] = [:]
            for pixel in 0..<(width * height) {
                let index = pixel * 4
                let r = Int(bytes[index]), g = Int(bytes[index + 1]), b = Int(bytes[index + 2])
                guard max(r, g, b) - min(r, g, b) > 8 else { continue }
                counts[r << 16 | g << 8 | b, default: 0] += 1
            }
            let key = try require(counts.max { $0.value < $1.value }?.key)
            return [(key >> 16) & 0xff, (key >> 8) & 0xff, key & 0xff]
        }

        func expectColor(_ actual: [Int], _ expected: [Int]) {
            expectEqual(actual.count, 3)
            expectEqual(expected.count, 3)
            for (actual, expected) in zip(actual, expected) {
                expect(abs(actual - expected) <= 1)
            }
        }

        for color in HighlightColor.allCases {
            let annotation = PDFAnnotation(bounds: CGRect(x: 50, y: 500, width: 160, height: 20),
                                           forType: .highlight, withProperties: nil)
            annotation.color = color.color
            page.addAnnotation(annotation)

            let palette = components(color.color)
            expectEqual(palette.count, 4)
            expectEqual(palette.last, 1)
            let expectedRenderedTint = rgb255(color.color)
            let liveTint = try dominantTint(annotation)
            expectColor(liveTint, expectedRenderedTint)

            let saved = try require(PDFDocument(data: owner.data(ofType: "PDF Document")))
            let savedAnnotation = try require(saved.page(at: 0)?.annotations.first)
            expect(color.matches(savedAnnotation.color))
            let savedPalette = components(savedAnnotation.color)
            expectEqual(savedPalette.count, palette.count)
            for (actual, expected) in zip(savedPalette, palette) {
                expect(abs(actual - expected) < 0.005)
            }
            expectColor(try dominantTint(savedAnnotation), liveTint)
            page.removeAnnotation(annotation)
        }
    }

    @MainActor func testHighlightColorConfiguresAndRecolorsMarkup() throws {
        let owner = ReaderDocument()
        let pdf = try makePDF()
        owner.reader.pdf = pdf
        let page = try require(pdf.page(at: 0))
        let canvas = PDFCanvas(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        canvas.reader = owner.reader
        owner.reader.canvas = canvas
        canvas.document = pdf
        let selection = try require(pdf.findString("Scientific research", withOptions: []).first)
        let event = try require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        let undo = try require(owner.undoManager)
        undo.groupsByEvent = false
        expectEqual(owner.reader.highlightColor, .green)
        for (itemIndex, annotationType) in [(1, "Highlight"), (2, "Underline")] {
            for color in HighlightColor.allCases {
                canvas.setCurrentSelection(selection, animate: false)
                owner.reader.selectHighlight(color)
                expectEqual(owner.reader.tool, .select)
                expectEqual(owner.reader.highlightColor, color)
                expectEqual(canvas.currentSelection?.string, selection.string)
                expect(page.annotations.isEmpty)
                expect(!undo.canUndo)
                let menu = try require(canvas.menu(for: event))
                let item = menu.items[itemIndex]
                expectEqual(item.title, itemIndex == 1 ? "高亮" : "下划线")
                expect(item.submenu == nil)
                undo.beginUndoGrouping()
                _ = canvas.perform(try require(item.action), with: item)
                undo.endUndoGrouping()
                let annotation = try require(page.annotations.first)
                expectEqual(annotation.type, annotationType)
                expectEqual(annotation.color, color.color)
                expect(canvas.currentSelection == nil)
                owner.reader.selectedAnnotation = annotation
                let replacementColor: HighlightColor = color == .blue ? .orange : .blue
                undo.beginUndoGrouping()
                owner.reader.selectHighlight(replacementColor)
                undo.endUndoGrouping()
                expectEqual(page.annotations.count, 1)
                expectEqual(page.annotations.first?.color, replacementColor.color)
                expect(owner.reader.selectedAnnotation === page.annotations.first)
                expectEqual(owner.reader.currentHighlightColor, replacementColor)
                owner.reader.undo()
                expectEqual(page.annotations.first?.color, color.color)
                owner.reader.redo()
                expectEqual(page.annotations.first?.color, replacementColor.color)
                owner.reader.undo()
                owner.reader.undo()
                expect(page.annotations.isEmpty)
                owner.reader.redo()
                expectEqual(page.annotations.first?.color, color.color)
                owner.reader.undo()
                undo.removeAllActions()
            }
        }
        owner.reader.setTool(.note)
        owner.reader.selectHighlight(.orange)
        expectEqual(owner.reader.tool, .note)
        expect(page.annotations.isEmpty)
    }

    @MainActor func testNoteEditingVisibilityAndStableLayout() throws {
        func findEditor(_ view: NSView) -> NoteTextView? {
            if let editor = view as? NoteTextView { return editor }
            return view.subviews.compactMap { findEditor($0) }.first
        }
        func expectClose(_ actual: NSRect, _ expected: NSRect) {
            for (a, b) in [(actual.minX, expected.minX), (actual.minY, expected.minY),
                           (actual.width, expected.width), (actual.height, expected.height)] {
                expect(abs(a - b) < 0.001)
            }
        }
        for scale in [0.75, 1.0, 1.5, 2.0] {
            let owner = ReaderDocument()
            let pdf = try makePDF()
            owner.reader.pdf = pdf
            let page = try require(pdf.page(at: 0))
            let canvas = PDFCanvas(frame: NSRect(x: 0, y: 0, width: 800, height: 1000))
            canvas.reader = owner.reader
            owner.reader.canvas = canvas
            canvas.document = pdf
            canvas.scaleFactor = scale
            canvas.beginEditing(page: page, point: NSPoint(x: 80, y: 500), annotation: nil)
            let editor = try require(findEditor(canvas))
            expectEqual(editor.font?.pointSize, 10)
            expectEqual(editor.textContainerOrigin.x, editor.textContainerInset.width)
            expectEqual(editor.textContainerOrigin.y, editor.textContainerInset.height)
            editor.string = "  Hello 中文笔记"
            editor.didChangeText()
            let box = try require(editor.enclosingScrollView?.superview as? NoteEditorBox)
            let before = canvas.convert(box.convert(box.textRect, to: canvas), to: page)
            canvas.finishEditing(commit: true)
            let saved = try require(page.annotations.first)
            expectClose(saved.bounds, before)
            expectEqual(saved.contents, "  Hello 中文笔记")
            expect(saved.shouldDisplay)
            canvas.beginEditing(page: page, point: saved.bounds.origin, annotation: saved)
            expect(!saved.shouldDisplay)
            expectEqual(page.annotations.count, 1)
            expectEqual(findEditor(canvas)?.string, saved.contents)
            canvas.finishEditing(commit: false)
            expect(saved.shouldDisplay)
            expectClose(saved.bounds, before)
            canvas.beginEditing(page: page, point: saved.bounds.origin, annotation: saved)
            canvas.finishEditing(commit: true)
            expect(saved.shouldDisplay)
            expect(page.annotations.first === saved)
            canvas.beginEditing(page: page, point: saved.bounds.origin, annotation: saved)
            let editing = try require(findEditor(canvas))
            editing.string += " edited"
            editing.didChangeText()
            let updatedBox = try require(editing.enclosingScrollView?.superview as? NoteEditorBox)
            let updatedBounds = canvas.convert(updatedBox.convert(updatedBox.textRect, to: canvas), to: page)
            let restored = try require(PDFDocument(data: owner.data(ofType: "PDF Document")))
            let restoredNote = try require(restored.page(at: 0)?.annotations.first)
            expect(restoredNote.shouldDisplay)
            expectEqual(restoredNote.contents, "  Hello 中文笔记 edited")
            let committed = try require(page.annotations.first)
            expectClose(committed.bounds, updatedBounds)
            expect(abs(committed.bounds.minX - before.minX) < 0.001)
            expect(abs(committed.bounds.maxY - before.maxY) < 0.001)
            expect(saved.shouldDisplay)
            expect(committed.shouldDisplay)
        }
    }

    @MainActor func testNoteTextMatchesPDFRendering() throws {
        let size: CGFloat = 240
        let resolution: CGFloat = 2
        let pixels = Int(size * resolution)
        func inkBounds(_ draw: (CGContext) -> Void) throws -> NSRect {
            let context = try require(CGContext(data: nil, width: pixels, height: pixels,
                bitsPerComponent: 8, bytesPerRow: pixels * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
            context.scaleBy(x: resolution, y: resolution)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            draw(context)
            NSGraphicsContext.restoreGraphicsState()
            let data = try require(context.data).assumingMemoryBound(to: UInt8.self)
            var left = pixels, top = pixels, right = 0, bottom = 0
            for y in 0..<pixels { for x in 0..<pixels where data[(y * pixels + x) * 4] < 128 {
                left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
            } }
            return NSRect(x: left, y: top, width: right - left, height: bottom - top)
        }
        for fontSize in [10.0, 12.0, 14.0, 18.0, 24.0] {
            for content in ["Hello 中文笔记", "Hello note\n第二行笔记"] {
                let font = NoteStyle.font(ofSize: fontSize)
                let native = try inkBounds { context in
                    let note = PDFAnnotation(bounds: NSRect(x: 0, y: 0, width: size, height: size), forType: .freeText, withProperties: nil)
                    note.contents = content; note.font = font; note.fontColor = .black; note.color = .clear
                    let border = PDFBorder(); border.lineWidth = 0; note.border = border
                    note.draw(with: .cropBox, in: context)
                }
                let editing = try inkBounds { context in
                    context.translateBy(x: 0, y: size); context.scaleBy(x: 1, y: -1)
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                    let inset = NoteLayout.inset(for: font)
                    let storage = NSTextStorage(string: content, attributes: [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: NoteLayout.nativeParagraph(for: font)])
                    let layout = NSLayoutManager()
                    let container = NSTextContainer(containerSize: NSSize(width: size - inset.width * 2, height: size))
                    container.lineFragmentPadding = 0
                    storage.addLayoutManager(layout); layout.addTextContainer(container)
                    layout.drawGlyphs(forGlyphRange: layout.glyphRange(for: container), at: NSPoint(x: inset.width, y: inset.height))
                }
                if abs(native.maxY - editing.maxY) > resolution { print("Layout mismatch \(fontSize) \(content.debugDescription): native=\(native) editor=\(editing)") }
                expect(abs(native.minX - editing.minX) <= 1)
                expect(abs(native.minY - editing.minY) <= 1)
                // Font fallback can round subsequent line heights by one PDF point.
                expect(abs(native.maxY - editing.maxY) <= resolution)
                expect(abs(native.maxX - editing.maxX) <= 1)
            }
        }
    }

    @MainActor func testFixedNoteStyleAndExistingNoteConversion() throws {
        func findEditor(_ view: NSView) -> NoteTextView? {
            if let editor = view as? NoteTextView { return editor }
            return view.subviews.compactMap { findEditor($0) }.first
        }
        func assertStyle(_ font: NSFont?, _ color: NSColor?) {
            expectEqual(font?.fontName, "HannotateSC-W5")
            expectEqual(color?.usingColorSpace(.sRGB), NoteStyle.color.usingColorSpace(.sRGB))
        }
        let owner = ReaderDocument()
        let pdf = try makePDF()
        owner.reader.pdf = pdf
        let page = try require(pdf.page(at: 0))
        let canvas = PDFCanvas(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        canvas.reader = owner.reader
        owner.reader.canvas = canvas
        canvas.document = pdf
        let undo = try require(owner.undoManager)
        undo.groupsByEvent = false
        canvas.beginEditing(page: page, point: NSPoint(x: 70, y: 500), annotation: nil)
        let text = try require(findEditor(canvas))
        assertStyle(text.font, text.textColor)
        text.insertText("中文笔记 Hello", replacementRange: NSRange(location: 0, length: 0))
        assertStyle(text.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont,
                    text.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        undo.beginUndoGrouping()
        canvas.finishEditing(commit: true)
        undo.endUndoGrouping()
        let saved = try require(page.annotations.first)
        assertStyle(saved.font, saved.fontColor)
        let restored = try require(PDFDocument(data: owner.data(ofType: "PDF Document")))
        let restoredNote = try require(restored.page(at: 0)?.annotations.first)
        // PDFKit may prefix an embedded subset font name during serialization.
        expect(restoredNote.font?.fontName.contains("HannotateSC-W5") == true)
        expectEqual(restoredNote.fontColor?.usingColorSpace(.sRGB), NoteStyle.color.usingColorSpace(.sRGB))
        expectEqual(restoredNote.contents, "中文笔记 Hello")

        let old = PDFAnnotation(bounds: NSRect(x: 70, y: 400, width: 160, height: 35), forType: .freeText, withProperties: nil)
        old.contents = "Existing note"; old.font = .systemFont(ofSize: 18); old.fontColor = .black
        page.addAnnotation(old)
        canvas.beginEditing(page: page, point: old.bounds.origin, annotation: old)
        assertStyle(findEditor(canvas)?.font, findEditor(canvas)?.textColor)
        canvas.finishEditing(commit: false)
        expect(page.annotations.contains { $0 === old })
        expectEqual(old.fontColor?.usingColorSpace(.sRGB), NSColor.black.usingColorSpace(.sRGB))
        canvas.beginEditing(page: page, point: old.bounds.origin, annotation: old)
        undo.beginUndoGrouping()
        canvas.finishEditing(commit: true)
        undo.endUndoGrouping()
        let converted = try require(page.annotations.first { $0.contents == old.contents })
        assertStyle(converted.font, converted.fontColor)
        expectEqual(converted.font?.pointSize, 18)
        expectEqual(converted.bounds.minX, old.bounds.minX)
        expectEqual(converted.bounds.maxY, old.bounds.maxY)
        undo.undo()
        expect(page.annotations.contains { $0 === old })
        expectEqual(old.fontColor?.usingColorSpace(.sRGB), NSColor.black.usingColorSpace(.sRGB))
        undo.redo()
        expect(page.annotations.contains { $0 === converted })
    }

    @MainActor func testEmptyNoteDeletion() throws {
        func findEditor(_ view: NSView) -> NoteTextView? {
            if let editor = view as? NoteTextView { return editor }
            return view.subviews.compactMap { findEditor($0) }.first
        }
        func deleteKey(_ code: UInt16) throws -> NSEvent {
            try require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil,
                characters: code == 51 ? "\u{7f}" : "\u{f728}",
                charactersIgnoringModifiers: code == 51 ? "\u{7f}" : "\u{f728}",
                isARepeat: false, keyCode: code))
        }
        let owner = ReaderDocument()
        let pdf = try makePDF()
        owner.reader.pdf = pdf
        let page = try require(pdf.page(at: 0))
        let canvas = PDFCanvas(frame: NSRect(x: 0, y: 0, width: 800, height: 1000))
        canvas.reader = owner.reader
        owner.reader.canvas = canvas
        canvas.document = pdf
        let undo = try require(owner.undoManager)
        undo.groupsByEvent = false
        let origin = NSPoint(x: 70, y: 500)
        // New empty frames disappear without modifying the document, either on
        // commit (the outside-click path) or an additional delete key press.
        for code in [UInt16(0), 51, 117] {
            owner.reader.setTool(.note)
            canvas.beginEditing(page: page, point: origin, annotation: nil)
            expectEqual(owner.reader.tool, .select)
            if code == 0 { canvas.finishEditing(commit: true) }
            else { try require(findEditor(canvas)).keyDown(with: deleteKey(code)) }
            expect(page.annotations.isEmpty)
            expect(!owner.reader.isEditingNote)
            expect(!owner.isDocumentEdited)
            expect(!undo.canUndo)
        }
        let original = PDFAnnotation(bounds: NSRect(x: 70, y: 460, width: 160, height: 30), forType: .freeText, withProperties: nil)
        original.contents = "A"; original.font = NoteStyle.font(ofSize: 18); original.fontColor = NoteStyle.color
        page.addAnnotation(original)
        for code in [UInt16(0), 51, 117] {
            canvas.beginEditing(page: page, point: origin, annotation: original)
            let editor = try require(findEditor(canvas))
            editor.setSelectedRange(NSRange(location: code == 117 ? 0 : 1, length: 0))
            editor.keyDown(with: try deleteKey(code == 117 ? 117 : 51))
            // Removing the last character alone leaves the editor open for typing.
            expectEqual(editor.string, "")
            expect(owner.reader.isEditingNote)
            expect(page.annotations.first === original)
            undo.beginUndoGrouping()
            if code == 0 { canvas.finishEditing(commit: true) }
            else { editor.keyDown(with: try deleteKey(code)) }
            undo.endUndoGrouping()
            expect(!owner.reader.isEditingNote)
            expectEqual(owner.reader.tool, .select)
            expect(page.annotations.isEmpty)
            let saved = try require(PDFDocument(data: owner.data(ofType: "PDF Document")))
            expect(saved.page(at: 0)?.annotations.isEmpty == true)
            undo.undo()
            expect(page.annotations.first === original)
            expectEqual(original.contents, "A")
            expect(original.shouldDisplay)
            undo.redo()
            expect(page.annotations.isEmpty)
            undo.undo()
            undo.removeAllActions()
        }
        // Escape still cancels clearing a note, restoring the existing content.
        canvas.beginEditing(page: page, point: origin, annotation: original)
        let editor = try require(findEditor(canvas))
        editor.string = ""; editor.didChangeText()
        canvas.finishEditing(commit: false)
        expect(page.annotations.first === original)
        expectEqual(original.contents, "A")
        expect(original.shouldDisplay)
    }

    @MainActor func testZoomPercentageInput() throws {
        let owner = ReaderDocument()
        let canvas = PDFCanvas(frame: NSRect(x: 0, y: 0, width: 800, height: 1000))
        canvas.document = try makePDF()
        canvas.minScaleFactor = 0.2
        canvas.maxScaleFactor = 5
        owner.reader.canvas = canvas
        canvas.reader = owner.reader
        for (input, expected) in [("125", 1.25), (" 150% ", 1.5), ("125.5％", 1.255),
                                  ("1", 0.2), ("9999", 5.0)] {
            expect(owner.reader.setZoomPercentage(input))
            expect(abs(canvas.scaleFactor - expected) < 0.0001)
            expectEqual(owner.reader.zoom, canvas.scaleFactor)
            expect(!canvas.autoScales)
        }
        for input in ["", "abc", "0", "-10", "nan", "inf", "10%%"] {
            let previous = canvas.scaleFactor
            expect(!owner.reader.setZoomPercentage(input))
            expectEqual(canvas.scaleFactor, previous)
        }
    }

}
