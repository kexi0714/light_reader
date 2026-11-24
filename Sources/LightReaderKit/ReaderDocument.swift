import AppKit
import PDFKit
import SwiftUI

@objc(ReaderDocument)
public final class ReaderDocument: NSDocument {
    let reader = ReaderState()
    public override init() {
        super.init()
        hasUndoManager = true
        reader.owner = self
        reader.observeUndoChanges()
    }
    public override class var autosavesInPlace: Bool { false }
    public override func read(from data: Data, ofType typeName: String) throws {
        guard let pdf = PDFDocument(data: data) else {
            throw NSError(domain: "LightReader", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法打开此文件，它可能不是有效的 PDF。"])
        }
        reader.pdf = pdf
    }
    public override func data(ofType typeName: String) throws -> Data {
        reader.canvas?.finishEditing(commit: true)
        guard let pdf = reader.pdf, !pdf.isLocked, let data = pdf.dataRepresentation() else {
            throw NSError(domain: "LightReader", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法保存 PDF，请先解锁文献。"])
        }
        return data
    }
    public override func makeWindowControllers() {
        let controller = ReaderWindowController(window: nil)
        let host = NSHostingController(rootView: ReaderView(state: reader, tabs: controller.tabs))
        let window = NSWindow(contentViewController: host)
        window.setContentSize(NSSize(width: 1180, height: 800))
        window.minSize = NSSize(width: 860, height: 560)
        window.title = displayName
        window.titleVisibility = .hidden
        window.animationBehavior = .none
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.tabbingIdentifier = "LightReader.PDF"
        window.tabbingMode = .disallowed
        window.center()
        controller.window = window
        controller.tabs.append(window)
        window.delegate = controller
        addWindowController(controller)
    }
    public override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        reader.canvas?.finishEditing(commit: true)
        super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
    }
    public override func close() {
        for controller in windowControllers {
            if let window = controller.window { ReaderTabs.group(of: window)?.remove(window) }
        }
        reader.rememberPosition()
        reader.cancelTranslation()
        super.close()
    }
    @objc func showDocumentFind(_ sender: Any?) {
        guard reader.pdf?.isLocked == false else { return }
        reader.canvas?.finishEditing(commit: true)
        reader.findRequest = UUID()
    }
    @objc func saveWithEditor(_ sender: Any?) {
        reader.canvas?.finishEditing(commit: true)
        save(sender)
    }
}

enum ReaderTool: Equatable {
    case select, note
}

enum HighlightColor: String, CaseIterable {
    case green, orange, blue
    var title: String {
        switch self { case .green: return "绿色"; case .orange: return "橙色"; case .blue: return "蓝色" }
    }
    var color: NSColor {
        // PDFKit drops NSColor alpha when it serializes markup annotations.
        // Keep the palette opaque so live and reopened highlights look identical.
        switch self {
        case .green: return NSColor(srgbRed: 0.50, green: 0.78, blue: 0.53, alpha: 1)
        case .orange: return NSColor(srgbRed: 0.96, green: 0.66, blue: 0.29, alpha: 1)
        case .blue: return NSColor(srgbRed: 0.40, green: 0.65, blue: 0.90, alpha: 1)
        }
    }
    func matches(_ other: NSColor) -> Bool {
        guard let lhs = color.usingColorSpace(.sRGB), let rhs = other.usingColorSpace(.sRGB) else { return false }
        // Color spaces and serialized component precision can vary after reopening.
        return abs(lhs.redComponent - rhs.redComponent) < 0.005
            && abs(lhs.greenComponent - rhs.greenComponent) < 0.005
            && abs(lhs.blueComponent - rhs.blueComponent) < 0.005
    }
    var swatch: Color { Color(nsColor: color) }
}

struct PlacedAnnotation {
    let page: PDFPage
    let annotation: PDFAnnotation
}

final class ReaderState: ObservableObject {
    // Persist the originating operation across PDF save/reopen, including across pages.
    private static let markupGroupKey = PDFAnnotationKey(rawValue: "LiReMarkupGroup")
    weak var owner: ReaderDocument?
    weak var canvas: PDFCanvas?
    @Published var pdf: PDFDocument?
    @Published var findRequest: UUID?
    @Published var tool: ReaderTool = .select
    @Published private(set) var highlightColor: HighlightColor = .green
    @Published var pageIndex = 1
    @Published var pageCount = 0
    static let defaultZoom: CGFloat = 2.2
    @Published var zoom = ReaderState.defaultZoom
    @Published var selectedText = ""
    @Published var translation = ""
    @Published var translationSource = ""
    @Published var translationError: String?
    @Published var isTranslating = false
    @Published var sidebarVisible = true
    @Published var translationSettingsVisible = false
    @Published var selectedAnnotation: PDFAnnotation? {
        didSet { canvas?.refreshMarkupSelection() }
    }
    @Published var noteFontSize = Double(NoteStyle.defaultFontSize)
    @Published var isEditingNote = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private var undoObservers: [NSObjectProtocol] = []
    private var activeUndoManager: UndoManager? { canvas?.noteUndoManager ?? owner?.undoManager }

    func observeUndoChanges() {
        for name in [Notification.Name.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            undoObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let self, let manager = notification.object as? UndoManager,
                      manager === self.activeUndoManager else { return }
                self.refreshUndoState()
            })
        }
        refreshUndoState()
    }
    func refreshUndoState() {
        canUndo = activeUndoManager?.canUndo == true
        canRedo = activeUndoManager?.canRedo == true
    }
    func undo() {
        guard activeUndoManager?.canUndo == true else { return }
        activeUndoManager?.undo()
        selectedAnnotation = nil
        refreshUndoState()
    }
    func redo() {
        guard activeUndoManager?.canRedo == true else { return }
        activeUndoManager?.redo()
        selectedAnnotation = nil
        refreshUndoState()
    }
    @Published var locked = false
    @Published var notice: String?
    private var requestTask: Task<Void, Never>?
    private var requestID = UUID()
    private var cache: [String: String] = [:]
    private var settingsObserver: NSObjectProtocol?

    var canAnnotate: Bool { pdf?.allowsCommenting == true && !locked }
    var toolHint: String {
        if isEditingNote { return "正在输入笔记 · 拖动顶部移动栏移动 · 边缘缩放 · ⌘↩ 完成 · Esc 取消" }
        if let annotation = selectedAnnotation, ["Highlight", "Underline"].contains(annotation.type ?? "") {
            return "已选中标记 · 点击顶部色块修改颜色 · Delete 删除 · Esc 取消选择"
        }
        switch tool {
        case .select: return "划词翻译 · ⌘追加划选 · 右键高亮 · 单击笔记可编辑"
        case .note: return "点击页面添加笔记 · ⌘↩ 完成 · Esc 取消"
        }
    }
    func setTool(_ newTool: ReaderTool) {
        canvas?.finishEditing(commit: true)
        selectedAnnotation = nil
        tool = newTool
        canvas?.window?.makeFirstResponder(canvas)
    }
    var currentNoteFontSize: Double {
        if let size = canvas?.editingNoteFontSize { return Double(size) }
        if selectedAnnotation?.type == "FreeText", let size = selectedAnnotation?.font?.pointSize { return Double(size) }
        return noteFontSize
    }
    var noteFontSizes: [Double] {
        Array(Set([8.0, 10, 12, 14, 16, 18, 20, 22, 24, 28, 32, 36, 48, 72, currentNoteFontSize])).sorted()
    }
    func setNoteFontSize(_ size: Double) {
        guard canAnnotate, size.isFinite, (1...144).contains(size) else { return }
        noteFontSize = size
        if isEditingNote {
            canvas?.setEditingNoteFontSize(CGFloat(size))
        } else if let original = selectedAnnotation, original.type == "FreeText",
                  original.font?.pointSize != CGFloat(size), let page = original.page,
                  let note = original.copy() as? PDFAnnotation {
            note.font = NoteStyle.font(ofSize: CGFloat(size))
            note.modificationDate = Date()
            replaceAnnotations(removing: [.init(page: page, annotation: original)],
                               adding: [.init(page: page, annotation: note)], action: "修改字号")
            selectedAnnotation = note
        }
        refreshUndoState()
    }
    var currentHighlightColor: HighlightColor? {
        if let annotation = selectedAnnotation, ["Highlight", "Underline"].contains(annotation.type ?? "") {
            return HighlightColor.allCases.first { $0.matches(annotation.color) }
        }
        return highlightColor
    }
    func selectHighlight(_ color: HighlightColor) {
        highlightColor = color
        guard canAnnotate, let selected = selectedAnnotation,
              ["Highlight", "Underline"].contains(selected.type ?? ""),
              selected.page?.document === pdf else { return }
        let originals = annotationGroup(containing: selected)
        guard originals.contains(where: { !color.matches($0.annotation.color) }) else { return }
        let replacements = originals.compactMap { item -> PlacedAnnotation? in
            guard let copy = item.annotation.copy() as? PDFAnnotation else { return nil }
            // A saved appearance can draw the previous color over the new /C value.
            copy.removeValue(forAnnotationKey: .appearanceDictionary)
            copy.color = color.color
            copy.modificationDate = Date()
            return .init(page: item.page, annotation: copy)
        }
        guard replacements.count == originals.count else { return }
        let selectedIndex = originals.firstIndex { $0.annotation === selected }
        replaceAnnotations(removing: originals, adding: replacements, action: "修改标记颜色")
        if let selectedIndex { selectedAnnotation = replacements[selectedIndex].annotation }
        refreshUndoState()
    }
    func highlight(_ selection: PDFSelection, color: HighlightColor) {
        addTextMarkup(selection, type: .highlight, color: color.color, action: "添加高亮")
    }
    func underline(_ selection: PDFSelection) {
        addTextMarkup(selection, type: .underline, color: highlightColor.color, action: "添加下划线")
    }
    private func addTextMarkup(_ selection: PDFSelection, type: PDFAnnotationSubtype, color: NSColor, action: String) {
        guard canAnnotate else { notice = "这份 PDF 不允许添加标注。"; return }
        let groupID = UUID().uuidString
        var glyphsByPage: [ObjectIdentifier: [CGRect]] = [:]
        let annotations = selection.selectionsByLine().flatMap { line -> [PlacedAnnotation] in
            line.pages.compactMap { page in
                var bounds = line.bounds(for: page)
                if type == .highlight {
                    let key = ObjectIdentifier(page)
                    if glyphsByPage[key] == nil { glyphsByPage[key] = TextMarkupGeometry.glyphBounds(on: page) }
                    bounds = TextMarkupGeometry.highlightBounds(for: line, on: page, glyphs: glyphsByPage[key] ?? [])
                }
                guard !bounds.isEmpty, !bounds.isInfinite else { return nil }
                let annotation = PDFAnnotation(bounds: bounds, forType: type, withProperties: nil)
                if type == .highlight { annotation.quadrilateralPoints = TextMarkupGeometry.quadrilateralPoints(for: bounds) }
                annotation.setValue(groupID, forAnnotationKey: Self.markupGroupKey)
                annotation.color = color
                annotation.contents = line.string
                annotation.modificationDate = Date()
                return .init(page: page, annotation: annotation)
            }
        }
        if !annotations.isEmpty { replaceAnnotations(removing: [], adding: annotations, action: action) }
    }
    func replaceAnnotations(removing: [PlacedAnnotation], adding: [PlacedAnnotation], action: String) {
        guard let owner else { return }
        for item in removing { item.page.removeAnnotation(item.annotation) }
        for item in adding { item.page.addAnnotation(item.annotation) }
        for page in Set((removing + adding).map(\.page)) { canvas?.annotationsChanged(on: page) }
        owner.undoManager?.registerUndo(withTarget: self) { target in
            target.replaceAnnotations(removing: adding, adding: removing, action: action)
        }
        owner.undoManager?.setActionName(action)
        // NSDocument observes its undo manager and updates the change count itself.
        selectedAnnotation = nil
        canvas?.needsDisplay = true
        canvas?.documentView?.needsDisplay = true
    }
    func deleteSelectedAnnotation() {
        guard canAnnotate, let annotation = selectedAnnotation, annotation.page != nil else { return }
        replaceAnnotations(removing: annotationGroup(containing: annotation), adding: [], action: "删除标注")
    }
    func annotationGroup(containing annotation: PDFAnnotation) -> [PlacedAnnotation] {
        guard let page = annotation.page else { return [] }
        var annotations = [PlacedAnnotation(page: page, annotation: annotation)]
        if ["Highlight", "Underline"].contains(annotation.type ?? ""),
           let groupID = annotation.value(forAnnotationKey: Self.markupGroupKey) as? String,
           !groupID.isEmpty, let pdf, page.document === pdf {
            annotations = (0..<pdf.pageCount).compactMap { pdf.page(at: $0) }.flatMap { groupPage in
                groupPage.annotations.compactMap { candidate -> PlacedAnnotation? in
                    guard candidate.type == annotation.type,
                          candidate.value(forAnnotationKey: Self.markupGroupKey) as? String == groupID else { return nil }
                    return .init(page: groupPage, annotation: candidate)
                }
            }
        }
        return annotations
    }
    func acceptSelection(_ selection: PDFSelection?) {
        guard let selection else { return }
        let text = selection.translationText
        guard !text.isEmpty else { return }
        selectedAnnotation = nil
        selectedText = text
        translate()
    }
    func retranslate(_ editedText: String) {
        let text = editedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        selectedText = text
        translate(force: true)
    }
    func translate(force: Bool = false) {
        guard !selectedText.isEmpty else { return }
        cancelTranslation()
        translationError = nil
        translation = ""
        let text = selectedText
        let configuration = SettingsStore.shared.configuration
        translationSource = configuration.provider.title
        let id = UUID()
        requestID = id
        let secret: String
        do {
            secret = try SettingsStore.shared.secret(for: configuration.provider)
            _ = try TranslationService.request(text: text, configuration: configuration, secret: secret)
        } catch { translationError = error.localizedDescription; return }
        let key = [configuration.provider.rawValue, configuration.endpoint, configuration.model, configuration.baiduAppID, text].joined(separator: "\u{001F}")
        if !force, let cached = cache[key] { translation = cached; return }
        isTranslating = true
        requestTask = Task { @MainActor [weak self] in
            do {
                // Debounce rapid selections before making a billable request.
                try await Task.sleep(nanoseconds: 300_000_000)
                let result = try await TranslationService().translate(text, configuration: configuration, secret: secret)
                guard let self, self.requestID == id, !Task.isCancelled else { return }
                self.translation = result
                if self.cache.count >= 100 { self.cache.removeAll() }
                self.cache[key] = result
                self.isTranslating = false
            } catch {
                guard let self, self.requestID == id, !Task.isCancelled else { return }
                self.isTranslating = false
                self.translationError = error.localizedDescription
            }
        }
    }
    func cancelTranslation() {
        requestTask?.cancel()
        requestTask = nil
        requestID = UUID()
        isTranslating = false
    }
    func movePage(_ delta: Int) { goToPage(pageIndex + delta) }
    func goToPage(_ number: Int) {
        canvas?.finishEditing(commit: true)
        guard let pdf, let page = pdf.page(at: max(0, min(number - 1, pdf.pageCount - 1))) else { return }
        canvas?.go(to: page)
    }
    func scale(_ factor: CGFloat) {
        canvas?.finishEditing(commit: true)
        guard let canvas else { return }
        canvas.autoScales = false
        canvas.scaleFactor = max(canvas.minScaleFactor, min(canvas.maxScaleFactor, canvas.scaleFactor * factor))
    }
    @discardableResult
    func setZoomPercentage(_ input: String) -> Bool {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix("%") || value.hasSuffix("％") { value.removeLast() }
        guard let percentage = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              percentage.isFinite, percentage > 0, let canvas else { return false }
        canvas.finishEditing(commit: true)
        canvas.autoScales = false
        canvas.scaleFactor = max(canvas.minScaleFactor, min(canvas.maxScaleFactor, percentage / 100))
        zoom = canvas.scaleFactor
        return true
    }
    func fitPage() { canvas?.finishEditing(commit: true); canvas?.autoScales = true }
    func rememberPosition() {
        guard let canvas else { return }
        ReadingHistory.shared.save(.init(page: pageIndex - 1, scale: canvas.scaleFactor, autoScale: canvas.autoScales), for: owner?.fileURL)
    }
    func unlock(_ password: String) -> Bool {
        guard let pdf, pdf.unlock(withPassword: password) else { return false }
        locked = false
        pageCount = pdf.pageCount
        canvas?.document = pdf
        return true
    }
    deinit {
        requestTask?.cancel()
        undoObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }
}
