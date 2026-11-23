import AppKit
import SwiftUI

/// A borderless editor that grows with the original text inside the sidebar's scroll view.
struct OriginalTextEditor: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = 13
    var lineSpacing: CGFloat = 6
    var editable = true
    var minimumHeight: CGFloat = 100
    var onRetranslate: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> OriginalTextView {
        let view = OriginalTextView(frame: .zero)
        view.isRichText = false
        view.drawsBackground = false
        view.isEditable = editable
        view.isSelectable = true
        view.textColor = .labelColor
        view.insertionPointColor = .labelColor
        view.textContainerInset = NSSize(width: 18, height: 8)
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        view.allowsUndo = true
        view.delegate = context.coordinator
        view.setAccessibilityLabel(editable ? "原文，可修改后右键重新翻译" : "译文")
        return view
    }

    func updateNSView(_ view: OriginalTextView, context: Context) {
        context.coordinator.parent = self
        view.onRetranslate = editable ? onRetranslate : nil
        view.isEditable = editable
        if view.string != text {
            view.string = text
            view.undoManager?.removeAllActions()
        }
        view.applyTypography(fontSize: fontSize, lineSpacing: lineSpacing)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: OriginalTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0,
              let container = nsView.textContainer, let layout = nsView.layoutManager else { return nil }
        container.containerSize = NSSize(width: max(1, width - nsView.textContainerInset.width * 2), height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let naturalHeight = ceil(layout.usedRect(for: container).height) + nsView.textContainerInset.height * 2 + 24
        let proposedHeight = editable ? (proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? 0) : 0
        return CGSize(width: width, height: max(minimumHeight, naturalHeight, proposedHeight))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: OriginalTextEditor
        init(_ parent: OriginalTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? OriginalTextView else { return }
            parent.text = view.string
            view.invalidateIntrinsicContentSize()
        }
    }
}

class OriginalTextView: NSTextView {
    private let editingUndoManager = UndoManager()
    override var undoManager: UndoManager? { editingUndoManager }
    var onRetranslate: ((String) -> Void)?

    // Font scaling must preserve the selection, draft, and text undo stack.
    func applyTypography(fontSize: CGFloat, lineSpacing: CGFloat) {
        let bodyFont = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        guard font != bodyFont || defaultParagraphStyle?.lineSpacing != lineSpacing else { return }
        let selection = selectedRanges
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        let attributes: [NSAttributedString.Key: Any] = [
            .font: bodyFont, .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        textStorage?.addAttributes(attributes, range: NSRange(location: 0, length: (string as NSString).length))
        font = bodyFont
        defaultParagraphStyle = paragraph
        typingAttributes = attributes
        selectedRanges = selection
        invalidateIntrinsicContentSize()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if !isEditable {
            let copy = NSMenuItem(title: "复制", action: #selector(copy(_:)), keyEquivalent: "")
            copy.target = self
            copy.isEnabled = selectedRange().length > 0
            menu.addItem(copy)
            let select = NSMenuItem(title: "全选", action: #selector(selectAll(_:)), keyEquivalent: "")
            select.target = self
            select.isEnabled = !string.isEmpty
            menu.addItem(select)
            return menu
        }
        let item = NSMenuItem(title: "重新翻译", action: #selector(retranslate(_:)), keyEquivalent: "")
        item.target = self
        item.isEnabled = !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        menu.addItem(item)
        let copy = NSMenuItem(title: "复制", action: #selector(copy(_:)), keyEquivalent: "")
        copy.target = self
        copy.isEnabled = selectedRange().length > 0
        menu.addItem(copy)
        return menu
    }

    @objc func retranslate(_ sender: Any?) {
        guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onRetranslate?(string)
    }
}
