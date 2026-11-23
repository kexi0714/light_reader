import AppKit
import PDFKit
import SwiftUI
@testable import LightReaderKit

final class TabTests {
    @MainActor func testInitialWindowPlacement() throws {
        let visible = NSRect(x: -1920, y: 40, width: 1920, height: 1040)
        let centered = WindowPlacement.centeredFrame(size: NSSize(width: 640, height: 490), visibleFrame: visible)
        expectEqual(centered.midX, visible.midX)
        expectEqual(centered.midY, visible.midY)
        expectEqual(WindowPlacement.centeredFrame(size: NSSize(width: 3000, height: 2000), visibleFrame: visible), visible)
        _ = NSApplication.shared
        let delegate = AppDelegate()
        delegate.showWelcome()
        let welcome = try require(NSApp.windows.first { $0.title == "LiRe" && $0.isVisible })
        defer { welcome.close() }
        let screen = try require(welcome.screen)
        expect(abs(welcome.frame.midX - screen.visibleFrame.midX) <= 1)
        expect(abs(welcome.frame.midY - screen.visibleFrame.midY) <= 1)
        expectEqual(welcome.contentView?.frame.size, NSSize(width: 640, height: 460))
    }

    @MainActor func testDocumentTabs() throws {
        _ = NSApplication.shared
        NSWindow.allowsAutomaticWindowTabbing = true
        let documents = (1...4).map { index in
            let document = ReaderDocument()
            document.displayName = "Tab check \(index).pdf"
            document.reader.pdf = PDFDocument()
            document.makeWindowControllers()
            return document
        }
        defer { documents.forEach { $0.close() } }
        let windows = try documents.map { try require($0.windowControllers.first?.window) }
        ReaderTabs.show(documents[0], alreadyOpen: false, in: nil)
        expect(windows[0].tabGroup?.isTabBarVisible != true)
        let firstScreen = try require(windows[0].screen)
        expect(abs(windows[0].frame.midX - firstScreen.visibleFrame.midX) <= 1)
        expect(abs(windows[0].frame.midY - firstScreen.visibleFrame.midY) <= 1)
        expect(windows.allSatisfy { $0.titleVisibility == .hidden })
        // Exercise a moved, resized window rather than matching default frames.
        windows[0].setFrame(NSRect(x: 80, y: 120, width: 960, height: 680), display: true)
        windows[0].contentView?.layoutSubtreeIfNeeded()
        let originalFrame = windows[0].frame
        let originalContentSize = windows[0].contentView?.frame.size
        ReaderTabs.show(documents[1], alreadyOpen: false, in: windows[0])
        expectEqual(windows[1].frame, originalFrame)
        expectEqual(windows[1].contentView?.frame.size, originalContentSize)
        let group = try require(ReaderTabs.group(of: windows[0]))
        expectEqual(group.windows, Array(windows.prefix(2)))
        expect(group.selectedWindow === windows[1])
        expect(windows.allSatisfy { $0.tabGroup?.isTabBarVisible != true })

        // Opening from an earlier tab still appends at the right end.
        ReaderTabs.show(documents[0], alreadyOpen: true, in: windows[1])
        ReaderTabs.show(documents[2], alreadyOpen: false, in: windows[0])
        expectEqual(group.windows, Array(windows.prefix(3)))
        expect(group.selectedWindow === windows[2])
        expectEqual(windows[2].frame, originalFrame)
        expectEqual(windows[2].contentView?.frame.size, originalContentSize)
        ReaderTabs.show(documents[1], alreadyOpen: true, in: windows[2])
        expectEqual(group.windows.count, 3)
        expect(group.selectedWindow === windows[1])

        group.sidebarFraction = 0.36
        ReaderTabs.moveSelection(by: 1, in: windows[1])
        expect(group.selectedWindow === windows[2])
        expectEqual(ReaderTabs.group(of: windows[2])?.sidebarFraction, 0.36)
        expect(!windows[1].isVisible)
        expect(windows[2].isVisible)
        ReaderTabs.moveSelection(by: -1, in: windows[2])

        // Reopening a document in another window selects it without moving it.
        ReaderTabs.show(documents[3], alreadyOpen: false, in: windows[1])
        ReaderTabs.detach(windows[3])
        ReaderTabs.show(documents[1], alreadyOpen: true, in: windows[3])
        expectEqual(group.windows.count, 3)
        expect(ReaderTabs.group(of: windows[3]) !== group)
        expect(group.selectedWindow === windows[1])

        expectEqual(ReaderTabs.group(of: windows[3])?.sidebarFraction, 0.36)
        ReaderTabs.mergeAll(into: windows[1])
        expectEqual(group.windows.count, 4)
        expect(group.selectedWindow === windows[1])
        expect(!windows[3].isVisible)
        ReaderTabs.detach(windows[3])

        // Closing one tab leaves the other document windows and their states alive.
        documents[2].close()
        expectEqual(group.windows, Array(windows.prefix(2)))
        expect(windows[0].windowController?.document === documents[0])
        expect(windows[1].windowController?.document === documents[1])
        documents[1].close()
        expectEqual(group.windows, [windows[0]])
        expect(windows.allSatisfy { $0.tabGroup?.isTabBarVisible != true })
        expectEqual(windows[0].frame, originalFrame)
        expectEqual(windows[0].contentView?.frame.size, originalContentSize)
    }

    @MainActor func testTabReordering() throws {
        let documents = (0..<4).map { _ in
            let document = ReaderDocument()
            document.reader.pdf = PDFDocument()
            document.makeWindowControllers()
            return document
        }
        defer { documents.forEach { $0.close() } }
        let windows = try documents.map { try require($0.windowControllers.first?.window) }
        ReaderTabs.show(documents[0], alreadyOpen: false, in: nil)
        for index in 1..<3 { ReaderTabs.show(documents[index], alreadyOpen: false, in: windows[0]) }
        let group = try require(ReaderTabs.group(of: windows[0]))
        group.select(windows[1])
        let frame = windows[1].frame
        let content = windows[1].contentView
        documents[1].reader.selectedText = "Keep this selection"
        group.sidebarFraction = 0.34

        // Drag an inactive tab right, then the active tab right, then back left.
        group.move(ObjectIdentifier(windows[0]), to: 2)
        expectEqual(group.windows, [windows[1], windows[2], windows[0]])
        group.move(ObjectIdentifier(windows[1]), to: 2)
        expectEqual(group.windows, [windows[2], windows[0], windows[1]])
        group.move(ObjectIdentifier(windows[1]), to: 0)
        expectEqual(group.windows, [windows[1], windows[2], windows[0]])
        expect(group.selectedWindow === windows[1])
        expect(windows[1].isVisible)
        expectEqual(windows[1].frame, frame)
        expect(windows[1].contentView === content)
        expectEqual(documents[1].reader.selectedText, "Keep this selection")
        expectEqual(group.sidebarFraction, 0.34)

        group.move(ObjectIdentifier(windows[3]), to: 0)
        group.move(ObjectIdentifier(windows[1]), to: -1)
        group.move(ObjectIdentifier(windows[1]), to: 3)
        group.move(ObjectIdentifier(windows[1]), to: 0)
        expectEqual(group.windows, [windows[1], windows[2], windows[0]])
        ReaderTabs.moveSelection(by: 1, in: windows[1])
        expect(group.selectedWindow === windows[2])
        ReaderTabs.show(documents[3], alreadyOpen: false, in: windows[2])
        expectEqual(group.windows, [windows[1], windows[2], windows[0], windows[3]])
        group.select(windows[2])
        documents[2].close()
        expectEqual(group.windows, [windows[1], windows[0], windows[3]])
        expect(group.selectedWindow === windows[0])
        ReaderTabs.detach(windows[3])
        expectEqual(group.windows, [windows[1], windows[0]])
        ReaderTabs.mergeAll(into: windows[0])
        // Other tests may still have closed NSWindowControllers registered with AppKit.
        expectEqual(group.windows.filter { windows.contains($0) }, [windows[1], windows[0], windows[3]])
        expectEqual(Array(group.windows.prefix(2)), [windows[1], windows[0]])

        // Equal-width card hit testing includes gaps and clamps either edge.
        expectEqual(ReaderTabBar.destination(at: -100, width: 608, count: 3), 0)
        expectEqual(ReaderTabBar.destination(at: 100, width: 608, count: 3), 0)
        expectEqual(ReaderTabBar.destination(at: 304, width: 608, count: 3), 1)
        expectEqual(ReaderTabBar.destination(at: 508, width: 608, count: 3), 2)
        expectEqual(ReaderTabBar.destination(at: 900, width: 608, count: 3), 2)
        expectEqual(ReaderTabBar.destination(at: 100, width: 608, count: 1), 0)
        expectEqual(ReaderTabBar.destination(at: 100, width: 608, count: 0), nil)
        expectEqual(ReaderTabBar.destination(at: 100, width: 0, count: 3), nil)
    }

    @MainActor func testTabDragGesture() throws {
        let group = ReaderTabGroup()
        let windows = (0..<3).map { index in
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 616, height: 38),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Document \(index)"
            group.append(window)
            return window
        }
        let host = NSHostingView(rootView: ReaderTabBar(group: group))
        let testWindow = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 616, height: 38),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
        testWindow.isReleasedWhenClosed = false
        testWindow.contentView = host
        defer { testWindow.close(); windows.forEach { $0.close() } }
        group.select(windows[1])
        testWindow.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        func send(from start: CGFloat, to end: CGFloat, drag: Bool) throws {
            let points: [(NSEvent.EventType, CGFloat)] = drag
                ? [(.leftMouseDown, start), (.leftMouseDragged, start + (end - start) / 2), (.leftMouseDragged, end), (.leftMouseUp, end)]
                : [(.leftMouseDown, start), (.leftMouseUp, end)]
            for (index, item) in points.enumerated() {
                let event = try require(NSEvent.mouseEvent(with: item.0, location: NSPoint(x: item.1, y: 19),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + Double(index) * 0.02,
                    windowNumber: testWindow.windowNumber, context: nil,
                    eventNumber: index, clickCount: 1, pressure: item.0 == .leftMouseUp ? 0 : 1))
                NSApp.postEvent(event, atStart: false)
            }
            let deadline = Date().addingTimeInterval(0.2)
            while Date() < deadline, let event = NSApp.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            host.layoutSubtreeIfNeeded()
        }
        try send(from: 104, to: 512, drag: true)
        expectEqual(group.windows, [windows[1], windows[2], windows[0]])
        expect(group.selectedWindow === windows[1])
        try send(from: 512, to: 104, drag: true)
        expectEqual(group.windows, windows)
        expect(group.selectedWindow === windows[1])
        try send(from: 512, to: 512, drag: false)
        expect(group.selectedWindow === windows[2])
        expectEqual(group.windows, windows)
    }

    @MainActor func testResizableReaderPanes() throws {
        _ = NSApplication.shared
        let split = ReaderSplitContainer(left: Text("PDF"), right: Text("Translation"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 700),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = split
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        split.resizeSubviews(withOldSize: .zero)
        expectEqual(split.rightHost.frame.width, (1180 - 8) * 0.25)
        expectEqual(split.leftHost.frame.height, split.rightHost.frame.height)
        expectEqual(split.leftHost.frame.minY, split.rightHost.frame.minY)
        let dividerPoint = NSPoint(x: split.leftHost.frame.maxX + 4, y: 350)
        expect(split.hitTest(dividerPoint) === split)
        var reportedFraction: CGFloat = 0
        split.onFractionChange = { reportedFraction = $0 }
        let location = split.convert(dividerPoint, to: nil)
        let target = NSPoint(x: location.x - 120, y: location.y)
        // Exercise NSSplitView's actual mouse tracking, not a custom width setter.
        let down = try require(NSEvent.mouseEvent(with: .leftMouseDown, location: location,
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        for type in [NSEvent.EventType.leftMouseDragged, .leftMouseUp] {
            let event = try require(NSEvent.mouseEvent(with: type, location: target,
                        modifierFlags: [], timestamp: 0.1, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
            NSApp.postEvent(event, atStart: false)
        }
        split.mouseDown(with: down)
        // AppKit aligns the pointer within the divider; allow half its hit width.
        expect(abs(split.rightHost.frame.width - 413) <= split.dividerThickness / 2)
        expect(abs(reportedFraction - split.rightHost.frame.width / 1172) < 0.001)
        let fraction = split.sidebarFraction
        window.setContentSize(NSSize(width: 960, height: 700))
        expect(abs(split.rightHost.frame.width - 952 * fraction) <= 1)
        split.configure(fraction: fraction, visible: false)
        expectEqual(split.leftHost.frame.width, split.bounds.width)
        expect(split.rightHost.isHidden)
        split.configure(fraction: fraction, visible: true)
        expect(!split.rightHost.isHidden)
        expect(abs(split.rightHost.frame.width - 952 * fraction) <= 1)
        split.configure(fraction: 0.99, visible: true)
        expectEqual(split.leftHost.frame.width, 470)
        split.configure(fraction: 0.01, visible: true)
        expectEqual(split.rightHost.frame.width, 210)
    }

    @MainActor func testPDFDropFiltering() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let first = URL(fileURLWithPath: "/tmp/paper-one.pdf")
        let second = URL(fileURLWithPath: "/tmp/paper-two.PDF")
        pasteboard.writeObjects([first as NSURL, URL(fileURLWithPath: "/tmp/notes.txt") as NSURL, second as NSURL])
        expectEqual(PDFFileDrop.urls(from: pasteboard), [first, second])
        pasteboard.clearContents()
        pasteboard.setString("Not a file", forType: .string)
        expect(PDFFileDrop.urls(from: pasteboard).isEmpty)
        expect(!PDFFileDrop.accept([], in: nil))
    }
}
