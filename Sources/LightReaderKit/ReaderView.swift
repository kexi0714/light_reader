import SwiftUI
import PDFKit
import UniformTypeIdentifiers

let readerAccent = Color(red: 0.20, green: 0.40, blue: 0.33)

struct ReaderView: View {
    @ObservedObject var state: ReaderState
    @State private var pageEntry = "1"
    @State private var zoomEntry = "100%"
    @FocusState private var zoomIsFocused: Bool
    @State private var password = ""
    @State private var unlockError = false
    @State private var sidebarFraction: CGFloat = 0.25
    @State private var sidebarDragStart: CGFloat?
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { geometry in
                let availableWidth = max(0, geometry.size.width - 1)
                let sidebarWidth = min(max(availableWidth * sidebarFraction, 210), max(210, availableWidth - 470))
                HStack(spacing: 0) {
                    ZStack {
                        PDFCanvasHost(state: state)
                        if state.locked { unlockPanel }
                    }
                    .frame(width: state.sidebarVisible ? max(0, availableWidth - sidebarWidth) : geometry.size.width)
                    .frame(maxHeight: .infinity)
                    if state.sidebarVisible {
                        Divider()
                            .frame(width: 1)
                            .overlay {
                                Color.clear.frame(width: 9).contentShape(Rectangle())
                                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                                        .onChanged { value in
                                            if sidebarDragStart == nil { sidebarDragStart = sidebarWidth }
                                            let width = min(max((sidebarDragStart ?? sidebarWidth) - value.translation.width, 210), max(210, availableWidth - 470))
                                            sidebarFraction = width / max(1, availableWidth)
                                        }
                                        .onEnded { _ in sidebarDragStart = nil })
                            }
                            .accessibilityLabel("调整翻译边栏宽度")
                        TranslationSidebar(state: state).frame(width: sidebarWidth)
                    }
                }
            }
            Divider()
            HStack(spacing: 10) {
                Image(systemName: state.tool == .select ? "cursorarrow" : "pencil.tip.crop.circle")
                    .foregroundStyle(readerAccent)
                Text(state.notice ?? state.toolHint)
                Spacer()
                if let annotation = state.selectedAnnotation {
                    Text(annotation.type == "FreeText" ? "已选中笔记" : annotation.type == "Underline" ? "已选中下划线" : "已选中高亮").foregroundStyle(readerAccent)
                    Button("删除") { state.deleteSelectedAnnotation() }.buttonStyle(.borderless).disabled(!state.canAnnotate)
                }
                Text("\(state.pageCount) 页").monospacedDigit().foregroundStyle(.tertiary)
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 18).frame(height: 30)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            PDFFileDrop.accept(providers, in: state.owner?.windowControllers.first?.window)
        }
        .tint(readerAccent)
        .onChange(of: state.pageIndex) { _, value in pageEntry = String(value) }
        .onAppear { zoomEntry = zoomLabel }
        .onChange(of: state.zoom) { _, _ in if !zoomIsFocused { zoomEntry = zoomLabel } }
        .onChange(of: zoomIsFocused) { _, focused in if !focused { zoomEntry = zoomLabel } }
        .onChange(of: state.tool) { _, _ in state.notice = nil }
    }
    private var toolbar: some View {
        HStack(spacing: 4) {
            toolButton("folder", "打开 PDF（⌘O）") { AppDelegate.current?.openDocument(nil) }
            Button { state.owner?.saveWithEditor(nil) } label: {
                SaveIcon()
                    .stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                    .frame(width: 16, height: 16)
                    .foregroundStyle(Color.primary.opacity(0.75))
                    .frame(width: 29, height: 29)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).help("保存 PDF（⌘S）").accessibilityLabel("保存 PDF（⌘S）")
            separator
            annotationControls
            separator
            navigationControls
            Spacer(minLength: 4)
            toolButton("sidebar.right", "显示或隐藏翻译栏", active: state.sidebarVisible) { state.sidebarVisible.toggle() }
            toolButton("gearshape", "翻译设置（⌘,）") { AppDelegate.current?.showSettings(nil) }
        }
        .padding(.horizontal, 12).frame(height: 45)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    private var annotationControls: some View {
        HStack(spacing: 4) {
            toolButton("cursorarrow", "选择与翻译（Esc）", active: state.tool == .select) { state.setTool(.select) }
            Button { state.setTool(state.tool == .note ? .select : .note) } label: {
                Text("T").font(.system(size: 21, weight: .medium, design: .serif))
                    .frame(width: 29, height: 29)
                    .foregroundStyle(state.tool == .note ? readerAccent : Color.primary.opacity(0.75))
                    .background(state.tool == .note ? readerAccent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain).help("打字机笔记（⌘⇧T）").accessibilityLabel("打字机笔记（⌘⇧T）").disabled(!state.canAnnotate)
            Picker("字号", selection: $state.noteFontSize) {
                ForEach([10.0, 12, 14, 16, 18, 22], id: \.self) { size in Text("\(Int(size)) pt").tag(size) }
            }.labelsHidden().frame(width: 68).help("新笔记字号")
                .accessibilityLabel("打字机字号").disabled(!state.canAnnotate)
            HStack(spacing: 3) {
                ForEach(HighlightColor.allCases, id: \.self) { color in
                    Button { state.selectHighlight(color) } label: {
                        Circle().fill(color.swatch).frame(width: 17, height: 17)
                            .overlay { if state.highlightColor == color { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.black.opacity(0.65)) } }
                            .padding(5).background(state.highlightColor == color ? readerAccent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain).disabled(!state.canAnnotate).help("高亮与下划线颜色：\(color.title)").accessibilityLabel("高亮与下划线颜色：\(color.title)")
                }
            }
            separator
            toolButton("arrow.uturn.backward", "撤销（⌘Z）", disabled: !state.canUndo) { state.undo() }
            toolButton("arrow.uturn.forward", "重做（⌘⇧Z）", disabled: !state.canRedo) { state.redo() }

        }.fixedSize(horizontal: true, vertical: false)
    }
    private var navigationControls: some View {
        HStack(spacing: 4) {
            toolButton("chevron.left", "上一页", disabled: state.pageIndex <= 1) { state.movePage(-1) }
            TextField("页码", text: $pageEntry)
                .textFieldStyle(.plain).multilineTextAlignment(.center).font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(width: 34).padding(.vertical, 5)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
                .onSubmit { state.goToPage(Int(pageEntry) ?? state.pageIndex); pageEntry = String(state.pageIndex) }
                .accessibilityLabel("当前页码")
            Text("/ \(state.pageCount)").font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            toolButton("chevron.right", "下一页", disabled: state.pageIndex >= state.pageCount) { state.movePage(1) }
            separator
            toolButton("minus.magnifyingglass", "缩小（⌘−）") { state.scale(1 / 1.2) }
            TextField("缩放比例", text: $zoomEntry)
                .textFieldStyle(.plain).multilineTextAlignment(.center)
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 56).padding(.vertical, 6)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
                .focused($zoomIsFocused)
                .onSubmit {
                    state.setZoomPercentage(zoomEntry)
                    zoomEntry = zoomLabel
                    zoomIsFocused = false
                }
                .onExitCommand { zoomEntry = zoomLabel; zoomIsFocused = false }
                .help("输入百分比后按回车（20–500%）；适合页面：⌘0")
                .accessibilityLabel("缩放百分比")
            toolButton("plus.magnifyingglass", "放大（⌘+）") { state.scale(1.2) }
        }.fixedSize(horizontal: true, vertical: false)
    }
    private var zoomLabel: String {
        let value = String(format: "%.1f", state.zoom * 100)
        return (value.hasSuffix(".0") ? String(value.dropLast(2)) : value) + "%"
    }
    private var separator: some View { Divider().frame(height: 20).padding(.horizontal, 2) }
    private func toolButton(_ symbol: String, _ help: String, active: Bool = false, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium)).frame(width: 29, height: 29)
                .foregroundStyle(active ? readerAccent : Color.primary.opacity(0.75))
                .background(active ? readerAccent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).help(help).accessibilityLabel(help).disabled(disabled)
    }
    private var unlockPanel: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.doc").font(.system(size: 32)).foregroundStyle(readerAccent)
            Text("这份文献已加密").font(.headline)
            SecureField("PDF 密码", text: $password).textFieldStyle(.roundedBorder).frame(width: 220).onSubmit(unlock)
            if unlockError { Text("密码不正确，请重试。").font(.caption).foregroundStyle(.red) }
            Button("解锁文献", action: unlock).buttonStyle(.borderedProminent)
        }.padding(36).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
    private func unlock() { unlockError = !state.unlock(password); if !unlockError { password = "" } }
}

struct TranslationSidebar: View {
    @ObservedObject var state: ReaderState
    @ObservedObject private var settings = SettingsStore.shared
    @State private var showOriginal = true
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "character.bubble").foregroundStyle(readerAccent)
                Text("划词翻译").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("EN → 中文").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }.padding(.horizontal, 22).padding(.top, 23).padding(.bottom, 18)
            Divider().padding(.horizontal, 22)
            if state.selectedText.isEmpty {
                Spacer()
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: "text.cursor").font(.system(size: 34, weight: .light)).foregroundStyle(readerAccent.opacity(0.7))
                    Text("读到哪里，\n译到哪里。").font(.system(size: 25, weight: .medium)).lineSpacing(5)
                    Text("在左侧选中英文单词、句子或段落，译文会显示在这里。").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5)
                    Button("配置翻译接口 →") { AppDelegate.current?.showSettings(nil) }
                        .buttonStyle(.plain).foregroundStyle(readerAccent).font(.system(size: 12, weight: .medium)).padding(.top, 4)
                }.padding(.horizontal, 28)
                Spacer()
                Spacer().frame(height: 50)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        DisclosureGroup(isExpanded: $showOriginal) {
                            Text(state.selectedText).font(.system(size: 12)).foregroundStyle(.secondary)
                                .lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 9)
                        } label: { Text("原文").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary) }
                        Divider()
                        HStack {
                            Text("译文").font(.system(size: 11, weight: .semibold)).foregroundStyle(readerAccent)
                            Spacer()
                            if !state.translation.isEmpty {
                                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(state.translation, forType: .string) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).help("复制译文").accessibilityLabel("复制译文")
                            }
                            if state.isTranslating {
                                Button { state.cancelTranslation() } label: { Image(systemName: "stop.circle") }.buttonStyle(.plain).help("停止翻译")
                            } else {
                                Button { state.translate(force: true) } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("重新翻译")
                            }
                        }
                        if state.isTranslating {
                            HStack(spacing: 10) { ProgressView().controlSize(.small); Text("正在翻译…").font(.system(size: 12)).foregroundStyle(.secondary) }.padding(.vertical, 4)
                        } else if let error = state.translationError {
                            VStack(alignment: .leading, spacing: 12) {
                                Label("暂时无法翻译", systemImage: "exclamationmark.circle").font(.system(size: 13, weight: .medium))
                                Text(error).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled).lineSpacing(4)
                                HStack {
                                    Button("翻译设置") { AppDelegate.current?.showSettings(nil) }
                                    Button("重试") { state.translate(force: true) }
                                }.controlSize(.small)
                            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                        } else {
                            Text(state.translation.isEmpty ? "翻译已停止。点击右上角重新翻译。" : state.translation)
                                .font(.system(size: 14)).lineSpacing(8).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(22)
                }
            }
            Divider()
            HStack(spacing: 7) {
                Circle().fill(readerAccent.opacity(0.5)).frame(width: 5, height: 5)
                Text(state.translationSource.isEmpty ? settings.configuration.provider.title : state.translationSource)
                Spacer()
                Text("仅发送选中文字")
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 22).frame(height: 37)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// A compact floppy disk, matching the other toolbar icons' outline style.
private struct SaveIcon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 2, y: 1))
        path.addLine(to: CGPoint(x: 15, y: 1))
        path.addLine(to: CGPoint(x: 19, y: 5))
        path.addLine(to: CGPoint(x: 19, y: 18))
        path.addQuadCurve(to: CGPoint(x: 18, y: 19), control: CGPoint(x: 19, y: 19))
        path.addLine(to: CGPoint(x: 2, y: 19))
        path.addQuadCurve(to: CGPoint(x: 1, y: 18), control: CGPoint(x: 1, y: 19))
        path.addLine(to: CGPoint(x: 1, y: 2))
        path.addQuadCurve(to: CGPoint(x: 2, y: 1), control: CGPoint(x: 1, y: 1))
        path.closeSubpath()
        path.addRect(CGRect(x: 5, y: 1, width: 8, height: 6))
        path.move(to: CGPoint(x: 5, y: 19))
        path.addLine(to: CGPoint(x: 5, y: 11))
        path.addLine(to: CGPoint(x: 15, y: 11))
        path.addLine(to: CGPoint(x: 15, y: 19))
        return path.applying(CGAffineTransform(scaleX: rect.width / 20, y: rect.height / 20))
            .applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }
}
