import AppKit
import SwiftUI
@testable import LightReaderKit

final class OriginalTextTests {
    @MainActor func testRetranslateMenuUsesEntireEditedText() throws {
        let view = OriginalTextView(frame: NSRect(x: 0, y: 0, width: 280, height: 200))
        let event = try require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        var submissions: [String] = []
        view.onRetranslate = { submissions.append($0) }
        view.string = "Original sentence."
        view.setSelectedRange(NSRange(location: 0, length: view.string.utf16.count))
        view.insertText("Edited sentence.\nSecond paragraph.", replacementRange: view.selectedRange())
        view.setSelectedRange(NSRange(location: 0, length: 6))
        let menu = try require(view.menu(for: event))
        expectEqual(menu.items.map(\.title), ["重新翻译", "复制"])
        let item = try require(menu.items.first)
        expect(item.isEnabled)
        expect(menu.items[1].isEnabled)
        NSPasteboard.general.clearContents()
        let copyAction = try require(menu.items[1].action)
        expect(NSApp.sendAction(copyAction, to: menu.items[1].target, from: menu.items[1]))
        expectEqual(NSPasteboard.general.string(forType: .string), "Edited")
        let action = try require(item.action)
        expect(NSApp.sendAction(action, to: item.target, from: item))
        expectEqual(submissions, ["Edited sentence.\nSecond paragraph."])
        for empty in ["", " \n\t"] {
            view.string = empty
            expectEqual(view.menu(for: event)?.items.first?.isEnabled, false)
            view.retranslate(nil)
        }
        expectEqual(submissions.count, 1)
    }

    @MainActor func testOriginalEditorUndoIsIndependent() {
        let first = OriginalTextView(frame: .zero)
        let second = OriginalTextView(frame: .zero)
        first.allowsUndo = true
        first.undoManager?.beginUndoGrouping()
        first.insertText("New draft", replacementRange: NSRange(location: 0, length: 0))
        first.undoManager?.endUndoGrouping()
        expectEqual(first.string, "New draft")
        expect(first.undoManager !== second.undoManager)
        expect(first.undoManager?.canUndo == true)
        expect(second.undoManager?.canUndo == false)
        first.undoManager?.undo()
        expectEqual(first.string, "")
        first.undoManager?.redo()
        expectEqual(first.string, "New draft")
    }
    @MainActor func testSidebarTextSelectionAndScaling() throws {
        for editable in [false, true] {
            let host = NSHostingView(rootView: OriginalTextEditor(text: .constant("First line.\nSecond line."),
                fontSize: 14, editable: editable))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 220),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            defer { window.close() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
            func findText(_ view: NSView) -> OriginalTextView? {
                if let text = view as? OriginalTextView { return text }
                return view.subviews.compactMap { findText($0) }.first
            }
            let text = try require(findText(host))
            expectEqual(text.isEditable, editable)
            expect(text.isSelectable)
            // Both the horizontal inset and empty space below text belong to the text view.
            let left = NSPoint(x: 3, y: 10)
            let bottom = NSPoint(x: text.bounds.midX, y: text.bounds.maxY - 5)
            expect(text.hitTest(text.convert(left, to: text.superview)) === text)
            expect(text.hitTest(text.convert(bottom, to: text.superview)) === text)
            expectEqual(text.characterIndexForInsertion(at: bottom), text.string.utf16.count)
            window.makeFirstResponder(text)
            expect(window.firstResponder === text)
            expect(NSApp.sendAction(#selector(NSText.selectAll(_:)), to: window.firstResponder, from: nil))
            expectEqual(text.selectedRange(), NSRange(location: 0, length: text.string.utf16.count))
            text.setSelectedRange(NSRange(location: 3, length: 4))
            text.applyTypography(fontSize: 28, lineSpacing: 12)
            expectEqual(text.font?.pointSize, 28)
            expectEqual(text.selectedRange(), NSRange(location: 3, length: 4))
            expectEqual(text.string, "First line.\nSecond line.")
        }
    }

    @MainActor func testContinuousSidebarEditing() throws {
        var draft = "Editable original."
        var submitted = ""
        let root = TranslationTextEditor(original: Binding(get: { draft }, set: { draft = $0 }),
            translation: "译文保持常规字重。", scale: 1.7, onRetranslate: { submitted = $0 })
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 700),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        func findText(_ view: NSView) -> TranslationTextView? {
            if let text = view as? TranslationTextView { return text }
            return view.subviews.compactMap { findText($0) }.first
        }
        let view = try require(findText(host))
        view.selectAll(nil)
        expectEqual(view.selectedRange(), NSRange(location: 0, length: view.string.utf16.count))
        expect(view.selectedRange().length > draft.utf16.count)
        let prefix = (view.string as NSString).substring(to: view.originalStart)
        expect(!view.canEdit(view.selectedRange()))
        expect(!view.shouldChangeText(in: view.selectedRange(), replacementString: "Overwrite all"))
        expect(!view.shouldChangeText(in: NSRange(location: view.originalStart - 1, length: 1), replacementString: ""))
        view.setSelectedRange(NSRange(location: view.originalStart, length: draft.utf16.count))
        view.undoManager?.beginUndoGrouping()
        view.insertText("Modified original.", replacementRange: view.selectedRange())
        view.undoManager?.endUndoGrouping()
        expectEqual(draft, "Modified original.")
        expectEqual((view.string as NSString).substring(to: view.originalStart), prefix)
        view.retranslate(nil)
        expectEqual(submitted, draft)
        view.selectAll(nil)
        let selection = view.selectedRange()
        view.render(translation: "译文保持常规字重。", original: draft, scale: 2)
        expectEqual(view.selectedRange(), selection)
        let storage = try require(view.textStorage)
        for index in [4, view.originalStart] {
            let font = try require(storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont)
            expect(!NSFontManager.shared.traits(of: font).contains(.boldFontMask))
            expectEqual(font.familyName, "Songti SC")
        }
        let title = try require(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        expect(NSFontManager.shared.traits(of: title).contains(.boldFontMask))
        expectEqual(title.pointSize, 32)
        view.undoManager?.undo()
        expectEqual(view.originalText, "Editable original.")
        expectEqual(draft, "Editable original.")
        view.setSelectedRange(NSRange(location: view.originalStart, length: draft.utf16.count))
        view.insertText("", replacementRange: view.selectedRange())
        expectEqual(view.originalText, "")
        submitted = "unchanged"
        view.retranslate(nil)
        expectEqual(submitted, "unchanged")
    }

}
