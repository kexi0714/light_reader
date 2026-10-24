import AppKit

/// Native tabs retain one NSDocument (and save/undo state) per PDF.
enum ReaderTabs {
    static var activeWindow: NSWindow? {
        NSApp.orderedWindows.first { $0.isVisible && $0.windowController?.document is ReaderDocument }
    }

    static func show(_ document: ReaderDocument, alreadyOpen: Bool, in preferredWindow: NSWindow?) {
        let destination = usableWindow(preferredWindow) ?? activeWindow
        if document.windowControllers.isEmpty { document.makeWindowControllers() }
        guard let window = document.windowControllers.first?.window else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            window.disableScreenUpdatesUntilFlush()
            if !alreadyOpen, let destination, destination !== window {
                (destination.windowController?.document as? ReaderDocument)?.reader.canvas?.finishEditing(commit: true)
                destination.disableScreenUpdatesUntilFlush()
                // Match the existing window before joining its group, so AppKit
                // never presents a centered/default-size window between tabs.
                window.setFrame(destination.frame, display: false, animate: false)
                window.contentView?.layoutSubtreeIfNeeded()
                // Append after all existing file names, even when an earlier tab is selected.
                let last = destination.tabGroup?.windows.last ?? destination
                last.addTabbedWindow(window, ordered: .above)
            }
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.tabGroup?.selectedWindow = window
            window.makeKeyAndOrderFront(nil)
            // Keep the first tab row in the same screen update as ordering in
            // the window, so adding a second PDF cannot shrink the reading area.
            if window.tabGroup?.isTabBarVisible != true { window.toggleTabBar(nil) }
            if !alreadyOpen && destination == nil { WindowPlacement.center(window) }
        }
    }

    private static func usableWindow(_ window: NSWindow?) -> NSWindow? {
        guard let window, window.windowController?.document is ReaderDocument else { return nil }
        let selected = window.tabGroup?.selectedWindow ?? window
        return selected.isVisible || selected.isMiniaturized ? selected : nil
    }
}

final class ReaderWindowController: NSWindowController, NSWindowDelegate {
    override func newWindowForTab(_ sender: Any?) {
        AppDelegate.current?.openDocument(sender)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let document = document as? ReaderDocument else { return }
        document.reader.canvas?.finishEditing(commit: true)
        document.reader.rememberPosition()
    }
}

enum PDFFileDrop {
    static func urls(from pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { $0.isFileURL && $0.pathExtension.lowercased() == "pdf" }
    }

    /// Load providers sequentially so the filename tabs follow the dropped file order.
    @discardableResult
    static func accept(_ providers: [NSItemProvider], in window: NSWindow?) -> Bool {
        let providers = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !providers.isEmpty else { return false }
        load(providers, index: 0, in: window)
        return true
    }

    private static func load(_ providers: [NSItemProvider], index: Int, in window: NSWindow?) {
        guard index < providers.count else { return }
        _ = providers[index].loadObject(ofClass: URL.self) { [weak window] url, _ in
            DispatchQueue.main.async {
                if let url, url.isFileURL, url.pathExtension.lowercased() == "pdf" {
                    AppDelegate.current?.open(url, in: window)
                }
                load(providers, index: index + 1, in: window)
            }
        }
    }
}
