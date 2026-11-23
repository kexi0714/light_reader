import AppKit

/// Editing controls use screen-sized hit targets around the text bounds.
final class NoteEditorBox: NSView {
    struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1)
        static let right = Edges(rawValue: 2)
        static let bottom = Edges(rawValue: 4)
        static let top = Edges(rawValue: 8)
    }
    enum Interaction { case move, resize(Edges) }
    var onBegin: ((Interaction, NSEvent) -> Void)?
    var onDrag: ((NSEvent) -> Void)?
    var onEnd: (() -> Void)?
    private(set) var textRect: NSRect = .zero
    private var dragCursor: NSCursor?
    private var hoverArea: NSTrackingArea?
    private let grip: CGFloat = 18
    private let innerHitSlop: CGFloat = 4
    private let headerHeight: CGFloat = 12
    private var scaleX: CGFloat { frame.width / max(1, bounds.width) }
    private var scaleY: CGFloat { frame.height / max(1, bounds.height) }
    private var screenHeader: NSRect {
        let width = min(40, (frame.width - 2 * grip) * 0.6)
        return NSRect(x: (frame.width - width) / 2, y: frame.height - grip,
                      width: width, height: headerHeight)
    }
    var moveRect: NSRect { localRect(screenHeader) }

    func setTextGeometry(frame textFrame: NSRect, size textSize: NSSize) {
        let sx = textFrame.width / max(1, textSize.width)
        let sy = textFrame.height / max(1, textSize.height)
        frame = NSRect(x: textFrame.minX - grip, y: textFrame.minY - grip,
                       width: textFrame.width + 2 * grip,
                       height: textFrame.height + 2 * grip)
        bounds = NSRect(x: -grip / sx, y: -grip / sy,
                        width: textSize.width + 2 * grip / sx,
                        height: textSize.height + 2 * grip / sy)
        textRect = NSRect(origin: .zero, size: textSize)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    private func localRect(_ rect: NSRect) -> NSRect {
        NSRect(x: bounds.minX + rect.minX / scaleX, y: bounds.minY + rect.minY / scaleY,
               width: rect.width / scaleX, height: rect.height / scaleY)
    }

    private var resizeTargets: [(Edges, NSRect)] {
        let w = frame.width, h = frame.height
        // Preserve a clickable text interior even on short, zoomed-out notes.
        let textWidth = max(0, w - 2 * grip)
        let edgeX = min(grip + min(innerHitSlop, textWidth / 6), max(grip, w / 2 - 1))
        let header = screenHeader
        return [
            // Keep corner ownership unchanged while widening the straight edges.
            ([.left, .bottom], NSRect(x: 0, y: 0, width: grip, height: grip)),
            ([.right, .bottom], NSRect(x: w - grip, y: 0, width: grip, height: grip)),
            ([.left, .top], NSRect(x: 0, y: h - grip, width: grip, height: grip)),
            ([.right, .top], NSRect(x: w - grip, y: h - grip, width: grip, height: grip)),
            (.left, NSRect(x: 0, y: grip, width: edgeX, height: h - 2 * grip)),
            (.right, NSRect(x: w - edgeX, y: grip, width: edgeX, height: h - 2 * grip)),
            (.bottom, NSRect(x: grip, y: 0, width: w - 2 * grip, height: grip)),
            // Tile the top band around the move handle so cursor and drag agree.
            (.top, NSRect(x: grip, y: h - grip, width: header.minX - grip, height: grip)),
            (.top, NSRect(x: header.minX, y: header.maxY, width: header.width,
                          height: max(0, h - header.maxY))),
            (.top, NSRect(x: header.maxX, y: h - grip, width: w - grip - header.maxX, height: grip))
        ]
    }

    func interaction(at point: NSPoint) -> Interaction? {
        guard bounds.contains(point) else { return nil }
        for (edges, rect) in resizeTargets where localRect(rect).contains(point) { return .resize(edges) }
        return moveRect.contains(point) ? .move : nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if interaction(at: local) != nil { return self }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard let interaction = interaction(at: convert(event.locationInWindow, from: nil)) else { return }
        let cursor: NSCursor
        switch interaction {
        case .move: cursor = .closedHand
        case .resize(let edges): cursor = resizeCursor(for: edges)
        }
        dragCursor = cursor
        cursor.set()
        onBegin?(interaction, event)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let dragCursor else { return }
        onDrag?(event)
        dragCursor.set()
    }
    override func mouseUp(with event: NSEvent) {
        guard dragCursor != nil else { return }
        dragCursor = nil
        onEnd?()
        window?.invalidateCursorRects(for: self)
        hoverCursor(for: event)?.set()
    }

    private func resizeCursor(for edges: Edges) -> NSCursor {
        if #available(macOS 15, *) {
            let position: NSCursor.FrameResizePosition
            switch edges {
            case [.top, .left]: position = .topLeft
            case [.top, .right]: position = .topRight
            case [.bottom, .left]: position = .bottomLeft
            case [.bottom, .right]: position = .bottomRight
            case .left: position = .left
            case .right: position = .right
            case .top: position = .top
            default: position = .bottom
            }
            return .frameResize(position: position, directions: .all)
        }
        if edges == .left || edges == .right { return .resizeLeftRight }
        if edges == .top || edges == .bottom { return .resizeUpDown }
        return .crosshair
    }

    private func hoverCursor(for event: NSEvent) -> NSCursor? {
        if let dragCursor { return dragCursor }
        switch interaction(at: convert(event.locationInWindow, from: nil)) {
        case .move: return .openHand
        case .resize(let edges): return resizeCursor(for: edges)
        case nil: return nil
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .mouseMoved, .cursorUpdate],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        if let cursor = hoverCursor(for: event) { cursor.set() }
        else { super.cursorUpdate(with: event) }
    }

    override func mouseMoved(with event: NSEvent) {
        if let cursor = hoverCursor(for: event) { cursor.set() }
        else { super.mouseMoved(with: event) }
    }

    override func resetCursorRects() {
        addCursorRect(moveRect, cursor: .openHand)
        for (edges, rect) in resizeTargets {
            addCursorRect(localRect(rect), cursor: resizeCursor(for: edges))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: bounds.minX, yBy: bounds.minY)
        transform.scaleX(by: 1 / scaleX, yBy: 1 / scaleY)
        transform.concat()

        let outline = NSRect(x: grip - 1, y: grip - 1, width: frame.width - 2 * grip + 2,
                             height: frame.height - 2 * grip + 2)
        let accent = NSColor.controlAccentColor
        accent.withAlphaComponent(0.42).setStroke()
        let border = NSBezierPath(roundedRect: outline, xRadius: 2, yRadius: 2)
        border.lineWidth = 0.75
        border.stroke()

        let handleWidth = min(18, screenHeader.width)
        accent.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: NSRect(x: screenHeader.midX - handleWidth / 2,
                                          y: screenHeader.midY - 1.5,
                                          width: handleWidth, height: 3),
                     xRadius: 1.5, yRadius: 1.5).fill()

        for (x, y) in [(outline.minX, outline.minY), (outline.maxX, outline.minY),
                       (outline.minX, outline.maxY), (outline.maxX, outline.maxY)] {
            NSBezierPath(ovalIn: NSRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3)).fill()
        }
    }
}
