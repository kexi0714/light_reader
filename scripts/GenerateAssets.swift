import AppKit
import PDFKit
import CoreText

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources")
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func icon(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    NSColor(srgbRed: 0.18, green: 0.36, blue: 0.30, alpha: 1).setFill()
    NSBezierPath(roundedRect: CGRect(x: 40, y: 40, width: 944, height: 944), xRadius: 210, yRadius: 210).fill()
    NSColor(srgbRed: 0.96, green: 0.95, blue: 0.90, alpha: 1).setFill()
    NSBezierPath(roundedRect: CGRect(x: 230, y: 220, width: 564, height: 610), xRadius: 42, yRadius: 42).fill()
    NSColor(srgbRed: 0.77, green: 0.84, blue: 0.74, alpha: 1).setFill()
    NSBezierPath(roundedRect: CGRect(x: 230, y: 200, width: 564, height: 54), xRadius: 18, yRadius: 18).fill()
    NSColor(srgbRed: 0.33, green: 0.47, blue: 0.39, alpha: 1).setFill()
    for y in [650, 550, 450] { NSBezierPath(roundedRect: CGRect(x: 325, y: y, width: 370, height: 25), xRadius: 12, yRadius: 12).fill() }
    NSColor(srgbRed: 0.93, green: 0.68, blue: 0.38, alpha: 1).setFill()
    NSBezierPath(roundedRect: CGRect(x: 310, y: 432, width: 250, height: 57), xRadius: 8, yRadius: 8).fill()
    NSColor(srgbRed: 0.33, green: 0.47, blue: 0.39, alpha: 1).setFill()
    NSBezierPath(roundedRect: CGRect(x: 325, y: 450, width: 220, height: 21), xRadius: 10, yRadius: 10).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for size in [16, 32, 128, 256, 512] {
    try icon(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try icon(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}

var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
let pdfURL = root.appendingPathComponent("docs/Sample Paper.pdf")
let context = CGContext(pdfURL as CFURL, mediaBox: &mediaBox, nil)!
func text(_ string: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, size: CGFloat, bold: Bool = false, color: NSColor = .black) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 6
    let attrs: [NSAttributedString.Key: Any] = [.font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size), .foregroundColor: color, .paragraphStyle: paragraph]
    let setter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: string, attributes: attrs))
    let path = CGPath(rect: CGRect(x: x, y: y, width: width, height: height), transform: nil)
    CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil), context)
}
for page in 1...2 {
    context.beginPDFPage(nil)
    context.setFillColor(NSColor.white.cgColor)
    context.fill(mediaBox)
    text("LIGHT READER  /  SAMPLE DOCUMENT", x: 50, y: 735, width: 500, height: 20, size: 9, color: .gray)
    if page == 1 {
        text("A quieter space for\nscientific reading", x: 50, y: 615, width: 500, height: 100, size: 29, bold: true)
        text("A sample paper for testing translation and PDF annotations", x: 50, y: 580, width: 500, height: 32, size: 11, color: .gray)
        text("Abstract", x: 50, y: 535, width: 500, height: 27, size: 14, bold: true)
        text("Scientific reading involves understanding complex ideas and connecting them to prior knowledge. A focused reading environment can support this process by keeping translation and annotation close to the original text. This document provides selectable English text for testing a lightweight PDF reader.", x: 50, y: 415, width: 500, height: 115, size: 12)
        text("1. Reading with context", x: 50, y: 370, width: 245, height: 28, size: 13, bold: true)
        text("Researchers often move between unfamiliar terminology and the central argument of a paper. Translating a selected sentence can help clarify its meaning without replacing the source material.\n\nHighlighting draws attention to an important claim. Short notes preserve questions that deserve further investigation [1].", x: 50, y: 125, width: 240, height: 235, size: 11)
        text("2. Notes that stay with you", x: 320, y: 370, width: 245, height: 28, size: 13, bold: true)
        text("A useful note records the reader's own reasoning. It might identify an assumption, propose an alternative explanation, or connect a result to another study.\n\nStandard PDF annotations allow these ideas to remain attached to the document. The original text remains available for careful comparison.", x: 320, y: 125, width: 240, height: 235, size: 11)
    } else {
        text("From reading to understanding", x: 50, y: 645, width: 500, height: 65, size: 25, bold: true)
        text("3. A small workflow", x: 50, y: 585, width: 500, height: 32, size: 15, bold: true)
        text("Select an English sentence to see its translation. Mark a useful passage with a soft green, orange, or blue highlight. Click the typewriter tool and choose an empty area on this page to write a note. Save the PDF and reopen it to check that your annotations remain in place.", x: 50, y: 450, width: 500, height: 125, size: 13)
        text("Space for your notes", x: 50, y: 395, width: 500, height: 30, size: 13, bold: true, color: .gray)
        context.setStrokeColor(NSColor.lightGray.withAlphaComponent(0.3).cgColor)
        context.setLineWidth(0.5)
        for y in stride(from: 150, through: 360, by: 35) { context.move(to: CGPoint(x: 50, y: y)); context.addLine(to: CGPoint(x: 562, y: y)); context.strokePath() }
        text("[1] This is an original demonstration document, not a published research paper.", x: 50, y: 80, width: 500, height: 30, size: 9, color: .gray)
    }
    text("\(page) / 2", x: 280, y: 35, width: 100, height: 18, size: 9, color: .gray)
    context.endPDFPage()
}
context.closePDF()
print("Generated app icon and docs/Sample Paper.pdf")

// ICNS accepts PNG payloads; write the container directly so asset generation
// also works with Command Line Tools installations lacking iconutil support.
func bigEndian(_ number: Int) -> Data {
    var value = UInt32(number).bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}
var chunks = Data()
for (type, size) in [("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128), ("ic08", 256), ("ic09", 512), ("ic10", 1024)] {
    let png = icon(size)
    chunks.append(Data(type.utf8))
    chunks.append(bigEndian(png.count + 8))
    chunks.append(png)
}
var icns = Data("icns".utf8)
icns.append(bigEndian(chunks.count + 8))
icns.append(chunks)
try icns.write(to: resources.appendingPathComponent("AppIcon.icns"))
