import AppKit
import PDFKit
import SwiftUI

struct PDFCanvasHost: NSViewRepresentable {
    @ObservedObject var state: ReaderState
    func makeNSView(context: Context) -> PDFCanvas {
        let view = PDFCanvas(frame: .zero)
        view.registerForDraggedTypes([.fileURL])
        view.reader = state
        state.canvas = view
        view.document = state.pdf
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        view.backgroundColor = NSColor(srgbRed: 0.91, green: 0.92, blue: 0.90, alpha: 1)
        view.minScaleFactor = 0.2
        view.maxScaleFactor = 5
        view.autoScales = true
        view.startObserving()
        DispatchQueue.main.async {
            state.pageCount = state.pdf?.pageCount ?? 0
            state.locked = state.pdf?.isLocked ?? false
            if let position = ReadingHistory.shared.position(for: state.owner?.fileURL), let pdf = state.pdf,
               let page = pdf.page(at: min(position.page, max(0, pdf.pageCount - 1))) {
                if !position.autoScale { view.autoScales = false; view.scaleFactor = position.scale }
                view.go(to: page)
            }
            view.publishPosition()
        }
        return view
    }
    func updateNSView(_ nsView: PDFCanvas, context: Context) {}
    static func dismantleNSView(_ nsView: PDFCanvas, coordinator: ()) {
        nsView.finishEditing(commit: true)
        nsView.reader?.rememberPosition()
        nsView.stopObserving()
    }
}

final class NoteTextView: NSTextView {
    private let textUndoManager = UndoManager()
    override var undoManager: UndoManager? { textUndoManager }
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?(); return }
        if event.keyCode == 36 && event.modifierFlags.contains(.command) { onCommit?(); return }
        // Delete the frame only on a subsequent key press after the last character
        // is gone. Let the input method finish any marked text first.
        if [51, 117].contains(event.keyCode), string.isEmpty, !hasMarkedText(), let onCommit {
            onCommit()
            return
        }
        super.keyDown(with: event)
    }
}

final class PDFCanvas: PDFView {
    weak var reader: ReaderState?
    private var observers: [NSObjectProtocol] = []
    private var selectionWork: DispatchWorkItem?
    private var editorBox: NSView?
    private var editor: NoteTextView?
    private var editingPage: PDFPage?
    private var editingBounds: NSRect = .zero
    private var minimumEditorHeight: CGFloat = 28
    var noteUndoManager: UndoManager? { editor?.undoManager }
    private var editingOriginal: PDFAnnotation?
    private var originalShouldDisplay = true
    private var pressedAnnotation: PDFAnnotation?
    private var dragStart: NSPoint?
    private var originalBounds: NSRect?
    private var didDragAnnotation = false
    private var draggingSelection = false
    private var suppressSelection = false
    private var editingWasDirty = false
    private var textObserver: NSObjectProtocol?

    override var acceptsFirstResponder: Bool { true }
    override var undoManager: UndoManager? { reader?.owner?.undoManager }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        PDFFileDrop.urls(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !PDFFileDrop.urls(from: sender.draggingPasteboard).isEmpty
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = PDFFileDrop.urls(from: sender.draggingPasteboard)
        guard !urls.isEmpty, let app = AppDelegate.current else { return false }
        finishEditing(commit: true)
        for url in urls { app.open(url, in: window) }
        return true
    }

    func startObserving() {
        let center = NotificationCenter.default
        for name in [Notification.Name.PDFViewPageChanged, .PDFViewScaleChanged] {
            observers.append(center.addObserver(forName: name, object: self, queue: .main) { [weak self] _ in self?.publishPosition() })
        }
        observers.append(center.addObserver(forName: .PDFViewSelectionChanged, object: self, queue: .main) { [weak self] _ in
            guard let self, !self.suppressSelection, !self.draggingSelection, self.reader?.tool == .select else { return }
            self.selectionWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.reader?.tool == .select else { return }
                self.reader?.acceptSelection(self.currentSelection)
            }
            self.selectionWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        })
    }
    func stopObserving() {
        selectionWork?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }
    func publishPosition() {
        if let page = currentPage, let document { reader?.pageIndex = document.index(for: page) + 1 }
        reader?.zoom = scaleFactor
        reader?.rememberPosition()
    }
    override func mouseDown(with event: NSEvent) {
        finishEditing(commit: true)
        selectionWork?.cancel()
        pressedAnnotation = nil
        dragStart = nil
        originalBounds = nil
        didDragAnnotation = false
        draggingSelection = false
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let page = page(for: point, nearest: false), let reader else { super.mouseDown(with: event); return }
        let pagePoint = convert(point, to: page)
        // Notes must stay clickable even when newer text markup overlaps them.
        let hit = page.annotations.reversed().first {
            $0.type == "FreeText" && $0.bounds.contains(pagePoint)
        } ?? page.annotations.reversed().first {
            ["Highlight", "Underline"].contains($0.type ?? "") && $0.bounds.contains(pagePoint)
        }
        if reader.tool == .note, reader.canAnnotate {
            clearSelection()
            beginEditing(page: page, point: pagePoint, annotation: hit?.type == "FreeText" ? hit : nil)
            return
        }
        if reader.tool == .select, let hit, hit.type == "FreeText" {
            reader.selectedAnnotation = hit
            clearSelection()
            pressedAnnotation = hit
            dragStart = pagePoint
            originalBounds = hit.bounds
            didDragAnnotation = false
            return
        }
        reader.selectedAnnotation = nil
        pressedAnnotation = hit
        dragStart = pagePoint
        didDragAnnotation = false
        draggingSelection = true
        super.mouseDown(with: event)
    }
    override func mouseDragged(with event: NSEvent) {
        if let annotation = pressedAnnotation, annotation.type == "FreeText",
           let page = annotation.page, let start = dragStart, let bounds = originalBounds,
           reader?.tool == .select, reader?.canAnnotate == true {
            let point = convert(convert(event.locationInWindow, from: nil), to: page)
            // Small pointer movement during a click should still open the editor.
            guard didDragAnnotation || hypot(point.x - start.x, point.y - start.y) * scaleFactor >= 3 else { return }
            let proposed = bounds.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
            let crop = page.bounds(for: .cropBox)
            annotation.bounds = NSRect(x: max(crop.minX, min(proposed.minX, crop.maxX - bounds.width)),
                                       y: max(crop.minY, min(proposed.minY, crop.maxY - bounds.height)),
                                       width: bounds.width, height: bounds.height)
            didDragAnnotation = true
            documentView?.needsDisplay = true
            return
        }
        super.mouseDragged(with: event)
    }
    override func mouseUp(with event: NSEvent) {
        // A new note already owns focus; PDFKit did not receive its mouseDown.
        if editor != nil { return }
        if let annotation = pressedAnnotation, annotation.type == "FreeText",
           let page = annotation.page, let old = originalBounds {
            if didDragAnnotation, let replacement = annotation.copy() as? PDFAnnotation {
                let new = annotation.bounds
                annotation.bounds = old
                replacement.bounds = new
                reader?.replaceAnnotations(removing: [.init(page: page, annotation: annotation)], adding: [.init(page: page, annotation: replacement)], action: "移动笔记")
                reader?.selectedAnnotation = replacement
            } else if !didDragAnnotation, reader?.canAnnotate == true {
                let point = convert(convert(event.locationInWindow, from: nil), to: page)
                if annotation.bounds.contains(point) {
                    beginEditing(page: page, point: point, annotation: annotation)
                }
            }
            pressedAnnotation = nil
            dragStart = nil
            originalBounds = nil
            return
        }
        super.mouseUp(with: event)
        draggingSelection = false
        selectionWork?.cancel()
        if reader?.tool == .select {
            if let selection = currentSelection, !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reader?.acceptSelection(selection)
            } else if let hit = pressedAnnotation { reader?.selectedAnnotation = hit }
        }
        pressedAnnotation = nil
        dragStart = nil
        originalBounds = nil
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { finishEditing(commit: false); reader?.setTool(.select); clearSelection(); return }
        if [51, 117].contains(event.keyCode), reader?.selectedAnnotation != nil { reader?.deleteSelectedAnnotation(); return }
        if event.keyCode == 36, let annotation = reader?.selectedAnnotation,
           annotation.type == "FreeText", let page = annotation.page, reader?.canAnnotate == true {
            beginEditing(page: page, point: annotation.bounds.origin, annotation: annotation)
            return
        }
        super.keyDown(with: event)
    }
    override func scrollWheel(with event: NSEvent) { finishEditing(commit: true); super.scrollWheel(with: event) }
    override func magnify(with event: NSEvent) { finishEditing(commit: true); super.magnify(with: event) }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.allowsContextMenuPlugIns = false
        if #available(macOS 15.2, *) { menu.automaticallyInsertsWritingToolsItems = false }
        let enabled = reader?.canAnnotate == true &&
            !(currentSelection?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let highlight = menu.addItem(withTitle: "高亮", action: #selector(highlightFromMenu(_:)), keyEquivalent: "")
        highlight.target = self
        highlight.isEnabled = enabled
        let underline = menu.addItem(withTitle: "下划线", action: #selector(underlineFromMenu(_:)), keyEquivalent: "")
        underline.target = self
        underline.isEnabled = enabled
        return menu
    }
    @objc private func highlightFromMenu(_ sender: NSMenuItem) {
        guard let reader, let selection = currentSelection else { return }
        reader.highlight(selection, color: reader.highlightColor)
        clearMarkupSelection()
    }
    @objc private func underlineFromMenu(_ sender: NSMenuItem) {
        guard let selection = currentSelection else { return }
        reader?.underline(selection)
        clearMarkupSelection()
    }
    private func clearMarkupSelection() {
        selectionWork?.cancel()
        suppressSelection = true
        clearSelection()
        suppressSelection = false
    }

    func beginEditing(page: PDFPage, point: NSPoint, annotation: PDFAnnotation?) {
        guard reader?.canAnnotate == true else { return }
        finishEditing(commit: true)
        let crop = page.bounds(for: .cropBox)
        let width = min(160.0, crop.width)
        let fontSize = annotation?.font?.pointSize ?? reader?.noteFontSize ?? 14
        let height = min(ceil(fontSize * 1.3) + 10, crop.height)
        let bounds = annotation?.bounds ?? NSRect(x: max(crop.minX, min(point.x, crop.maxX - width)),
                                                   y: max(crop.minY, min(point.y - height, crop.maxY - height)), width: width, height: height)
        let rect = convert(bounds, from: page)
        let box = NSView(frame: rect)
        // Keep text layout in PDF points; scale the view, not the font metrics.
        box.bounds = NSRect(origin: .zero, size: bounds.size)
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.clear.cgColor
        box.layer?.borderColor = NSColor.gray.withAlphaComponent(0.65).cgColor
        box.layer?.borderWidth = 1
        box.layer?.cornerRadius = 0
        let scroll = NSScrollView(frame: box.bounds)
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        let text = NoteTextView(frame: scroll.bounds)
        text.isRichText = false
        text.allowsUndo = true
        let font = NoteStyle.font(ofSize: fontSize)
        text.font = font
        let paragraph = NoteLayout.paragraph(for: font, alignment: annotation?.alignment ?? .left)
        text.defaultParagraphStyle = paragraph
        text.typingAttributes = [.font: font, .foregroundColor: NoteStyle.color, .paragraphStyle: paragraph]
        text.textColor = NoteStyle.color
        text.insertionPointColor = NoteStyle.color
        text.drawsBackground = false
        text.backgroundColor = .clear
        text.textContainerInset = NoteLayout.inset(for: font)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: scroll.bounds.width - text.textContainerInset.width * 2, height: .greatestFiniteMagnitude)
        text.textStorage?.setAttributedString(NSAttributedString(string: annotation?.contents ?? "", attributes: [
            .font: font, .foregroundColor: NoteStyle.color, .paragraphStyle: paragraph]))
        text.onCommit = { [weak self] in self?.finishEditing(commit: true) }
        text.onCancel = { [weak self] in self?.finishEditing(commit: false) }
        scroll.documentView = text
        box.toolTip = "⌘↩ 完成 · Esc 取消"
        box.addSubview(scroll)
        addSubview(box)
        editorBox = box
        editor = text
        editingPage = page
        editingBounds = bounds
        minimumEditorHeight = bounds.height
        editingOriginal = annotation
        originalShouldDisplay = annotation?.shouldDisplay ?? true
        annotation?.shouldDisplay = false
        annotationsChanged(on: page)
        documentView?.needsDisplay = true
        editingWasDirty = false
        textObserver = NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: text, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.resizeNoteEditor()
            if !self.editingWasDirty {
                // Include active text in close/quit's unsaved-document detection.
                self.editingWasDirty = true
                self.reader?.owner?.updateChangeCount(.changeDone)
            }
            self.reader?.refreshUndoState()
        }
        // Switch tools without committing the newly created editor or taking its focus.
        reader?.tool = .select
        reader?.selectedAnnotation = nil
        reader?.isEditingNote = true
        reader?.refreshUndoState()
        window?.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: text.string.utf16.count, length: 0))
    }
    private func resizeNoteEditor() {
        guard let text = editor, let page = editingPage, let box = editorBox,
              let container = text.textContainer, let font = text.font else { return }
        let width = max(20, container.containerSize.width - container.lineFragmentPadding * 2)
        // Measure the current string; TextKit may still have the previous layout during a change notification.
        let measured = ((text.string + "\u{200B}") as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font, .paragraphStyle: text.defaultParagraphStyle ?? NSParagraphStyle.default])
        let contentHeight = ceil(measured.height) + text.textContainerInset.height * 2
        let crop = page.bounds(for: .cropBox)
        let height = min(max(minimumEditorHeight, ceil(contentHeight)), crop.height)
        editingBounds = NSRect(x: editingBounds.minX, y: max(crop.minY, editingBounds.maxY - height),
                               width: editingBounds.width, height: height)
        box.frame = convert(editingBounds, from: page)
        box.bounds = NSRect(origin: .zero, size: editingBounds.size)
    }
    func finishEditing(commit: Bool) {
        guard let text = editor, let page = editingPage else { return }
        if let observer = textObserver { NotificationCenter.default.removeObserver(observer) }
        textObserver = nil
        let contents = text.string
        let original = editingOriginal
        let font = NoteStyle.font(ofSize: text.font?.pointSize ?? 14)
        let fontColor = NoteStyle.color
        let alignment = text.alignment
        if commit { resizeNoteEditor() }
        let bounds = editingBounds
        original?.shouldDisplay = originalShouldDisplay
        annotationsChanged(on: page)
        documentView?.needsDisplay = true
        editorBox?.removeFromSuperview()
        editorBox = nil
        editor = nil
        editingPage = nil
        editingOriginal = nil
        reader?.isEditingNote = false
        defer { reader?.refreshUndoState() }
        if editingWasDirty { reader?.owner?.updateChangeCount(.changeUndone) }
        editingWasDirty = false
        window?.makeFirstResponder(self)
        guard commit else { return }
        if contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let original {
                reader?.replaceAnnotations(removing: [.init(page: page, annotation: original)],
                                           adding: [], action: "删除笔记")
            }
            return
        }
        if let original, (original.contents ?? "") == contents,
           original.font?.fontName == font.fontName, original.font?.pointSize == font.pointSize,
           original.fontColor?.usingColorSpace(.sRGB) == fontColor.usingColorSpace(.sRGB) { return }
        let note = (original?.copy() as? PDFAnnotation) ?? PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
        note.bounds = bounds
        note.contents = contents
        note.font = font
        note.fontColor = fontColor
        note.alignment = alignment
        if original == nil {
            note.color = .clear
            let border = PDFBorder()
            border.lineWidth = 0
            note.border = border
        }
        note.modificationDate = Date()
        reader?.replaceAnnotations(removing: original.map { [.init(page: page, annotation: $0)] } ?? [],
                                   adding: [.init(page: page, annotation: note)], action: original == nil ? "添加笔记" : "编辑笔记")
        reader?.selectedAnnotation = note
    }
    deinit {
        editingOriginal?.shouldDisplay = originalShouldDisplay
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        if let textObserver { NotificationCenter.default.removeObserver(textObserver) }
        selectionWork?.cancel()
    }
}
