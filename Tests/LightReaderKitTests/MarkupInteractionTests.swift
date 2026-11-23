import AppKit
import PDFKit
import SwiftUI

@testable import LightReaderKit

private final class ScrollTestWindow: NSWindow {
  var wheelEvent: NSEvent?
  override var currentEvent: NSEvent? { wheelEvent ?? super.currentEvent }
}

struct MarkupInteractionTests {
  @MainActor func testWheelOverMarkupAndEditor() throws {
    let owner = ReaderDocument()
    let pdf = PDFDocument()
    let page = PDFPage()
    page.setBounds(NSRect(x: 0, y: 0, width: 600, height: 1400), for: .mediaBox)
    pdf.insert(page, at: 0)
    let markup = PDFAnnotation(
      bounds: NSRect(x: 40, y: 730, width: 120, height: 20), forType: .highlight,
      withProperties: nil)
    page.addAnnotation(markup)
    let window = ScrollTestWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let canvas = PDFCanvas(frame: window.contentView!.bounds)
    window.contentView = canvas
    canvas.reader = owner.reader
    owner.reader.canvas = canvas
    owner.reader.pdf = pdf
    canvas.document = pdf
    canvas.displayMode = .singlePageContinuous
    canvas.scaleFactor = 1
    canvas.layoutSubtreeIfNeeded()
    canvas.go(to: PDFDestination(page: page, at: NSPoint(x: 0, y: 900)))
    let scroll = try require(canvas.documentView?.enclosingScrollView)
    let event = try require(
      CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -40, wheel2: 0,
        wheel3: 0
      ).flatMap { NSEvent(cgEvent: $0) })
    func wheel(at point: NSPoint) throws {
      window.wheelEvent = event
      defer { window.wheelEvent = nil }
      let target = try require(canvas.hitTest(canvas.convert(point, to: canvas.superview)))
      expect(target === scroll)
      target.scrollWheel(with: event)
    }
    try wheel(at: canvas.convert(NSPoint(x: markup.bounds.midX, y: markup.bounds.midY), from: page))
    canvas.beginEditing(page: page, point: NSPoint(x: 180, y: 700), annotation: nil)
    let box = try require(canvas.documentView?.subviews.compactMap { $0 as? NoteEditorBox }.first)
    let text = try require(
      box.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? NoteTextView }.first)
    text.string = "滚动中的笔记"
    func pageRect() -> NSRect { canvas.convert(box.convert(box.textRect, to: canvas), to: page) }
    let anchor = pageRect()
    try wheel(at: box.convert(NSPoint(x: box.textRect.midX, y: box.textRect.midY), to: canvas))
    // Drive a clip-view scroll explicitly: synthetic wheel events have no
    // hardware gesture stream in a headless window.
    let clip = scroll.contentView
    let start = clip.bounds.origin
    let middle = clip.documentRect.midY - clip.bounds.height / 2
    clip.scroll(to: NSPoint(x: start.x, y: start.y < middle ? start.y + 80 : start.y - 80))
    scroll.reflectScrolledClipView(clip)
    expect(abs(clip.bounds.minY - start.y) > 1)
    expect(abs(pageRect().minY - anchor.minY) < 0.01)
    expect(owner.reader.isEditingNote && box.superview === canvas.documentView)
    expectEqual(text.string, "滚动中的笔记")
    canvas.finishEditing(commit: false)
  }

  @MainActor func testWindowRouting() throws {
    let owner = ReaderDocument()
    let page = PDFPage()
    page.setBounds(NSRect(x: 0, y: 0, width: 600, height: 800), for: .mediaBox)
    let pdf = PDFDocument()
    pdf.insert(page, at: 0)
    owner.reader.pdf = pdf
    let markup = PDFAnnotation(
      bounds: NSRect(x: 80, y: 450, width: 190, height: 18), forType: .highlight,
      withProperties: nil)
    markup.color = HighlightColor.green.color
    page.addAnnotation(markup)
    let groupKey = PDFAnnotationKey(rawValue: "LiReMarkupGroup")
    markup.setValue("selection-feedback", forAnnotationKey: groupKey)
    let secondLine = PDFAnnotation(
      bounds: NSRect(x: 80, y: 420, width: 140, height: 18), forType: .highlight,
      withProperties: nil)
    secondLine.setValue("selection-feedback", forAnnotationKey: groupKey)
    page.addAnnotation(secondLine)
    let link = PDFAnnotation(
      bounds: NSRect(x: 80, y: 650, width: 100, height: 20), forType: .link, withProperties: nil)
    link.action = PDFActionURL(url: URL(string: "https://github.com/example/paper")!)
    page.addAnnotation(link)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let canvas = PDFCanvas(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
    window.contentView = canvas
    canvas.reader = owner.reader
    owner.reader.canvas = canvas
    canvas.document = pdf
    canvas.displayMode = .singlePageContinuous
    canvas.scaleFactor = 2.2
    canvas.startObserving()
    defer { canvas.stopObserving() }
    window.makeKeyAndOrderFront(nil)
    canvas.layoutSubtreeIfNeeded()
    canvas.go(to: PDFDestination(page: page, at: NSPoint(x: 0, y: 600)))
    canvas.layoutSubtreeIfNeeded()
    let point = canvas.convert(NSPoint(x: markup.bounds.midX, y: markup.bounds.midY), from: page)
    let hit = canvas.hitTest(point)
    expect(hit === canvas)
    for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      let event = try require(
        NSEvent.mouseEvent(
          with: kind,
          location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
          pressure: 1))
      window.sendEvent(event)
    }
    expect(owner.reader.selectedAnnotation === markup)
    let overlay = try require(
      canvas.documentView?.subviews.compactMap { $0 as? MarkupSelectionOverlay }.first)
    expect(!overlay.isHidden)
    expectEqual(overlay.selectionRects.count, 2)
    let expected = overlay.convert(canvas.convert(markup.bounds, from: page), from: canvas)
    expectEqual(overlay.selectionRects.first, expected)
    expect(overlay.hitTest(expected.origin) == nil)
    // Render the actual feedback view to ensure selection produces visible pixels.
    let bitmap = try require(overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds))
    overlay.cacheDisplay(in: overlay.bounds, to: bitmap)
    let selectedPoint = NSPoint(x: expected.midX, y: expected.midY)
    let x = Int(
      (selectedPoint.x - overlay.bounds.minX) * CGFloat(bitmap.pixelsWide) / overlay.bounds.width)
    let y = Int(
      (overlay.bounds.maxY - selectedPoint.y) * CGFloat(bitmap.pixelsHigh) / overlay.bounds.height)
    let selectionColor = try require(bitmap.colorAt(x: x, y: y))
    expect(selectionColor.alphaComponent > 0 && selectionColor.alphaComponent < 0.15)
    owner.reader.selectHighlight(.orange)
    expectEqual(overlay.selectionRects.count, 2)
    let saved = try require(PDFDocument(data: owner.data(ofType: "PDF Document")))
    expectEqual(saved.page(at: 0)?.annotations.count, 3)
    owner.reader.setTool(.select)
    expect(overlay.isHidden)
    expect(overlay.selectionRects.isEmpty)
    owner.reader.selectedAnnotation = page.annotations.first { $0.type == "Highlight" }
    expectEqual(overlay.selectionRects.count, 2)
    expectEqual(owner.reader.currentHighlightColor, .orange)
    expect(
      page.annotations.contains {
        $0.type == "Highlight" && HighlightColor.orange.matches($0.color)
      })
    let url = try require((link.action as? PDFActionURL)?.url)
    expect(!canvas.canOpenLink(url, at: point))
    canvas.go(to: PDFDestination(page: page, at: NSPoint(x: 0, y: 780)))
    canvas.layoutSubtreeIfNeeded()
    let selected = try require(owner.reader.selectedAnnotation)
    let movedRect = overlay.convert(canvas.convert(selected.bounds, from: page), from: canvas)
    expect(
      overlay.selectionRects.contains {
        abs($0.minX - movedRect.minX) < 0.01 && abs($0.minY - movedRect.minY) < 0.01
          && abs($0.width - movedRect.width) < 0.01 && abs($0.height - movedRect.height) < 0.01
      })
    canvas.scaleFactor = 1.5
    canvas.layoutSubtreeIfNeeded()
    let zoomedRect = overlay.convert(canvas.convert(selected.bounds, from: page), from: canvas)
    expect(
      overlay.selectionRects.contains {
        abs($0.minX - zoomedRect.minX) < 0.01 && abs($0.minY - zoomedRect.minY) < 0.01
          && abs($0.width - zoomedRect.width) < 0.01 && abs($0.height - zoomedRect.height) < 0.01
      })
    let linkPoint = canvas.convert(NSPoint(x: link.bounds.midX, y: link.bounds.midY), from: page)
    expect(canvas.canOpenLink(url, at: linkPoint))
    expect(!canvas.canOpenLink(URL(string: "https://example.com/other")!, at: linkPoint))
    let overlapping = PDFAnnotation(bounds: link.bounds, forType: .highlight, withProperties: nil)
    page.addAnnotation(overlapping)
    expect(canvas.hitTest(linkPoint) === canvas)
    expect(!canvas.canOpenLink(url, at: linkPoint))
  }
  @MainActor func testPaletteInReader() throws {
    let pdf = PDFDocument()
    let original = PDFPage()
    original.setBounds(NSRect(x: 0, y: 0, width: 600, height: 800), for: .mediaBox)
    pdf.insert(original, at: 0)
    let bounds = NSRect(x: 200, y: 530, width: 120, height: 16)
    let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
    annotation.color = HighlightColor.green.color
    original.addAnnotation(annotation)
    let owner = ReaderDocument()
    try owner.read(from: require(pdf.dataRepresentation()), ofType: "PDF Document")
    let page = try require(owner.reader.pdf?.page(at: 0))
    let markup = try require(page.annotations.first)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView = NSHostingView(rootView: ReaderView(state: owner.reader, tabs: ReaderTabGroup()))
    window.makeKeyAndOrderFront(nil)
    window.contentView?.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    let canvas = try require(owner.reader.canvas)
    canvas.go(to: PDFDestination(page: page, at: NSPoint(x: 0, y: 650)))
    canvas.layoutSubtreeIfNeeded()

    func click(_ point: NSPoint) throws {
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let event = try require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
          context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
        window.sendEvent(event)
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    let point = canvas.convert(NSPoint(x: bounds.midX, y: bounds.midY), from: page)
    try click(canvas.convert(point, to: nil))
    expect(owner.reader.selectedAnnotation === markup)
    // Frames of the three 17-point palette circles with five points of padding.
    let swatches = try require(window.contentView).descendants().filter {
      $0.frame.size == NSSize(width: 27, height: 27)
    }.sorted { $0.convert(.zero, to: nil).x < $1.convert(.zero, to: nil).x }
    guard swatches.count == HighlightColor.allCases.count else { fail("Expected three palette buttons"); return }
    for (color, button) in zip(HighlightColor.allCases, swatches).reversed() where color != .green {
      try click(button.convert(NSPoint(x: 2, y: button.bounds.midY), to: nil))
      let selected = try require(owner.reader.selectedAnnotation)
      expect(selected === page.annotations.first && color.matches(selected.color))
    }
    let saved = try require(PDFDocument(data: owner.data(ofType: "PDF Document")))
    let savedAnnotation = try require(saved.page(at: 0)?.annotations.first)
    expect(HighlightColor.orange.matches(savedAnnotation.color))
  }
}

private extension NSView {
  func descendants() -> [NSView] {
    subviews + subviews.flatMap { $0.descendants() }
  }
}
