import AppKit

enum WindowPlacement {
    static func centeredFrame(size: NSSize, visibleFrame: NSRect) -> NSRect {
        let width = min(size.width, visibleFrame.width)
        let height = min(size.height, visibleFrame.height)
        return NSRect(x: visibleFrame.midX - width / 2, y: visibleFrame.midY - height / 2,
                      width: width, height: height)
    }

    static func center(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        guard let screen = NSScreen.main ?? window.screen else { return }
        window.setFrame(centeredFrame(size: window.frame.size, visibleFrame: screen.visibleFrame),
                        display: false, animate: false)
    }
}
