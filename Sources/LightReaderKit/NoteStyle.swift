import AppKit

/// Shared by the editor and the saved PDF annotation.
enum NoteStyle {
    static let fontName = "HannotateSC-W5"
    static let color = NSColor(calibratedRed: 1, green: 0, blue: 0, alpha: 1)

    static func font(ofSize size: CGFloat) -> NSFont {
        NSFont(name: fontName, size: size) ?? NSFont.systemFont(ofSize: size)
    }
}
