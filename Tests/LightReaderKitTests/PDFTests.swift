import AppKit
import PDFKit
import CoreText
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
        expectEqual(emptyMenu.items.map(\.title), ["高亮", "下划线"])
        expect(!emptyMenu.allowsContextMenuPlugIns)
        expect(emptyMenu.items.allSatisfy { !$0.isEnabled })
        canvas.setCurrentSelection(selection, animate: false)
        let menu = try require(canvas.menu(for: event))
        expectEqual(menu.items.map(\.title), ["高亮", "下划线"])
        expect(menu.items.allSatisfy(\.isEnabled))
        expect(menu.items.first?.submenu == nil)
        expectNotNil(menu.items.first?.action)
        let undo = try require(owner.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        let underlineItem = menu.items[1]
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
        let box = try require(text.enclosingScrollView?.superview)
        expect(box.frame.width <= 161)
        expect(box.frame.height < 40)
        expect(!text.drawsBackground)
        let textUndo = try require(text.undoManager)
        textUndo.groupsByEvent = false
        textUndo.beginUndoGrouping()
        text.insertText("笔记测试\nSecond line\nThird line", replacementRange: NSRange(location: 0, length: 0))
        textUndo.endUndoGrouping()
        expect(owner.reader.canUndo)
        expect(box.frame.height > 40)
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

    @MainActor func testHighlightColorOnlyConfiguresContextMenu() throws {
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
        for (itemIndex, annotationType) in [(0, "Highlight"), (1, "Underline")] {
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
                expectEqual(item.title, itemIndex == 0 ? "高亮" : "下划线")
                expect(item.submenu == nil)
                undo.beginUndoGrouping()
                _ = canvas.perform(try require(item.action), with: item)
                undo.endUndoGrouping()
                let annotation = try require(page.annotations.first)
                expectEqual(annotation.type, annotationType)
                expectEqual(annotation.color, color.color)
                expect(canvas.currentSelection == nil)
                owner.reader.selectedAnnotation = annotation
                owner.reader.selectHighlight(color == .blue ? .orange : .blue)
                expect(page.annotations.first === annotation)
                expectEqual(annotation.color, color.color)
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
            expectEqual(editor.font?.pointSize, 14)
            expectEqual(editor.textContainerOrigin.x, editor.textContainerInset.width)
            expectEqual(editor.textContainerOrigin.y, editor.textContainerInset.height)
            editor.string = "  Hello 中文笔记"
            editor.didChangeText()
            let box = try require(editor.enclosingScrollView?.superview)
            let before = canvas.convert(box.frame, to: page)
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
            let updatedBox = try require(editing.enclosingScrollView?.superview)
            let updatedBounds = canvas.convert(updatedBox.frame, to: page)
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
        for fontSize in [10.0, 14.0, 18.0, 24.0] {
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
                    let storage = NSTextStorage(string: content, attributes: [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: NoteLayout.paragraph(for: font)])
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
