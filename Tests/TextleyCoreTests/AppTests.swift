import AppKit
@testable import Textley
import TextleyCore
import WebKit
import XCTest

final class AppTests: XCTestCase {
    @MainActor
    func testLargeTextOpensAndEdits() async throws {
        guard ProcessInfo.processInfo.environment["TEXTLEY_CHECK_LARGE_FILES"] == "1" else {
            throw XCTSkip("Large-file timing is an opt-in check.")
        }
        _ = NSApplication.shared
        let lines = String(repeating: "A plain text fixture line with a short field and a counter.\n", count: 175_000)
        for (description, data) in [
            ("10 MB multiline", Data(lines.utf8)),
            ("10 MB single line", Data(repeating: 97, count: 10_000_000))
        ] {
            let started = ContinuousClock.now
            let document = try EditorDocument(data: data)
            document.scroll.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
            document.apply(EditorPreferences())
            document.scroll.tile()
            let layout = try XCTUnwrap(document.editor.layoutManager)
            let container = try XCTUnwrap(document.editor.textContainer)
            _ = layout.glyphRange(forBoundingRect: NSRect(x: 0, y: 0, width: 580, height: 440), in: container)
            let elapsed = started.duration(to: .now)
            print("\(description) open and layout: \(elapsed)")
            XCTAssertLessThan(elapsed, .seconds(2))
            document.editor.insertText("X", replacementRange: NSRange(location: 0, length: 0))
            XCTAssertTrue(document.text.hasPrefix("X"))
        }
    }

    @MainActor
    func testEditingUndoAndSavingPreserveDocumentState() async throws {
        _ = NSApplication.shared
        let folder = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("sample.md")
        let original = "id-12\nCafe\u{0301} 👩🏽‍💻"
        let format = TextFileFormat(encoding: .utf16BE, lineEnding: .crlf)
        let bytes = try format.encode(original)
        try bytes.write(to: url)

        let first = try EditorDocument(url: url, data: bytes)
        let second = try EditorDocument(data: Data("second".utf8))
        let workspace = WindowDocuments(documents: [first, second])
        XCTAssertNotNil(first.editor.textStorage)
        XCTAssertTrue(first.goToLine(2))
        XCTAssertEqual(first.editor.selectedRange().location, 6)
        first.showsPreview = true
        first.search.pattern = #"id-(\d+)"#
        first.search.isRegex = true
        first.replacement = "item[$1]"
        first.replaceAll()
        XCTAssertEqual(first.text, "item[12]\nCafe\u{0301} 👩🏽‍💻")
        XCTAssertTrue(first.isDirty)
        first.editor.breakUndoCoalescing()
        await Task.yield()
        XCTAssertTrue(first.history.canUndo)
        first.history.undo()
        XCTAssertEqual(first.text, original)
        XCTAssertFalse(first.isDirty)
        XCTAssertEqual(second.text, "second")
        workspace.cycle(direction: 1)
        XCTAssertTrue(workspace.active === second)
        workspace.cycle(direction: 1)
        XCTAssertTrue(workspace.active === first)
        XCTAssertTrue(first.showsPreview)

        first.languageOverride = .plain
        XCTAssertEqual(first.language, .plain)
        XCTAssertEqual(first.text, original)
        first.languageOverride = nil
        XCTAssertEqual(first.language, .markdown)

        first.apply(.uppercase)
        try first.save(to: url)
        let reopened = try TextFileFormat.decode(Data(contentsOf: url))
        XCTAssertEqual(reopened.format, format)
        XCTAssertFalse(reopened.text.hasSuffix("\n"))
        XCTAssertTrue(reopened.text.hasPrefix("ID-12"))
    }

    @MainActor
    func testWindowSwitchAndDetachPreserveScrollSelectionAndUndo() async throws {
        _ = NSApplication.shared
        let app = TextleyApplication()
        let content = (1...300).map { "Line \($0): editor fixture\n" }.joined()
        let first = try EditorDocument(data: Data(content.utf8))
        let second = try EditorDocument(data: Data("second tab".utf8))
        let third = try EditorDocument(data: Data("third tab".utf8))
        let controller = app.newWindow(with: [first, second, third])
        defer {
            let controllers = app.mcpTabs.map(\.0)
            for controller in controllers {
                controller.window?.orderOut(nil)
                app.removeWindow(controller)
            }
        }

        try await waitFor { first.editor.window === controller.window && first.scroll.contentSize.height > 100 }
        first.editor.insertText("Edited ", replacementRange: NSRange(location: 0, length: 0))
        first.editor.breakUndoCoalescing()
        XCTAssertTrue(first.goToLine(220))
        let cursor = first.editor.selectedRange()
        let scrollY = first.scroll.contentView.bounds.minY
        XCTAssertGreaterThan(scrollY, 100)
        XCTAssertTrue(first.history.canUndo)
        XCTAssertEqual(first.editor.accessibilityLabel(), "Document text")

        controller.documents.cycle(direction: 1)
        try await waitFor { second.editor.window === controller.window }
        controller.documents.cycle(direction: 1)
        try await waitFor { third.editor.window === controller.window }
        third.editor.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0),
                                   replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(third.editor.hasMarkedText())
        third.editor.unmarkText()
        XCTAssertTrue(third.text.hasPrefix("日本"))

        controller.documents.cycle(direction: 1)
        try await waitFor { first.editor.window === controller.window }
        XCTAssertEqual(first.editor.selectedRange(), cursor)
        XCTAssertEqual(first.scroll.contentView.bounds.minY, scrollY, accuracy: 1)

        controller.moveToNewWindow(first)
        let detached = try XCTUnwrap(app.mcpTabs.first(where: { $0.1 === first })?.0)
        XCTAssertFalse(detached === controller)
        try await waitFor { first.editor.window === detached.window && second.editor.window === controller.window }
        XCTAssertEqual(first.editor.selectedRange(), cursor)
        XCTAssertEqual(first.scroll.contentView.bounds.minY, scrollY, accuracy: 1)
        first.history.undo()
        XCTAssertEqual(first.text, content)
        XCTAssertEqual(second.text, "second tab")
        XCTAssertTrue(third.text.hasPrefix("日本"))
    }

    @MainActor
    func testMarkdownPreviewReplacesEditorAndPreservesDocumentState() async throws {
        _ = NSApplication.shared
        let app = TextleyApplication()
        let source = "# Trail Log\n\n" + (1...300).map { "Trail note \($0)\n" }.joined()
        let markdown = try EditorDocument(url: URL(fileURLWithPath: "/tmp/Trail Log.md"), data: Data(source.utf8))
        let second = try EditorDocument(url: URL(fileURLWithPath: "/tmp/Other.md"), data: Data("# Other".utf8))
        let controller = app.newWindow(with: [markdown, second])
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        defer { window.orderOut(nil); app.removeWindow(controller) }

        try await waitFor { markdown.editor.window === window && markdown.scroll.contentSize.height > 100 }
        markdown.editor.insertText("Updated ", replacementRange: NSRange(location: 2, length: 0))
        markdown.editor.breakUndoCoalescing()
        XCTAssertTrue(markdown.goToLine(200))
        let selection = markdown.editor.selectedRange()
        let scroll = markdown.scroll.contentView.bounds.minY
        XCTAssertGreaterThan(scroll, 100)

        markdown.showsPreview = true
        try await waitFor { markdown.editor.window == nil && self.containsMarkdownPreview(in: content) }
        controller.select(second)
        try await waitFor { second.editor.window === window && !self.containsMarkdownPreview(in: content) }
        controller.select(markdown)
        try await waitFor { markdown.editor.window == nil && self.containsMarkdownPreview(in: content) }

        markdown.showsPreview = false
        try await waitFor { markdown.editor.window === window && !self.containsMarkdownPreview(in: content) }
        XCTAssertEqual(markdown.editor.selectedRange(), selection)
        XCTAssertEqual(markdown.scroll.contentView.bounds.minY, scroll, accuracy: 1)
        XCTAssertTrue(markdown.history.canUndo)
        markdown.history.undo()
        XCTAssertEqual(markdown.text, source)

        markdown.showsPreview = true
        try await waitFor { markdown.editor.window == nil }
        markdown.openFind()
        try await waitFor { markdown.editor.window === window }
        XCTAssertFalse(markdown.showsPreview)
        XCTAssertTrue(markdown.showsFind)
    }

    @MainActor
    private func containsMarkdownPreview(in view: NSView) -> Bool {
        view is WKWebView || view.subviews.contains { containsMarkdownPreview(in: $0) }
    }

    @MainActor
    func testRelaunchRestoresVaultsAndImagesRefresh() async throws {
        _ = NSApplication.shared
        let directory = try fixtureDirectory()
        let suite = "Textley-vault-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let first = directory.appendingPathComponent("Notes", isDirectory: true).resolvingSymlinksInPath()
        let second = directory.appendingPathComponent("Reference", isDirectory: true).resolvingSymlinksInPath()
        for root in [first, second] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            try Data("A local file".utf8).write(to: root.appendingPathComponent("note.txt"))
            try imageData(width: 2, height: 3).write(to: root.appendingPathComponent("image.png"))
        }
        TextleyApplication(defaults: defaults).rememberVaults([first, second])

        let app = TextleyApplication(defaults: defaults)
        let controller = app.newWindow()
        defer { controller.window?.orderOut(nil); app.removeWindow(controller) }
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        try await waitFor {
            controller.documents.vaults.count == 2 && controller.documents.vaults.allSatisfy { $0.entries.count == 2 }
        }
        XCTAssertEqual(Set(controller.documents.vaults.map { $0.url.path }), Set([first.path, second.path]))
        let pictures = try [first, second].map { root in
            let document = try EditorDocument(imageURL: root.appendingPathComponent("image.png"))
            controller.documents.add(document)
            return document
        }
        XCTAssertTrue(pictures.allSatisfy { $0.isImage && $0.imageSize == CGSize(width: 2, height: 3) })
        try imageData(width: 5, height: 7).write(to: first.appendingPathComponent("image.png"), options: .atomic)
        try await waitFor { pictures[0].imageSize == CGSize(width: 5, height: 7) }
        XCTAssertEqual(pictures[1].imageSize, CGSize(width: 2, height: 3))

        let removed = try XCTUnwrap(controller.documents.vaults.first(where: { $0.url.path == first.path }))
        controller.removeVault(removed)
        XCTAssertEqual(defaults.stringArray(forKey: "vaultPaths"), [second.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.appendingPathComponent("note.txt").path))
    }

    @MainActor
    func testDirtyTabCloseChoicesAndCancelExternalOverwrite() async throws {
        _ = NSApplication.shared
        let directory = try fixtureDirectory()
        let suite = "Textley-close-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let documents = try ["Keep", "Discard", "Save"].map { name in
            let url = directory.appendingPathComponent(name + ".txt")
            let data = Data("original".utf8)
            try data.write(to: url)
            let document = try EditorDocument(url: url, data: data)
            document.apply(.uppercase)
            return document
        }
        let app = TextleyApplication(defaults: defaults)
        let controller = app.newWindow(with: documents)
        defer { controller.window?.orderOut(nil); app.removeWindow(controller) }

        withModalResponse(.alertSecondButtonReturn) { controller.closeTab(documents[0]) }
        XCTAssertTrue(controller.documents.tabs.contains { $0 === documents[0] })
        XCTAssertTrue(documents[0].isDirty)

        withModalResponse(.alertThirdButtonReturn) { controller.closeTab(documents[1]) }
        XCTAssertFalse(controller.documents.tabs.contains { $0 === documents[1] })
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(documents[1].url), encoding: .utf8), "original")

        withModalResponse(.alertFirstButtonReturn) { controller.closeTab(documents[2]) }
        XCTAssertFalse(controller.documents.tabs.contains { $0 === documents[2] })
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(documents[2].url), encoding: .utf8), "ORIGINAL")

        let conflictedURL = try XCTUnwrap(documents[0].url)
        try Data("external version".utf8).write(to: conflictedURL, options: .atomic)
        withModalResponse(.alertSecondButtonReturn) { XCTAssertFalse(controller.save(documents[0])) }
        XCTAssertEqual(try String(contentsOf: conflictedURL, encoding: .utf8), "external version")
        XCTAssertEqual(documents[0].text, "ORIGINAL")
        XCTAssertTrue(documents[0].isDirty)
    }

    @MainActor
    private func withModalResponse(_ response: NSApplication.ModalResponse, _ action: () -> Void) {
        let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard NSApp.modalWindow != nil else { return }
                NSApp.stopModal(withCode: response)
                timer.invalidate()
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate() }
        action()
    }

    private func imageData(width: Int, height: Int) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    @MainActor
    func testSettingsBackupRoundTripsAndRejectsInvalidPayload() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceName = UUID().uuidString
        let restoredName = UUID().uuidString
        let sourceDefaults = try XCTUnwrap(UserDefaults(suiteName: sourceName))
        let restoredDefaults = try XCTUnwrap(UserDefaults(suiteName: restoredName))
        defer {
            sourceDefaults.removePersistentDomain(forName: sourceName)
            restoredDefaults.removePersistentDomain(forName: restoredName)
        }
        let source = Preferences(defaults: sourceDefaults)
        let destination = Preferences(defaults: restoredDefaults)
        let file = directory.appendingPathComponent("settings.json")
        source.editor = EditorPreferences(fontSize: 19, wrap: true, lineNumbers: false)
        try source.export(to: file)
        try destination.restore(from: file)
        XCTAssertEqual(destination.editor, source.editor)
        XCTAssertEqual(Preferences(defaults: restoredDefaults).editor, source.editor)
        try Data(#"{"version":1,"editor":{"fontSize":99,"wrap":false,"lineNumbers":true}}"#.utf8).write(to: file)
        XCTAssertThrowsError(try destination.restore(from: file))
        XCTAssertEqual(destination.editor, source.editor)
    }

    @MainActor
    func testTwoVaultsWatchNestedChangesAndRefreshCleanDocuments() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstRoot = directory.appendingPathComponent("First")
        let secondRoot = directory.appendingPathComponent("Second")
        let nested = firstRoot.appendingPathComponent("Nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        let draftURL = nested.appendingPathComponent("draft.md")
        let otherURL = secondRoot.appendingPathComponent("other.txt")
        try Data("first".utf8).write(to: draftURL)
        try Data("second".utf8).write(to: otherURL)
        let document = try EditorDocument(url: draftURL, data: Data(contentsOf: draftURL))
        let first = FolderVault(url: firstRoot.resolvingSymlinksInPath()) { _ in document.refreshFromFolder() }
        let second = FolderVault(url: secondRoot.resolvingSymlinksInPath()) { _ in }
        defer { first.stop(); second.stop() }
        try await waitFor { first.entries.first?.children?.first?.name == "draft.md" && second.entries.first?.name == "other.txt" }

        let newFile = nested.appendingPathComponent("new.md")
        try Data("# New".utf8).write(to: newFile)
        try await waitFor { first.entries.first?.children?.contains(where: { $0.name == "new.md" }) == true }
        let moved = secondRoot.appendingPathComponent("moved.md")
        try FileManager.default.moveItem(at: newFile, to: moved)
        try await waitFor {
            first.entries.first?.children?.contains(where: { $0.name == "new.md" }) == false
                && second.entries.contains(where: { $0.name == "moved.md" })
        }
        try FileManager.default.removeItem(at: moved)
        try await waitFor { !second.entries.contains(where: { $0.name == "moved.md" }) }

        try Data("changed externally".utf8).write(to: draftURL, options: .atomic)
        try await waitFor { document.text == "changed externally" }
        document.apply(.uppercase)
        XCTAssertTrue(document.isDirty)
        try Data("another edit".utf8).write(to: draftURL, options: .atomic)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(document.text, "CHANGED EXTERNALLY")
        XCTAssertThrowsError(try document.save(to: draftURL))
        XCTAssertEqual(try String(contentsOf: draftURL, encoding: .utf8), "another edit")
    }

    @MainActor
    private func waitFor(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let until = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() && ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(80)) }
        XCTAssertTrue(condition(), "The observed state did not update", file: file, line: line)
    }
}
