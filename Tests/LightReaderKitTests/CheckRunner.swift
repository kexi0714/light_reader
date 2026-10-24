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

@main
struct CheckRunner {
    @MainActor static func main() async {
        let translations = TranslationTests()
        let pdf = PDFTests()
        let settings = SettingsTests()
        let tabs = TabTests()
        let checks: [(String, () throws -> Void)] = [
            ("Welcome window centers after layout, including multiple-screen coordinates", tabs.testInitialWindowPlacement),
            ("Native PDF tabs append, switch, reuse and close independently", tabs.testNativeDocumentTabs),
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
            ("Chinese notes and highlights survive PDF save", pdf.testAnnotationsRoundTripAsStandardPDF),
            ("Annotation undo, redo and document isolation", pdf.testAnnotationUndoRedoAndDocumentIsolation),
            ("Multiline highlight and rotated PDF round-trip", pdf.testMultilineHighlightAndRotatedPageSurviveSave),
            ("Minimal context menu and underline save/undo", pdf.testUnderlineSaveUndoAndMinimalMenu),
            ("Compact one-shot note and text/document undo", pdf.testCompactSingleUseNoteAndToolbarUndo),
            ("Single-click saved overlapping note, edit undo and drag", pdf.testClickSavedNoteToResumeEditing),
            ("Shared palette configures context highlight and underline", pdf.testHighlightColorOnlyConfiguresContextMenu),
            ("Note visibility and position survive edit/cancel/save at four zoom levels", pdf.testNoteEditingVisibilityAndStableLayout),
            ("Editor and native PDF text render at the same position", pdf.testNoteTextMatchesPDFRendering),
            ("Red Hannotate notes persist, existing note conversion cancels and undoes", pdf.testFixedNoteStyleAndExistingNoteConversion),
            ("Empty note deletion on blur or extra Delete, with undo and cancel", pdf.testEmptyNoteDeletion),
            ("Editable zoom percentage, bounds and invalid input", pdf.testZoomPercentageInput)
        ]
        for (name, check) in checks {
            let before = failures
            do { try check() } catch { fail("\(name): \(error)") }
            print("\(failures == before ? "PASS" : "FAIL") \(name)")
        }
        let before = failures
        do { try await translations.testHTTPFailureIsActionable() } catch { fail("HTTP failure check: \(error)") }
        print("\(failures == before ? "PASS" : "FAIL") HTTP failure produces actionable error")
        print("\(checks.count + 1) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
