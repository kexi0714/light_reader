import AppKit
import PDFKit
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
        let welcome = try require(NSApp.windows.first { $0.title == "Light Reader" && $0.isVisible })
        defer { welcome.close() }
        let screen = try require(welcome.screen)
        expect(abs(welcome.frame.midX - screen.visibleFrame.midX) <= 1)
        expect(abs(welcome.frame.midY - screen.visibleFrame.midY) <= 1)
        expectEqual(welcome.contentView?.frame.size, NSSize(width: 640, height: 460))
    }

    @MainActor func testNativeDocumentTabs() throws {
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
        expect(windows[0].tabGroup?.isTabBarVisible == true)
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
        let group = try require(windows[0].tabGroup)
        expectEqual(group.windows, Array(windows.prefix(2)))
        expect(group.selectedWindow === windows[1])
        expect(group.isTabBarVisible)

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

        // Reopening a document in another window selects it without moving it.
        ReaderTabs.show(documents[3], alreadyOpen: false, in: windows[1])
        windows[3].moveTabToNewWindow(nil)
        ReaderTabs.show(documents[1], alreadyOpen: true, in: windows[3])
        expectEqual(group.windows.count, 3)
        expect(windows[3].tabGroup !== group)
        expect(group.selectedWindow === windows[1])

        // Closing one tab leaves the other document windows and their states alive.
        documents[2].close()
        expectEqual(group.windows, Array(windows.prefix(2)))
        expect(windows[0].windowController?.document === documents[0])
        expect(windows[1].windowController?.document === documents[1])
        documents[1].close()
        expectEqual(group.windows, [windows[0]])
        expect(group.isTabBarVisible)
        expectEqual(windows[0].frame, originalFrame)
        expectEqual(windows[0].contentView?.frame.size, originalContentSize)
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
