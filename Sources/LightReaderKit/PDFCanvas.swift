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
        view.displaysPageBreaks = false
        view.pageBreakMargins = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        view.pageShadowsEnabled = false
        // Gray belongs to the canvas, not a fixed border around each page.
        // Zooming the page to the viewport edges naturally covers this background.
        view.backgroundColor = NSColor(srgbRed: 0.88, green: 0.89, blue: 0.88, alpha: 1)
        view.minScaleFactor = 0.2
        view.maxScaleFactor = 5
        view.autoScales = false
        view.scaleFactor = ReaderState.defaultZoom
        view.startObserving()
        DispatchQueue.main.async {
            state.pageCount = state.pdf?.pageCount ?? 0
            state.locked = state.pdf?.isLocked ?? false
            if let position = ReadingHistory.shared.position(for: state.owner?.fileURL), let pdf = state.pdf,
               let page = pdf.page(at: min(position.page, max(0, pdf.pageCount - 1))) {
                view.autoScales = position.autoScale
                if !position.autoScale { view.scaleFactor = position.scale }
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

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        var pixel = convertToBacking(rect)
        pixel.origin.x = floor(pixel.minX)
        pixel.size.width = 1
        let caret = convertFromBacking(pixel)
        if flag {
            color.setFill()
            caret.fill()
        } else {
            setNeedsDisplay(caret)
        }
    }
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

// PDFView implements delegate-forwarding selectors itself. A separate delegate
// avoids forwarding optional callbacks (such as scale changes) back into itself.
private final class CanvasLinkDelegate: NSObject, PDFViewDelegate {
    func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
        (sender as? PDFCanvas)?.pdfViewWillClick(onLink: sender, with: url)
    }
}

final class PDFCanvas: PDFView {
    weak var reader: ReaderState?
    private var observers: [NSObjectProtocol] = []
    private var selectionWork: DispatchWorkItem?
    private let markupSelectionOverlay = MarkupSelectionOverlay(frame: .zero)
    private var editorBox: NoteEditorBox?
    private var editor: NoteTextView?
    private var editingPage: PDFPage?
    private var editingBounds: NSRect = .zero
    private var minimumEditorHeight: CGFloat = 0
    private var editorAutoWidth = false
    private var editorAutoHeight = true
    private var editorDrag: (bounds: NSRect, point: NSPoint, edges: NoteEditorBox.Edges?)?
    var noteUndoManager: UndoManager? { editor?.undoManager }
    var editingNoteFontSize: CGFloat? { editor?.font?.pointSize }
    private var editingOriginal: PDFAnnotation?
    private var originalShouldDisplay = true
    private var pressedAnnotation: PDFAnnotation?
    private var dragStart: NSPoint?
    private var originalBounds: NSRect?
    private var didDragAnnotation = false
    private var draggingSelection = false
    private var additiveBase: PDFSelection?
    private var selectionAnchor: (page: PDFPage, point: NSPoint)?
    private var selectionDidDrag = false
    private var selectionPointer: NSPoint = .zero
    private var selectionScrollObserver: NSObjectProtocol?
    private var suppressSelection = false
    private var editingWasDirty = false
    private var textObserver: NSObjectProtocol?
    private let linkDelegate = CanvasLinkDelegate()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        delegate = linkDelegate
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = linkDelegate
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        // Keep wheel gestures (including momentum) on the PDF scroll view,
        // even over an annotation or the note's nested text scroll view.
        if window?.currentEvent?.type == .scrollWheel,
           let scroll = documentView?.enclosingScrollView { return scroll }
        // Keep editor inputs and native PDF links, forms and multi-click gestures interactive.
        if let editorBox, hit === editorBox || hit.isDescendant(of: editorBox) { return hit }
        guard let documentView, hit === documentView || hit.isDescendant(of: documentView) else { return hit }
        let local = convert(point, from: superview)
        guard bounds.contains(local), page(for: local, nearest: false) != nil else { return hit }
        if reader?.tool == .note || editableAnnotation(at: local) != nil { return self }
        if let event = window?.currentEvent, shouldTrackText(at: local, event: event) { return self }
        return hit
    }

    private func shouldTrackText(at point: NSPoint, event: NSEvent) -> Bool {
        guard reader?.tool == .select, event.type == .leftMouseDown, event.clickCount == 1,
              event.modifierFlags.intersection([.shift, .control, .option]).isEmpty,
              let page = page(for: point, nearest: false), page.numberOfCharacters > 0 else { return false }
        return page.annotation(at: convert(point, to: page)) == nil
    }

    private func editableAnnotation(at point: NSPoint) -> PDFAnnotation? {
        guard let page = page(for: point, nearest: false) else { return nil }
        let location = convert(point, to: page)
        return page.annotations.reversed().first {
            $0.shouldDisplay && $0.type == "FreeText" && $0.bounds.contains(location)
        } ?? page.annotations.reversed().first {
            $0.shouldDisplay && ["Highlight", "Underline"].contains($0.type ?? "") && $0.bounds.contains(location)
        }
    }

    // Recheck URL hits in page coordinates after zooming/scrolling. A stale
    // PDFKit link overlay must not navigate from an unrelated article region.
    func canOpenLink(_ url: URL, at point: NSPoint) -> Bool {
        guard bounds.contains(point), editableAnnotation(at: point) == nil,
              let page = page(for: point, nearest: false) else { return false }
        let location = convert(point, to: page)
        return page.annotations.contains {
            $0.shouldDisplay && $0.type == "Link" && $0.bounds.contains(location) &&
            ($0.action as? PDFActionURL)?.url == url
        }
    }
    func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
        guard let event = NSApp.currentEvent,
              event.type == .leftMouseDown || event.type == .leftMouseUp,
              canOpenLink(url, at: convert(event.locationInWindow, from: nil)) else { return }
        NSWorkspace.shared.open(url)
    }

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
        endSelectionTracking()
        selectionWork?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }
    func refreshMarkupSelection() {
        guard let documentView else { return }
        if markupSelectionOverlay.superview !== documentView {
            markupSelectionOverlay.removeFromSuperview()
            documentView.addSubview(markupSelectionOverlay)
        }
        markupSelectionOverlay.frame = documentView.bounds
        markupSelectionOverlay.autoresizingMask = [.width, .height]
        let selected = reader?.selectedAnnotation
        let group = selected.flatMap { annotation -> [PlacedAnnotation]? in
            guard ["Highlight", "Underline"].contains(annotation.type ?? ""),
                  annotation.page?.document === document else { return nil }
            return reader?.annotationGroup(containing: annotation)
        } ?? []
        markupSelectionOverlay.selectionRects = group.filter { $0.annotation.shouldDisplay }.map {
            markupSelectionOverlay.convert(convert($0.annotation.bounds, from: $0.page), from: self)
        }
    }
    override func layout() {
        super.layout()
        layoutNoteEditor()
        refreshMarkupSelection()
    }
    func publishPosition() {
        layoutNoteEditor()
        refreshMarkupSelection()
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
        endSelectionTracking()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let page = page(for: point, nearest: false), let reader else { super.mouseDown(with: event); return }
        let pagePoint = convert(point, to: page)
        if reader.tool == .select, event.modifierFlags.contains(.command) {
            additiveBase = currentSelection?.copy() as? PDFSelection
            beginSelectionTracking(page: page, point: pagePoint, event: event)
            reader.selectedAnnotation = nil
            reader.cancelTranslation()
            return
        }
        let hit = editableAnnotation(at: point)
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
        if reader.tool == .select, let hit, ["Highlight", "Underline"].contains(hit.type ?? ""), event.clickCount == 1 {
            clearMarkupSelection()
            reader.selectedAnnotation = hit
            pressedAnnotation = hit
            beginSelectionTracking(page: page, point: pagePoint, event: event)
            return
        }
        reader.selectedAnnotation = nil
        if shouldTrackText(at: point, event: event) {
            clearMarkupSelection()
            beginSelectionTracking(page: page, point: pagePoint, event: event)
            return
        }
        pressedAnnotation = hit
        dragStart = pagePoint
        didDragAnnotation = false
        draggingSelection = true
        super.mouseDown(with: event)
    }
    override func mouseDragged(with event: NSEvent) {
        if selectionAnchor != nil {
            selectionPointer = event.locationInWindow
            documentView?.autoscroll(with: event)
            updateTrackedSelection()
            return
        }
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
        if selectionAnchor != nil {
            selectionPointer = event.locationInWindow
            updateTrackedSelection()
            let clickedMarkup = !selectionDidDrag ? pressedAnnotation : nil
            endSelectionTracking()
            pressedAnnotation = nil
            selectionWork?.cancel()
            if let clickedMarkup { reader?.selectedAnnotation = clickedMarkup }
            else { reader?.acceptSelection(currentSelection) }
            return
        }
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
    // Track the anchor in PDF points and the pointer in window points. Scrolling
    // can change the selected text even without another mouse-dragged event.
    private func beginSelectionTracking(page: PDFPage, point: NSPoint, event: NSEvent) {
        draggingSelection = true
        selectionAnchor = (page, point)
        selectionPointer = event.locationInWindow
        guard let clip = documentView?.enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        selectionScrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: clip, queue: .main) { [weak self] _ in self?.updateTrackedSelection() }
    }
    private func endSelectionTracking() {
        if let selectionScrollObserver { NotificationCenter.default.removeObserver(selectionScrollObserver) }
        selectionScrollObserver = nil
        selectionAnchor = nil
        additiveBase = nil
        selectionDidDrag = false
        draggingSelection = false
    }
    private func updateTrackedSelection() {
        guard let anchor = selectionAnchor, let document else { return }
        let point = convert(selectionPointer, from: nil)
        let start = convert(anchor.point, from: anchor.page)
        guard selectionDidDrag || hypot(point.x - start.x, point.y - start.y) >= 3,
              let endPage = page(for: point, nearest: true) else { return }
        selectionDidDrag = true
        let selection = document.selection(from: anchor.page, at: anchor.point,
                                           to: endPage, at: convert(point, to: endPage))
        if reader?.selectedAnnotation != nil { reader?.selectedAnnotation = nil }
        if let additiveBase, let selection {
            setCurrentSelection(PDFSelection.combining([additiveBase, selection], in: document), animate: false)
        } else {
            setCurrentSelection(selection ?? additiveBase, animate: false)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            pressedAnnotation = nil
            endSelectionTracking()
            selectionWork?.cancel()
            finishEditing(commit: false); reader?.setTool(.select); clearSelection(); return
        }
        if [51, 117].contains(event.keyCode), reader?.selectedAnnotation != nil { reader?.deleteSelectedAnnotation(); return }
        if event.keyCode == 36, let annotation = reader?.selectedAnnotation,
           annotation.type == "FreeText", let page = annotation.page, reader?.canAnnotate == true {
            beginEditing(page: page, point: annotation.bounds.origin, annotation: annotation)
            return
        }
        super.keyDown(with: event)
    }
    override func magnify(with event: NSEvent) { finishEditing(commit: true); super.magnify(with: event) }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.allowsContextMenuPlugIns = false
        if #available(macOS 15.2, *) { menu.automaticallyInsertsWritingToolsItems = false }
        if let annotation = markupAnnotation(at: event) {
            clearMarkupSelection()
            reader?.selectedAnnotation = annotation
            let delete = menu.addItem(withTitle: "删除标记", action: #selector(deleteMarkupFromMenu(_:)), keyEquivalent: "")
            delete.target = self
            delete.isEnabled = reader?.canAnnotate == true
            return menu
        }
        reader?.selectedAnnotation = nil
        let hasSelection = !(currentSelection?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let copy = menu.addItem(withTitle: "复制", action: #selector(copySelectionFromMenu(_:)), keyEquivalent: "")
        copy.target = self
        copy.isEnabled = hasSelection
        let enabled = reader?.canAnnotate == true && hasSelection
        let highlight = menu.addItem(withTitle: "高亮", action: #selector(highlightFromMenu(_:)), keyEquivalent: "")
        highlight.target = self
        highlight.isEnabled = enabled
        let underline = menu.addItem(withTitle: "下划线", action: #selector(underlineFromMenu(_:)), keyEquivalent: "")
        underline.target = self
        underline.isEnabled = enabled
        return menu
    }
    private func markupAnnotation(at event: NSEvent) -> PDFAnnotation? {
        let point = convert(event.locationInWindow, from: nil)
        guard let page = page(for: point, nearest: false) else { return nil }
        let pagePoint = convert(point, to: page)
        return page.annotations.reversed().first { annotation in
            ["Highlight", "Underline"].contains(annotation.type ?? "") && annotation.bounds.contains(pagePoint)
        }
    }
    @objc private func copySelectionFromMenu(_ sender: NSMenuItem) {
        guard let text = currentSelection?.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    @objc private func deleteMarkupFromMenu(_ sender: NSMenuItem) {
        reader?.deleteSelectedAnnotation()
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
        // New notes start compactly; users can still widen the box with the visible handles.
        let width = min(45.0, crop.width)
        let fontSize = annotation?.font?.pointSize ?? reader?.noteFontSize ?? Double(NoteStyle.defaultFontSize)
        let font = NoteStyle.font(ofSize: fontSize)
        let height = min(NoteLayout.singleLineHeight(for: font), crop.height)
        let bounds = annotation?.bounds ?? NSRect(x: max(crop.minX, min(point.x, crop.maxX - width)),
                                                   y: max(crop.minY, min(point.y - height, crop.maxY - height)), width: width, height: height)
        guard let documentView else { return }
        let rect = documentView.convert(convert(bounds, from: page), from: self)
        let box = NoteEditorBox(frame: rect)
        // Keep text layout in PDF points; scale the view, not the font metrics.
        box.setTextGeometry(frame: rect, size: bounds.size)
        let scroll = NSScrollView(frame: box.textRect)
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
        text.font = font
        let paragraph = NoteLayout.paragraph(alignment: annotation?.alignment ?? .left)
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
        box.toolTip = "拖动顶部短线移动 · 拖动边缘或四角调整大小 · ⌘↩ 完成 · Esc 取消"
        box.onBegin = { [weak self] interaction, event in self?.beginEditorDrag(interaction, event: event) }
        box.onDrag = { [weak self] event in self?.dragEditor(event) }
        box.onEnd = { [weak self] in self?.editorDrag = nil }
        box.addSubview(scroll)
        documentView.addSubview(box)
        editorBox = box
        editor = text
        editingPage = page
        editingBounds = bounds
        minimumEditorHeight = bounds.height
        editorAutoWidth = annotation == nil
        editorAutoHeight = true
        editorDrag = nil
        editingOriginal = annotation
        originalShouldDisplay = annotation?.shouldDisplay ?? true
        annotation?.shouldDisplay = false
        annotationsChanged(on: page)
        self.documentView?.needsDisplay = true
        editingWasDirty = false
        textObserver = NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: text, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.resizeNoteEditor()
            self.markEditorDirty()
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
    func setEditingNoteFontSize(_ size: CGFloat) {
        guard let text = editor, let oldSize = text.font?.pointSize, oldSize != size,
              size.isFinite, (1...144).contains(size) else { return }
        let range = NSRange(location: 0, length: text.string.utf16.count)
        guard text.shouldChangeText(in: range, replacementString: nil) else { return }
        text.breakUndoCoalescing()
        text.undoManager?.registerUndo(withTarget: self) { target in target.setEditingNoteFontSize(oldSize) }
        text.undoManager?.setActionName("修改字号")
        let selection = text.selectedRanges
        let font = NoteStyle.font(ofSize: size)
        let paragraph = NoteLayout.paragraph(alignment: text.alignment)
        text.font = font
        text.defaultParagraphStyle = paragraph
        text.textStorage?.addAttribute(.paragraphStyle, value: paragraph, range: range)
        text.textContainerInset = NoteLayout.inset(for: font)
        text.typingAttributes = [.font: font, .foregroundColor: NoteStyle.color, .paragraphStyle: paragraph]
        text.selectedRanges = selection
        text.didChangeText()
        // Publish changes from font undo/redo as well as toolbar changes.
        reader?.objectWillChange.send()
        window?.makeFirstResponder(text)
    }
    private func markEditorDirty() {
        if !editingWasDirty {
            editingWasDirty = true
            reader?.owner?.updateChangeCount(.changeDone)
        }
    }
    private func layoutNoteEditor() {
        guard let box = editorBox, let page = editingPage, let text = editor,
              let scroll = text.enclosingScrollView else { return }
        let canvasRect = convert(editingBounds, from: page)
        let documentRect = documentView?.convert(canvasRect, from: self) ?? canvasRect
        box.setTextGeometry(frame: documentRect, size: editingBounds.size)
        scroll.frame = box.textRect
        text.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(text.frame.height, scroll.contentSize.height)))
        text.textContainer?.containerSize = NSSize(width: max(1, scroll.contentSize.width - text.textContainerInset.width * 2),
                                                   height: .greatestFiniteMagnitude)
        if let container = text.textContainer { text.layoutManager?.ensureLayout(for: container) }
        box.needsDisplay = true
        window?.invalidateCursorRects(for: box)
    }
    private func beginEditorDrag(_ interaction: NoteEditorBox.Interaction, event: NSEvent) {
        guard let page = editingPage, let box = editorBox else { return }
        var pageEdges: NoteEditorBox.Edges?
        if case .resize(let edges) = interaction {
            pageEdges = []
            // Map the visible handles to PDF edges, including rotated pages.
            let samples: [(NoteEditorBox.Edges, NSPoint)] = [
                (.left, NSPoint(x: box.textRect.minX, y: box.textRect.midY)),
                (.right, NSPoint(x: box.textRect.maxX, y: box.textRect.midY)),
                (.bottom, NSPoint(x: box.textRect.midX, y: box.textRect.minY)),
                (.top, NSPoint(x: box.textRect.midX, y: box.textRect.maxY))]
            for (edge, local) in samples where edges.contains(edge) {
                let point = convert(box.convert(local, to: self), to: page)
                let distances: [(NoteEditorBox.Edges, CGFloat)] = [(.left, abs(point.x - editingBounds.minX)),
                    (.right, abs(point.x - editingBounds.maxX)), (.bottom, abs(point.y - editingBounds.minY)),
                    (.top, abs(point.y - editingBounds.maxY))]
                if let mapped = distances.min(by: { $0.1 < $1.1 })?.0 { pageEdges?.insert(mapped) }
            }
        }
        editorDrag = (editingBounds, convert(convert(event.locationInWindow, from: nil), to: page), pageEdges)
    }
    private func dragEditor(_ event: NSEvent) {
        guard let drag = editorDrag, let page = editingPage else { return }
        let point = convert(convert(event.locationInWindow, from: nil), to: page)
        let dx = point.x - drag.point.x, dy = point.y - drag.point.y
        let crop = page.bounds(for: .cropBox)
        var proposed = drag.bounds
        if let edges = drag.edges {
            let minWidth = min(40.0, crop.width)
            let minHeight = min(NoteLayout.singleLineHeight(for: editor?.font ?? NoteStyle.font(ofSize: NoteStyle.defaultFontSize)), crop.height)
            var left = proposed.minX, right = proposed.maxX, bottom = proposed.minY, top = proposed.maxY
            if edges.contains(.left) { left = max(crop.minX, min(right - minWidth, left + dx)) }
            if edges.contains(.right) { right = min(crop.maxX, max(left + minWidth, right + dx)) }
            if edges.contains(.bottom) { bottom = max(crop.minY, min(top - minHeight, bottom + dy)) }
            if edges.contains(.top) { top = min(crop.maxY, max(bottom + minHeight, top + dy)) }
            proposed = NSRect(x: left, y: bottom, width: right - left, height: top - bottom)
            if proposed.width != drag.bounds.width { editorAutoWidth = false }
            if !edges.intersection([.top, .bottom]).isEmpty {
                editorAutoHeight = false
                minimumEditorHeight = proposed.height
            }
        } else {
            proposed.origin = NSPoint(x: max(crop.minX, min(crop.maxX - proposed.width, proposed.minX + dx)),
                                      y: max(crop.minY, min(crop.maxY - proposed.height, proposed.minY + dy)))
        }
        guard proposed != editingBounds else { return }
        editingBounds = proposed
        layoutNoteEditor()
        // Width changes reflow immediately; an explicitly chosen height stays fixed.
        if let edges = drag.edges, edges.intersection([.top, .bottom]).isEmpty { resizeNoteEditor() }
        markEditorDirty()
    }
    private func resizeNoteEditor() {
        guard let text = editor, let page = editingPage, let font = text.font else { return }
        let crop = page.bounds(for: .cropBox)
        let content = (text.string + "\u{200B}") as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: NoteLayout.nativeParagraph(for: font, alignment: text.alignment)]
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let inset = text.textContainerInset
        if editorAutoWidth {
            let available = crop.maxX - editingBounds.minX
            let natural = content.boundingRect(with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
                                               options: options, attributes: attributes)
            editingBounds.size.width = min(available, max(editingBounds.width, ceil(natural.width + 2 * inset.width + 1)))
        }
        if editorAutoHeight {
            let measured = content.boundingRect(with: NSSize(width: max(1, editingBounds.width - 2 * inset.width), height: .greatestFiniteMagnitude),
                                                options: options, attributes: attributes)
            let height = min(max(minimumEditorHeight, ceil(measured.height + 2 * inset.height)), crop.height)
            editingBounds.origin.y = max(crop.minY, editingBounds.maxY - height)
            editingBounds.size.height = height
        }
        layoutNoteEditor()
    }
    func finishEditing(commit: Bool) {
        guard let text = editor, let page = editingPage else { return }
        if let observer = textObserver { NotificationCenter.default.removeObserver(observer) }
        textObserver = nil
        let contents = text.string
        let original = editingOriginal
        let font = NoteStyle.font(ofSize: text.font?.pointSize ?? NoteStyle.defaultFontSize)
        let fontColor = NoteStyle.color
        let alignment = text.alignment
        // Text changes already reflow; committing must preserve manually chosen geometry.
        let bounds = editingBounds
        original?.shouldDisplay = originalShouldDisplay
        annotationsChanged(on: page)
        documentView?.needsDisplay = true
        editorBox?.removeFromSuperview()
        editorBox = nil
        editorDrag = nil
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
        if let original, original.bounds == bounds, (original.contents ?? "") == contents,
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
        if let selectionScrollObserver { NotificationCenter.default.removeObserver(selectionScrollObserver) }
        editingOriginal?.shouldDisplay = originalShouldDisplay
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        if let textObserver { NotificationCenter.default.removeObserver(textObserver) }
        selectionWork?.cancel()
    }
}
