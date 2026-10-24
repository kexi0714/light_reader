import AppKit
import SwiftUI
import UniformTypeIdentifiers

public final class AppDelegate: NSObject, NSApplicationDelegate {
    static var current: AppDelegate? { NSApp.delegate as? AppDelegate }
    private var welcomeWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private struct PendingOpen {
        let url: URL
        weak var window: NSWindow?
    }
    private var pendingOpens: [PendingOpen] = []
    private var isOpeningDocument = false

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
        installMenus()
        if NSDocumentController.shared.documents.isEmpty { showWelcome() }
        NSApp.activate(ignoringOtherApps: true)
    }
    public func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWelcome() }
        return true
    }
    public func application(_ sender: NSApplication, openFiles filenames: [String]) {
        filenames.forEach { open(URL(fileURLWithPath: $0)) }
        sender.reply(toOpenOrPrint: .success)
    }
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for document in NSDocumentController.shared.documents.compactMap({ $0 as? ReaderDocument }) {
            document.reader.canvas?.finishEditing(commit: true)
            document.reader.rememberPosition()
        }
        NSDocumentController.shared.reviewUnsavedDocuments(withAlertTitle: "退出 Light Reader", cancellable: true,
            delegate: self, didReviewAllSelector: #selector(didReviewDocuments(_:didReviewAll:contextInfo:)), contextInfo: nil)
        return .terminateLater
    }
    @objc private func didReviewDocuments(_ controller: NSDocumentController, didReviewAll: Bool, contextInfo: UnsafeMutableRawPointer?) {
        NSApp.reply(toApplicationShouldTerminate: didReviewAll)
    }
    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "打开文献"
        let destination = ReaderTabs.activeWindow
        panel.begin { [weak self, weak destination] result in
            if result == .OK { panel.urls.forEach { self?.open($0, in: destination) } }
        }
    }
    func open(_ url: URL, in window: NSWindow? = nil) {
        pendingOpens.append(PendingOpen(url: url, window: window ?? ReaderTabs.activeWindow))
        openNextDocument()
    }
    private func openNextDocument() {
        guard !isOpeningDocument, !pendingOpens.isEmpty else { return }
        isOpeningDocument = true
        let request = pendingOpens.removeFirst()
        // Serial opening keeps a multi-file drop in order and avoids duplicate tabs.
        NSDocumentController.shared.openDocument(withContentsOf: request.url, display: false) { [weak self] document, alreadyOpen, error in
            guard let self else { return }
            if let error {
                NSApp.presentError(error)
            } else if let document = document as? ReaderDocument {
                ReaderTabs.show(document, alreadyOpen: alreadyOpen, in: request.window)
                self.welcomeWindow?.orderOut(nil)
            }
            self.isOpeningDocument = false
            self.openNextDocument()
        }
    }
    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.tabbingMode = .disallowed
            window.title = "翻译设置"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 530, height: 580))
            WindowPlacement.center(window)
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func showWelcome() {
        if welcomeWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: WelcomeView()))
            window.tabbingMode = .disallowed
            window.title = "Light Reader"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            welcomeWindow = window
        }
        guard let window = welcomeWindow else { return }
        let needsCentering = !window.isVisible
        window.disableScreenUpdatesUntilFlush()
        window.contentViewController = NSHostingController(rootView: WelcomeView())
        // Resolve the final SwiftUI size before positioning. Centering the initial
        // zero-sized host makes the eventual welcome view grow toward a corner.
        window.setContentSize(NSSize(width: 640, height: 460))
        if needsCentering { WindowPlacement.center(window) }
        window.makeKeyAndOrderFront(nil)
    }
    private var activeReader: ReaderState? { (NSApp.mainWindow?.windowController?.document as? ReaderDocument)?.reader }
    @objc func zoomIn(_ sender: Any?) { activeReader?.scale(1.2) }
    @objc func zoomOut(_ sender: Any?) { activeReader?.scale(1 / 1.2) }
    @objc func fitPage(_ sender: Any?) { activeReader?.fitPage() }
    @objc func noteTool(_ sender: Any?) { activeReader?.setTool(.note) }
    @objc func selectTool(_ sender: Any?) { activeReader?.setTool(.select) }
    @objc func toggleSidebar(_ sender: Any?) { activeReader?.sidebarVisible.toggle() }
    @objc func undo(_ sender: Any?) { activeReader?.undo() }
    @objc func redo(_ sender: Any?) { activeReader?.redo() }

    private func installMenus() {
        let main = NSMenu()
        func menu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            item.submenu = submenu
            main.addItem(item)
            return submenu
        }
        func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "", target: AnyObject? = nil, modifiers: NSEvent.ModifierFlags = .command) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = target
            item.keyEquivalentModifierMask = modifiers
            menu.addItem(item)
        }
        let app = menu("Light Reader")
        item(app, "关于 Light Reader", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp)
        app.addItem(.separator())
        item(app, "翻译设置…", #selector(showSettings(_:)), ",", target: self)
        app.addItem(.separator())
        item(app, "隐藏 Light Reader", #selector(NSApplication.hide(_:)), "h", target: NSApp)
        item(app, "隐藏其他", #selector(NSApplication.hideOtherApplications(_:)), "h", target: NSApp, modifiers: [.command, .option])
        item(app, "显示全部", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp)
        app.addItem(.separator())
        item(app, "退出 Light Reader", #selector(NSApplication.terminate(_:)), "q", target: NSApp)
        let file = menu("文件")
        item(file, "打开 PDF…", #selector(openDocument(_:)), "o", target: self)
        item(file, "欢迎窗口", #selector(showWelcome), "n", target: self)
        file.addItem(.separator())
        item(file, "保存", #selector(ReaderDocument.saveWithEditor(_:)), "s")
        item(file, "另存为…", #selector(NSDocument.saveAs(_:)), "s", modifiers: [.command, .shift])
        file.addItem(.separator())
        item(file, "关闭文献", #selector(NSWindow.performClose(_:)), "w")
        let edit = menu("编辑")
        item(edit, "撤销", #selector(undo(_:)), "z")
        item(edit, "重做", #selector(redo(_:)), "z", modifiers: [.command, .shift])
        edit.addItem(.separator())
        item(edit, "剪切", #selector(NSText.cut(_:)), "x")
        item(edit, "拷贝", #selector(NSText.copy(_:)), "c")
        item(edit, "粘贴", #selector(NSText.paste(_:)), "v")
        item(edit, "全选", #selector(NSText.selectAll(_:)), "a")
        let view = menu("显示")
        item(view, "放大", #selector(zoomIn(_:)), "=", target: self)
        item(view, "缩小", #selector(zoomOut(_:)), "-", target: self)
        item(view, "适合页面", #selector(fitPage(_:)), "0", target: self)
        item(view, "显示或隐藏翻译栏", #selector(toggleSidebar(_:)), "t", target: self, modifiers: [.command, .option])
        view.addItem(.separator())
        item(view, "选择与翻译", #selector(selectTool(_:)), "1", target: self)
        item(view, "打字机笔记", #selector(noteTool(_:)), "t", target: self, modifiers: [.command, .shift])
        let window = menu("窗口")
        item(window, "最小化", #selector(NSWindow.performMiniaturize(_:)), "m")
        item(window, "缩放", #selector(NSWindow.performZoom(_:)))
        window.addItem(.separator())
        item(window, "上一个文献标签", #selector(NSWindow.selectPreviousTab(_:)), "[", modifiers: [.command, .shift])
        item(window, "下一个文献标签", #selector(NSWindow.selectNextTab(_:)), "]", modifiers: [.command, .shift])
        item(window, "将标签移到新窗口", #selector(NSWindow.moveTabToNewWindow(_:)))
        item(window, "合并所有文献窗口", #selector(NSWindow.mergeAllWindows(_:)))
        window.addItem(.separator())
        item(window, "前置全部窗口", #selector(NSApplication.arrangeInFront(_:)), target: NSApp)
        NSApp.windowsMenu = window
        NSApp.mainMenu = main
    }
}

struct WelcomeView: View {
    @State private var dropTarget = false
    private var recent: [URL] { Array(NSDocumentController.shared.recentDocumentURLs.filter { FileManager.default.fileExists(atPath: $0.path) }.prefix(3)) }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "book.pages").font(.system(size: 45, weight: .ultraLight)).foregroundStyle(readerAccent)
                    .frame(width: 82, height: 82).background(readerAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 22))
                VStack(alignment: .leading, spacing: 8) {
                    Text("Light Reader").font(.system(size: 31, weight: .semibold, design: .rounded))
                    Text("让阅读，轻一点。").font(.system(size: 18)).foregroundStyle(.secondary)
                }
                Text("读英文文献，留下自己的思考。\n划词翻译、三色高亮、随处笔记。").font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(7)
                Button { AppDelegate.current?.openDocument(nil) } label: {
                    Label("打开 PDF 文献", systemImage: "plus").font(.system(size: 13, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 5)
                }.buttonStyle(.borderedProminent).controlSize(.large)
                Text("或将 PDF 拖到这里  ·  ⌘O").font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Button("翻译接口设置 →") { AppDelegate.current?.showSettings(nil) }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(readerAccent)
            }.padding(40).frame(width: 350)
            Divider()
            VStack(alignment: .leading, spacing: 26) {
                Text("专注于文献本身").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                feature("text.cursor", "划选即译", "译文在右侧，阅读不中断。")
                feature("highlighter", "标记重点", "浅绿、浅橙、浅蓝，刚刚好。")
                feature("t.square", "随处写下想法", "点击打字，笔记随 PDF 保存。")
                if !recent.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("最近打开").font(.system(size: 11)).foregroundStyle(.secondary)
                        ForEach(recent, id: \.self) { url in
                            Button { AppDelegate.current?.open(url) } label: {
                                Label(url.deletingPathExtension().lastPathComponent, systemImage: "doc.richtext").font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                            }.buttonStyle(.plain).help(url.path)
                        }
                    }
                }
                Spacer(minLength: 0)
            }.padding(32).frame(width: 290)
        }
        .frame(width: 640, height: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay { if dropTarget { RoundedRectangle(cornerRadius: 8).stroke(readerAccent, lineWidth: 3).padding(5) } }
        .tint(readerAccent)
        .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in
            PDFFileDrop.accept(providers, in: ReaderTabs.activeWindow)
        }
    }
    private func feature(_ symbol: String, _ title: String, _ subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(readerAccent).frame(width: 24)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}
