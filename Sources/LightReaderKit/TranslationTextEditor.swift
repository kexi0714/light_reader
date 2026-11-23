import AppKit
import SwiftUI

/// One text view makes selection continuous across both headings and text bodies.
struct TranslationTextEditor: NSViewRepresentable {
    @Binding var original: String
    let translation: String
    let scale: CGFloat
    var onRetranslate: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> TranslationTextView {
        let view = TranslationTextView(frame: .zero)
        view.isRichText = true
        view.importsGraphics = false
        view.drawsBackground = false
        view.isEditable = true
        view.isSelectable = true
        view.insertionPointColor = .labelColor
        view.textContainerInset = NSSize(width: 18, height: 8)
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        view.allowsUndo = true
        view.delegate = context.coordinator
        view.setAccessibilityLabel("翻译与原文，连续选择；原文可编辑并右键重新翻译")
        return view
    }

    func updateNSView(_ view: TranslationTextView, context: Context) {
        context.coordinator.parent = self
        view.onRetranslate = onRetranslate
        view.render(translation: translation, original: original, scale: scale)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TranslationTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0,
              let container = nsView.textContainer, let layout = nsView.layoutManager else { return nil }
        container.containerSize = NSSize(width: max(1, width - nsView.textContainerInset.width * 2), height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let height = ceil(layout.usedRect(for: container).height) + 40
        let available = proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? 0
        return CGSize(width: width, height: max(100, height, available))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TranslationTextEditor
        init(_ parent: TranslationTextEditor) { self.parent = parent }
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard let view = textView as? TranslationTextView else { return false }
            guard view.canEdit(affectedCharRange) else { return false }
            view.typingAttributes = view.originalAttributes
            return true
        }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? TranslationTextView else { return }
            parent.original = view.originalText
            view.invalidateIntrinsicContentSize()
        }
    }
}

final class TranslationTextView: OriginalTextView {
    private(set) var originalStart = 0
    private(set) var originalHeadingStart = 0
    private var renderedScale: CGFloat = 0
    private var renderedPrefix = ""
    private(set) var originalAttributes: [NSAttributedString.Key: Any] = [:]

    var originalText: String {
        (string as NSString).substring(from: min(originalStart, (string as NSString).length))
    }

    func canEdit(_ range: NSRange) -> Bool {
        let length = (string as NSString).length
        return range.location >= originalStart && range.location <= length && range.length <= length - range.location
    }

    func render(translation: String, original: String, scale: CGFloat) {
        let translationHeading = "翻译：\n"
        let translated = translationHeading + translation + "\n"
        let heading = "原文：  "
        let hint = "可修改后右键重新翻译\n"
        let prefix = translated + heading + hint
        let content = prefix + original
        let changedText = string != content
        guard changedText || renderedScale != scale || renderedPrefix != prefix else { return }
        let oldSelection = selectedRange()
        let selectedOriginal = oldSelection.location >= originalStart && originalStart > 0
        let originalOffset = selectedOriginal ? oldSelection.location - originalStart : 0
        originalHeadingStart = (translated as NSString).length
        originalStart = (prefix as NSString).length

        func attributes(size: CGFloat, bold: Bool = false, spacing: CGFloat = 0) -> [NSAttributedString.Key: Any] {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = spacing
            paragraph.paragraphSpacing = 10
            let font = NSFont(name: bold ? "Songti SC Bold" : "Songti SC Regular", size: size)
                ?? NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
            return [.font: font,
                    .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        }
        originalAttributes = attributes(size: 13 * scale, spacing: 6 * scale)
        let result = NSMutableAttributedString(string: content, attributes: originalAttributes)
        result.addAttributes(attributes(size: 14 * scale, spacing: 8 * scale),
                             range: NSRange(location: 0, length: originalHeadingStart))
        let titleAttributes = attributes(size: 16 * scale, bold: true, spacing: 4)
        result.addAttributes(titleAttributes, range: NSRange(location: 0, length: (translationHeading as NSString).length))
        var originalTitleAttributes = titleAttributes
        let originalParagraph = NSMutableParagraphStyle()
        originalParagraph.lineSpacing = 4
        originalParagraph.paragraphSpacing = 10
        originalParagraph.paragraphSpacingBefore = 18
        originalTitleAttributes[.paragraphStyle] = originalParagraph
        result.addAttributes(originalTitleAttributes, range: NSRange(location: originalHeadingStart, length: (heading as NSString).length))
        var hintAttributes = attributes(size: 10, spacing: 4)
        hintAttributes[.foregroundColor] = NSColor.secondaryLabelColor
        hintAttributes[.paragraphStyle] = originalParagraph
        result.addAttributes(hintAttributes, range: NSRange(location: originalHeadingStart + (heading as NSString).length, length: (hint as NSString).length))
        if changedText {
            textStorage?.setAttributedString(result)
            undoManager?.removeAllActions()
        } else {
            // Attribute-only updates retain text editing undo and the continuous selection.
            result.enumerateAttributes(in: NSRange(location: 0, length: result.length)) { attrs, range, _ in
                self.textStorage?.setAttributes(attrs, range: range)
            }
        }
        let location = selectedOriginal && changedText
            ? originalStart + min(originalOffset, (original as NSString).length)
            : min(oldSelection.location, result.length)
        setSelectedRange(NSRange(location: location, length: min(oldSelection.length, result.length - location)))
        typingAttributes = originalAttributes
        renderedPrefix = prefix
        renderedScale = scale
        invalidateIntrinsicContentSize()
    }

    override func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        insertText(text, replacementRange: selectedRange())
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.allowsContextMenuPlugIns = false
        let position = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        if position >= originalHeadingStart {
            let item = NSMenuItem(title: "重新翻译", action: #selector(retranslate(_:)), keyEquivalent: "")
            item.target = self
            item.isEnabled = !originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            menu.addItem(item)
            let copy = NSMenuItem(title: "复制", action: #selector(copy(_:)), keyEquivalent: "")
            copy.target = self
            copy.isEnabled = selectedRange().length > 0
            menu.addItem(copy)
        } else {
            let copy = NSMenuItem(title: "复制", action: #selector(copy(_:)), keyEquivalent: "")
            copy.target = self
            copy.isEnabled = selectedRange().length > 0
            menu.addItem(copy)
            let all = NSMenuItem(title: "全选", action: #selector(selectAll(_:)), keyEquivalent: "")
            all.target = self
            menu.addItem(all)
        }
        return menu
    }

    override func retranslate(_ sender: Any?) {
        guard !originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onRetranslate?(originalText)
    }
}
