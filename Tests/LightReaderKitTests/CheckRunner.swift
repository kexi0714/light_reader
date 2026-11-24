import AppKit
import Foundation

private var failures = 0
private enum CheckError: Error { case missingValue(String) }
func fail(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
    failures += 1
    print("  FAIL \(file):\(line): \(message)")
}
func expect(_ condition: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    if !condition() { fail("Condition is false", file: file, line: line) }
}
func expectEqual<T: Equatable>(_ actual: @autoclosure () throws -> T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) rethrows {
    let value = try actual()
    if value != expected { fail("Expected \(expected), got \(value)", file: file, line: line) }
}
func expectAtLeast<T: Comparable>(_ actual: T, _ minimum: T, file: StaticString = #filePath, line: UInt = #line) {
    if actual < minimum { fail("\(actual) is below \(minimum)", file: file, line: line) }
}
func expectNotNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
    if value == nil { fail("Expected a value", file: file, line: line) }
}
func require<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value else { throw CheckError.missingValue("\(file):\(line)") }
    return value
}
func expectThrows<T>(_ expression: @autoclosure () throws -> T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line, check: (Error) -> Void = { _ in }) {
    do { _ = try expression(); fail("Expected an error: \(message)", file: file, line: line) }
    catch { check(error) }
}

private final class CheckApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct CheckRunner {
    @MainActor static func main() async {
        _ = NSApplication.shared
        let applicationDelegate = CheckApplicationDelegate()
        NSApp.delegate = applicationDelegate
        defer { withExtendedLifetime(applicationDelegate) {} }
        let translations = TranslationTests()
        let pdf = PDFTests()
        let settings = SettingsTests()
        let tabs = TabTests()
        let originalText = OriginalTextTests()
        let checks: [(String, () async throws -> Void)] = [
            ("Find from PDF focus, type, highlight and advance across pages", pdf.testDocumentFind),
            ("Window toolbar recolors a selected highlight", MarkupInteractionTests().testPaletteInReader),
            ("Wheel over markup and active note scrolls the PDF and preserves the page anchor", MarkupInteractionTests().testWheelOverMarkupAndEditor),
            ("Markup mouse routing in a zoomed, scrolled PDF window", MarkupInteractionTests().testWindowRouting),
            ("Continuous sidebar selection preserves protected translation, original editing, styles and undo", originalText.testContinuousSidebarEditing),
            ("Sidebar text supports blank-area selection, Select All and font scaling", originalText.testSidebarTextSelectionAndScaling),
            ("Original context menu retranslates the full edited text and rejects blank text", originalText.testRetranslateMenuUsesEntireEditedText),
            ("Original text editing has independent undo and redo", originalText.testOriginalEditorUndoIsIndependent),
            ("Welcome window centers after layout, including multiple-screen coordinates", tabs.testInitialWindowPlacement),
            ("Reading-pane tabs append, switch, detach, merge and close independently", tabs.testDocumentTabs),
            ("Document tabs reorder without switching documents and retain order through navigation and closing", tabs.testTabReordering),
            ("Tab mouse gestures reorder in both directions while clicks still select", tabs.testTabDragGesture),
            ("Native divider drags, resizes and restores the translation pane", tabs.testResizableReaderPanes),
            ("PDF file drops filter URLs and preserve order", tabs.testPDFDropFiltering),
            ("Local credential persistence and permissions", settings.testPersistenceAndPermissions),
            ("Installed app storage is independent of the project and launch directory", settings.testStorageLocations),
            ("Legacy settings migration, backups and future/corrupt schema protection", settings.testSettingsMigrationAndFutureVersionProtection),
            ("Text cleanup and paragraph preservation", translations.testLineCleanupPreservesParagraphsAndCitation),
            ("Endpoint normalization", translations.testEndpointNormalization),
            ("Reject unsafe or ambiguous endpoint URLs", translations.testRejectsInsecureRemoteAndAmbiguousURLs),
            ("Model request schema and selected text", translations.testModelRequestContainsOnlySelectionAndExpectedSchema),
            ("Model response parsing", translations.testModelResponses),
            ("Baidu MD5 signing example", translations.testBaiduOfficialSigningExample),
            ("Baidu form encoding", translations.testBaiduFormEscapesSpecialCharacters),
            ("Baidu results and service errors", translations.testBaiduResponseAndServiceErrors),
            ("Baidu byte limit and missing credentials", translations.testBaiduByteLimitAndMissingConfiguration),
            ("PDF selection follows the stationary pointer while scrolling across pages", pdf.testSelectionAcrossScroll),
            ("Command drag appends disjoint PDF ranges, removes overlaps and preserves gaps", pdf.testDiscontinuousSelection),
            ("Chinese notes and highlights survive PDF save", pdf.testAnnotationsRoundTripAsStandardPDF),
            ("Annotation undo, redo and document isolation", pdf.testAnnotationUndoRedoAndDocumentIsolation),
            ("Multiline highlight and rotated PDF round-trip", pdf.testMultilineHighlightAndRotatedPageSurviveSave),
            ("Highlights fit glyphs and leave rendered line gaps before and after PDF save", pdf.testHighlightFitsGlyphsAndLeavesLineGaps),
            ("Minimal context menu and underline save/undo", pdf.testUnderlineSaveUndoAndMinimalMenu),
            ("Markup context menu deletes an entire multiline operation with undo/redo", pdf.testMarkupContextMenuDeletesAnnotation),
            ("Markup groups persist across pages and save/reopen without deleting overlapping operations", pdf.testMarkupGroupsSurviveSaveAcrossPages),
            ("Ungrouped legacy annotations and notes delete individually", pdf.testUngroupedAnnotationsDeleteIndividually),
            ("Compact one-shot note and text/document undo", pdf.testCompactSingleUseNoteAndToolbarUndo),
            ("Note stays on one line throughout uncommitted IME input", pdf.testLiveNoteComposition),
            ("Active note border drag, resizing, single-line reflow, save and geometry undo at four zoom levels", pdf.testEditingNoteMoveAndResize),
            ("Note font defaults, live editing, selection, undo and PDF persistence", pdf.testNoteFontSizeEditingAndPersistence),
            ("Note move bar and resize targets keep their screen size across zoom levels", pdf.testNoteEditorScreenSizedTargets),
            ("Single-click saved overlapping note, edit undo and drag", pdf.testClickSavedNoteToResumeEditing),
            ("Saved markup recolors across pages through toolbar colors, preserving geometry, grouping and undo", pdf.testRecolorSavedMarkupGroups),
            ("Green, orange and blue highlights render opaque and stay unchanged across save", pdf.testHighlightColorsRenderOpaqueAndUnchangedAcrossSave),
            ("Shared palette creates and recolors highlight and underline with undo", pdf.testHighlightColorConfiguresAndRecolorsMarkup),
            ("Note visibility and position survive edit/cancel/save at four zoom levels", pdf.testNoteEditingVisibilityAndStableLayout),
            ("Editor and native PDF text render at the same position", pdf.testNoteTextMatchesPDFRendering),
            ("Red Hannotate notes persist, existing note conversion cancels and undoes", pdf.testFixedNoteStyleAndExistingNoteConversion),
            ("Empty note deletion on blur or extra Delete, with undo and cancel", pdf.testEmptyNoteDeletion),
            ("Editable zoom percentage, bounds and invalid input", pdf.testZoomPercentageInput)
        ]
        let before = failures
        do { try await translations.testHTTPFailureIsActionable() } catch { fail("HTTP failure check: \(error)") }
        print("\(failures == before ? "PASS" : "FAIL") HTTP failure produces actionable error")
        for (name, check) in checks {
            let before = failures
            do { try await check() } catch { fail("\(name): \(error)") }
            print("\(failures == before ? "PASS" : "FAIL") \(name)")
        }
        print("\(checks.count + 1) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
