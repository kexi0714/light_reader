import AppKit
import SwiftUI

/// A real AppKit divider owns mouse tracking, including above the PDF and sidebar.
struct ReaderSplitView<Left: View, Right: View>: NSViewRepresentable {
    @Binding var fraction: CGFloat
    var sidebarVisible: Bool
    let left: Left
    let right: Right

    func makeNSView(context: Context) -> ReaderSplitContainer<Left, Right> {
        let view = ReaderSplitContainer(left: left, right: right)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: ReaderSplitContainer<Left, Right>, context: Context) {
        view.leftHost.rootView = left
        view.rightHost.rootView = right
        view.onFractionChange = { fraction = $0 }
        view.configure(fraction: fraction, visible: sidebarVisible)
    }
}

final class ReaderSplitContainer<Left: View, Right: View>: NSSplitView, NSSplitViewDelegate {
    let leftHost: NSHostingView<Left>
    let rightHost: NSHostingView<Right>
    var onFractionChange: ((CGFloat) -> Void)?
    private(set) var sidebarFraction: CGFloat = 0.25
    private var applyingLayout = false
    private var showsSidebar = true
    override var dividerThickness: CGFloat { showsSidebar ? min(8, bounds.width) : 0 }

    init(left: Left, right: Right) {
        leftHost = NSHostingView(rootView: left)
        rightHost = NSHostingView(rootView: right)
        super.init(frame: .zero)
        isVertical = true
        dividerStyle = .thin
        delegate = self
        leftHost.sizingOptions = []
        rightHost.sizingOptions = []
        addSubview(leftHost)
        addSubview(rightHost)
        setAccessibilityLabel("文献与翻译分栏")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func sidebarWidth(totalWidth: CGFloat, fraction: CGFloat) -> CGFloat {
        let available = max(0, totalWidth - 8)
        let minimum = min(210, available)
        let maximum = max(minimum, available - 470)
        return min(max(available * fraction, minimum), maximum)
    }

    func configure(fraction: CGFloat, visible: Bool) {
        guard abs(sidebarFraction - fraction) > 0.0001 || showsSidebar != visible else { return }
        sidebarFraction = fraction
        showsSidebar = visible
        resizeSubviews(withOldSize: bounds.size)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        applyingLayout = true
        defer { applyingLayout = false }
        rightHost.isHidden = !showsSidebar
        let rightWidth = showsSidebar ? Self.sidebarWidth(totalWidth: bounds.width, fraction: sidebarFraction) : 0
        let leftWidth = max(0, bounds.width - dividerThickness - rightWidth)
        leftHost.frame = NSRect(x: 0, y: 0, width: leftWidth, height: bounds.height)
        rightHost.frame = NSRect(x: leftWidth + dividerThickness, y: 0, width: rightWidth, height: bounds.height)
        needsDisplay = true
    }

    override func drawDivider(in rect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        rect.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: rect.midX - 0.5, y: rect.minY, width: 1, height: rect.height).fill()
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(470, max(0, bounds.width - dividerThickness - 210))
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(0, bounds.width - dividerThickness - 210)
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !applyingLayout, showsSidebar, bounds.width > dividerThickness else { return }
        sidebarFraction = rightHost.frame.width / (bounds.width - dividerThickness)
        onFractionChange?(sidebarFraction)
    }
}
