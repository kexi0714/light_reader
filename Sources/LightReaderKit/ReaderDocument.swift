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
        let host = NSHostingController(rootView: ReaderView(state: reader))
        let window = NSWindow(contentViewController: host)
        window.setContentSize(NSSize(width: 1180, height: 800))
        window.minSize = NSSize(width: 860, height: 560)
        window.title = displayName
        window.titleVisibility = .hidden
        window.animationBehavior = .none
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.tabbingIdentifier = "LightReader.PDF"
        window.tabbingMode = .preferred
        window.center()
        let controller = ReaderWindowController(window: window)
        window.delegate = controller
        addWindowController(controller)
    }
    public override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        reader.canvas?.finishEditing(commit: true)
        super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
    }
    public override func close() {
        reader.rememberPosition()
        reader.cancelTranslation()
        super.close()
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
        switch self { case .green: return "浅绿色"; case .orange: return "浅橙色"; case .blue: return "浅蓝色" }
    }
    var color: NSColor {
        switch self {
        case .green: return NSColor(srgbRed: 0.56, green: 0.83, blue: 0.59, alpha: 0.48)
        case .orange: return NSColor(srgbRed: 1.0, green: 0.73, blue: 0.40, alpha: 0.45)
        case .blue: return NSColor(srgbRed: 0.48, green: 0.74, blue: 0.96, alpha: 0.42)
        }
    }
    var swatch: Color { Color(nsColor: color.withAlphaComponent(1)) }
}

struct PlacedAnnotation {
    let page: PDFPage
    let annotation: PDFAnnotation
}

final class ReaderState: ObservableObject {
    weak var owner: ReaderDocument?
    weak var canvas: PDFCanvas?
    @Published var pdf: PDFDocument?
    @Published var tool: ReaderTool = .select
    @Published private(set) var highlightColor: HighlightColor = .green
    @Published var pageIndex = 1
    @Published var pageCount = 0
    @Published var zoom = 1.0
    @Published var selectedText = ""
    @Published var translation = ""
    @Published var translationSource = ""
    @Published var translationError: String?
    @Published var isTranslating = false
    @Published var sidebarVisible = true
    @Published var selectedAnnotation: PDFAnnotation?
    @Published var noteFontSize = 14.0
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
        if isEditingNote { return "正在输入笔记 · 点击框外完成并划词 · ⌘↩ 完成 · Esc 取消" }
        switch tool {
        case .select: return "划词翻译 · 右键高亮 · 单击笔记可编辑"
        case .note: return "点击页面添加笔记 · ⌘↩ 完成 · Esc 取消"
        }
    }
    func setTool(_ newTool: ReaderTool) {
        canvas?.finishEditing(commit: true)
        selectedAnnotation = nil
        tool = newTool
        canvas?.window?.makeFirstResponder(canvas)
    }
    func selectHighlight(_ color: HighlightColor) {
        highlightColor = color
    }
    func highlight(_ selection: PDFSelection, color: HighlightColor) {
        addTextMarkup(selection, type: .highlight, color: color.color, action: "添加高亮")
    }
    func underline(_ selection: PDFSelection) {
        addTextMarkup(selection, type: .underline, color: highlightColor.color, action: "添加下划线")
    }
    private func addTextMarkup(_ selection: PDFSelection, type: PDFAnnotationSubtype, color: NSColor, action: String) {
        guard canAnnotate else { notice = "这份 PDF 不允许添加标注。"; return }
        let annotations = selection.selectionsByLine().flatMap { line -> [PlacedAnnotation] in
            line.pages.compactMap { page in
                let bounds = line.bounds(for: page)
                guard !bounds.isEmpty, !bounds.isInfinite else { return nil }
                let annotation = PDFAnnotation(bounds: bounds, forType: type, withProperties: nil)
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
        guard canAnnotate, let annotation = selectedAnnotation, let page = annotation.page else { return }
        replaceAnnotations(removing: [.init(page: page, annotation: annotation)], adding: [], action: "删除标注")
    }
    func acceptSelection(_ selection: PDFSelection?) {
        guard let raw = selection?.string else { return }
        let text = TextPreparation.normalize(raw)
        guard !text.isEmpty else { return }
        selectedAnnotation = nil
        selectedText = text
        translate()
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
