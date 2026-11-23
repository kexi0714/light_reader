import AppKit
import SwiftUI

/// Keep independent NSDocuments while drawing tabs inside the reading pane.
/// Weak window references avoid retaining closed documents through their views.
final class ReaderTabGroup: ObservableObject {
    struct Entry: Identifiable {
        let id: ObjectIdentifier
        weak var window: NSWindow?
        var title: String { window?.title ?? "PDF" }
    }
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var selectedID: ObjectIdentifier?
    @Published var sidebarFraction: CGFloat = 0.25
    var windows: [NSWindow] { entries.compactMap(\.window) }
    var selectedWindow: NSWindow? { entries.first { $0.id == selectedID }?.window }

    func append(_ window: NSWindow) {
        guard !windows.contains(where: { $0 === window }) else { return }
        entries.append(Entry(id: ObjectIdentifier(window), window: window))
    }

    /// Reorder without activating windows or rebuilding their document views.
    func move(_ id: ObjectIdentifier, to destination: Int) {
        guard let source = entries.firstIndex(where: { $0.id == id }),
              entries.indices.contains(destination), source != destination else { return }
        var reordered = entries
        let entry = reordered.remove(at: source)
        reordered.insert(entry, at: destination)
        entries = reordered
    }

    func select(_ window: NSWindow) {
        guard windows.contains(where: { $0 === window }) else { return }
        let previous = selectedWindow
        if let previous, previous !== window {
            let reader = (previous.windowController?.document as? ReaderDocument)?.reader
            reader?.canvas?.finishEditing(commit: true)
            reader?.rememberPosition()
            window.setFrame(previous.frame, display: false, animate: false)
            (window.windowController?.document as? ReaderDocument)?.reader.sidebarVisible = reader?.sidebarVisible ?? true
        }
        window.disableScreenUpdatesUntilFlush()
        selectedID = ObjectIdentifier(window)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        if previous !== window { previous?.orderOut(nil) }
    }

    func remove(_ window: NSWindow) {
        guard let index = windows.firstIndex(where: { $0 === window }) else { return }
        let wasSelected = selectedWindow === window
        let remaining = windows.filter { $0 !== window }
        if wasSelected, !remaining.isEmpty {
            select(remaining[min(index, remaining.count - 1)])
        }
        entries.removeAll { $0.window == nil || $0.window === window }
        if entries.isEmpty { selectedID = nil }
    }

    func refreshTitles() { objectWillChange.send() }
}

enum ReaderTabs {
    static var activeWindow: NSWindow? {
        NSApp.orderedWindows.first { $0.isVisible && $0.windowController?.document is ReaderDocument }
    }

    static func group(of window: NSWindow?) -> ReaderTabGroup? {
        (window?.windowController as? ReaderWindowController)?.tabs
    }

    static func show(_ document: ReaderDocument, alreadyOpen: Bool, in preferredWindow: NSWindow?) {
        let destination = group(of: preferredWindow)?.selectedWindow ?? activeWindow
        if document.windowControllers.isEmpty { document.makeWindowControllers() }
        guard let controller = document.windowControllers.first as? ReaderWindowController,
              let window = controller.window else { return }
        if !alreadyOpen, let destination, destination !== window, let group = group(of: destination) {
            controller.tabs.remove(window)
            controller.setTabs(group)
            group.append(window)
        }
        controller.tabs.select(window)
        if !alreadyOpen && destination == nil { WindowPlacement.center(window) }
    }

    static func moveSelection(by offset: Int, in window: NSWindow?) {
        guard let group = group(of: window), let selected = group.selectedWindow,
              let index = group.windows.firstIndex(where: { $0 === selected }) else { return }
        let windows = group.windows
        group.select(windows[(index + offset + windows.count) % windows.count])
    }

    static func detach(_ window: NSWindow?) {
        guard let window, let controller = window.windowController as? ReaderWindowController,
              controller.tabs.windows.count > 1 else { return }
        let frame = window.frame
        let fraction = controller.tabs.sidebarFraction
        controller.tabs.remove(window)
        let group = ReaderTabGroup()
        group.sidebarFraction = fraction
        controller.setTabs(group)
        group.append(window)
        window.setFrame(frame.offsetBy(dx: 24, dy: -24), display: false)
        group.select(window)
    }

    static func mergeAll(into window: NSWindow?) {
        guard let window, let group = group(of: window) else { return }
        let others = NSApp.windows.compactMap { $0.windowController as? ReaderWindowController }
        for controller in others where controller.tabs !== group {
            guard let other = controller.window else { continue }
            controller.tabs.remove(other)
            controller.setTabs(group)
            group.append(other)
            other.orderOut(nil)
        }
        group.select(window)
    }
}

final class ReaderWindowController: NSWindowController, NSWindowDelegate {
    private(set) var tabs = ReaderTabGroup()

    func setTabs(_ group: ReaderTabGroup) {
        tabs = group
        if let document = document as? ReaderDocument,
           let host = window?.contentViewController as? NSHostingController<ReaderView> {
            host.rootView = ReaderView(state: document.reader, tabs: group)
        }
    }

    override func showWindow(_ sender: Any?) {
        if let window { tabs.select(window) }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Also handle document activation from the system Window menu or Dock.
        if let window, tabs.selectedWindow !== window { tabs.select(window) }
    }

    override func synchronizeWindowTitleWithDocumentName() {
        super.synchronizeWindowTitleWithDocumentName()
        tabs.refreshTitles()
    }

    func windowWillClose(_ notification: Notification) {
        if let window { tabs.remove(window) }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let document = document as? ReaderDocument else { return }
        document.reader.canvas?.finishEditing(commit: true)
        document.reader.rememberPosition()
    }
}

struct ReaderTabBar: View {
    @ObservedObject var group: ReaderTabGroup
    private struct TabDrag {
        let id: ObjectIdentifier
        let translation: CGFloat
        let destination: Int
    }
    @GestureState private var drag: TabDrag?

    // The geometry is the inner strip, excluding its four-point outer padding.
    static func destination(at x: CGFloat, width: CGFloat, count: Int) -> Int? {
        guard count > 0, width > 0, x.isFinite, width.isFinite else { return nil }
        let stride = (width + 4) / CGFloat(count)
        return Int(min(CGFloat(count - 1), max(0, floor((x + 2) / stride))))
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 4) {
                ForEach(group.entries) { entry in
                    tab(entry, width: geometry.size.width)
                        .offset(x: drag?.id == entry.id ? drag?.translation ?? 0 : 0)
                        .zIndex(drag?.id == entry.id ? 1 : 0)
                }
            }
            .coordinateSpace(name: "readerTabStrip")
        }
        .padding(.horizontal, 4).padding(.vertical, 4)
        .frame(height: 38)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain).accessibilityLabel("文献标签栏")
    }

    private func tab(_ entry: ReaderTabGroup.Entry, width: CGFloat) -> some View {
        let selected = group.selectedID == entry.id
        let destination = drag.map { group.entries.indices.contains($0.destination) && group.entries[$0.destination].id == entry.id } ?? false
        return Button { if let window = entry.window { group.select(window) } } label: {
            Text(entry.title)
                .font(.system(size: 12, weight: selected ? .medium : .regular))
                .foregroundStyle(Color.primary.opacity(selected ? 1 : 0.7))
                .lineLimit(1).truncationMode(.middle)
                // Reserve equal space on both sides so the close button never shifts the title.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("\(entry.title)\n左右拖动可调整顺序")
        .frame(minWidth: 0, maxWidth: .infinity)
        .background(selected || drag?.id == entry.id ? Color(nsColor: .textBackgroundColor) : Color.primary.opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(destination ? readerAccent : Color.primary.opacity(selected ? 0.28 : 0.12),
                              lineWidth: destination ? 2 : 1)
        }
        .highPriorityGesture(
            DragGesture(minimumDistance: 8, coordinateSpace: .named("readerTabStrip"))
                .updating($drag) { value, state, _ in
                    guard group.entries.count > 1,
                          let target = Self.destination(at: value.location.x, width: width, count: group.entries.count) else { return }
                    state = TabDrag(id: entry.id, translation: value.translation.width, destination: target)
                }
                .onEnded { value in
                    guard let target = Self.destination(at: value.location.x, width: width, count: group.entries.count) else { return }
                    group.move(entry.id, to: target)
                }
        )
        // Keep the close button outside the title's drag gesture.
        .overlay(alignment: .trailing) {
            Button {
                guard let window = entry.window else { return }
                // Unsaved changes must present their save sheet on a visible tab.
                if (window.windowController?.document as? NSDocument)?.isDocumentEdited == true {
                    group.select(window)
                }
                window.performClose(nil)
            } label: {
                Image(systemName: "xmark").font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }.buttonStyle(.plain).help("关闭文献").accessibilityLabel("关闭 \(entry.title)")
            .padding(.trailing, 2)
        }
        .clipped()
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
