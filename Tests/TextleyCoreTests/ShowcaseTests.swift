import AppKit
import SwiftUI
import WebKit
@testable import Textley
import XCTest

final class ShowcaseTests: XCTestCase {
    @MainActor
    func testRecordMarkdownViewSwitch() async throws {
        guard let output = ProcessInfo.processInfo.environment["TEXTLEY_MARKDOWN_RECORDING"] else {
            throw XCTSkip("No Markdown recording requested.")
        }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        _ = NSApplication.shared
        let app = TextleyApplication()
        let source = """
            # Trail Log

            ## North Ridge

            The trail is open. Check the map before you leave.

            - Water at mile 2
            - Return before dusk

            **Status:** draft
            """
        let document = try EditorDocument(url: directory.appendingPathComponent("Trail Log.md"), data: Data(source.utf8))
        let controller = app.newWindow(with: [document])
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        defer { window.orderOut(nil); app.removeWindow(controller) }
        window.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .milliseconds(500))

        let picker = try XCTUnwrap(markdownPicker(in: content))
        XCTAssertEqual(picker.selectedSegment, 0)
        let started = ProcessInfo.processInfo.systemUptime
        var timestamps: [Double] = []
        for index in 0..<54 {
            switch index {
            case 14, 40:
                picker.selectedSegment = 1
                XCTAssertTrue(picker.sendAction(picker.action, to: picker.target))
                XCTAssertTrue(document.isShowingMarkdownPreview)
            case 27:
                picker.selectedSegment = 0
                XCTAssertTrue(picker.sendAction(picker.action, to: picker.target))
                XCTAssertFalse(document.isShowingMarkdownPreview)
            case 34:
                let range = (document.text as NSString).range(of: "draft")
                document.editor.insertText("ready for review", replacementRange: range)
            default: break
            }
            try await Task.sleep(for: .milliseconds(70))
            timestamps.append(ProcessInfo.processInfo.systemUptime - started)
            try await capture(window, to: directory.appendingPathComponent(String(format: "%03d.png", index)),
                              permitsLoadingPreview: true)
        }
        let web = try XCTUnwrap(firstWebView(in: content))
        let renderedText = try await web.evaluateJavaScript("document.body.textContent") as? String
        XCTAssertTrue(renderedText?.contains("ready for review") == true)
        try JSONEncoder().encode(timestamps).write(to: directory.appendingPathComponent("timestamps.json"))
    }

    @MainActor
    private func markdownPicker(in view: NSView) -> NSSegmentedControl? {
        if let picker = view as? NSSegmentedControl, picker.segmentCount == 2,
           picker.label(forSegment: 0) == "Markdown", picker.label(forSegment: 1) == "Preview" { return picker }
        return view.subviews.lazy.compactMap { self.markdownPicker(in: $0) }.first
    }

    @MainActor
    func testRecordEditorAcceptance() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let output = environment["TEXTLEY_ACCEPTANCE_FRAMES"] else {
            throw XCTSkip("No editor acceptance recording requested.")
        }

        let frameDirectory = URL(fileURLWithPath: output, isDirectory: true)
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let notes = fixture.appendingPathComponent("Field Notes")
        let reference = fixture.appendingPathComponent("Reference")
        for folder in [notes, reference] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: fixture) }

        let markdownURL = notes.appendingPathComponent("Trail Log.md")
        let swiftURL = reference.appendingPathComponent("Trail.swift")
        let imageURL = reference.appendingPathComponent("Trail Map.png")
        let externalURL = notes.appendingPathComponent("Trail Update.txt")
        let markdown = """
            # Trail Log

            ## North Ridge

            The trail is open. Check the map before you leave.

            - Water at mile 2
            - Return before dusk

            **Status:** draft

            """
        let swift = """
            import Foundation

            struct Trail {
                let name: String
                let distance: Double
            }

            let route = Trail(name: "North Ridge", distance: 4.8)
            """
        try Data(markdown.utf8).write(to: markdownURL)
        try Data(swift.utf8).write(to: swiftURL)
        let map = NSImage(size: NSSize(width: 450, height: 270), flipped: true) { bounds in
            NSColor(calibratedRed: 0.09, green: 0.16, blue: 0.18, alpha: 1).setFill()
            bounds.fill()
            NSColor(calibratedRed: 0.56, green: 0.91, blue: 0.71, alpha: 1).setStroke()
            let trail = NSBezierPath()
            trail.move(to: NSPoint(x: 62, y: 200))
            trail.line(to: NSPoint(x: 155, y: 128))
            trail.line(to: NSPoint(x: 225, y: 156))
            trail.line(to: NSPoint(x: 371, y: 57))
            trail.lineWidth = 5
            trail.lineCapStyle = .round
            trail.stroke()
            ("NORTH RIDGE" as NSString).draw(at: NSPoint(x: 32, y: 26), withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 20, weight: .semibold),
                .foregroundColor: NSColor.white
            ])
            return true
        }
        let mapData = try XCTUnwrap(map.tiffRepresentation)
        let mapBitmap = try XCTUnwrap(NSBitmapImageRep(data: mapData))
        try XCTUnwrap(mapBitmap.representation(using: .png, properties: [:])).write(to: imageURL)

        _ = NSApplication.shared
        let suite = "Textley-acceptance-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = TextleyApplication(defaults: defaults)
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let controller = try XCTUnwrap(app.activeWindow)
        let window = try XCTUnwrap(controller.window)
        defer { window.orderOut(nil); app.removeWindow(controller) }
        window.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .milliseconds(300))
        let launchSize = try XCTUnwrap(window.contentView).bounds.size
        print("Textley first launch content: \(launchSize.width) × \(launchSize.height) points")
        XCTAssertEqual(launchSize.width, 1_000, accuracy: 1)
        XCTAssertEqual(launchSize.height, 650, accuracy: 1)
        await assertCapture(window, in: frameDirectory, named: "01-launch")

        for folder in [notes, reference] { controller.addVault(folder.resolvingSymlinksInPath()) }
        app.rememberVaults([notes, reference])
        app.openFiles([markdownURL, swiftURL], in: controller)
        let code = try XCTUnwrap(controller.documents.active)
        XCTAssertEqual(code.language, .swift)
        XCTAssertEqual(controller.documents.tabs.count, 2)
        XCTAssertEqual(controller.documents.vaults.count, 2)
        app.preferences.editor.lineNumbers = false
        await assertCapture(window, in: frameDirectory, named: "02-tabs")
        app.preferences.editor.lineNumbers = true

        let draft = try XCTUnwrap(controller.documents.tabs.first)
        controller.select(draft)
        draft.showsPreview = true
        await assertCapture(window, in: frameDirectory, named: "03-preview")
        draft.showsPreview = false
        try await Task.sleep(for: .milliseconds(150))

        let range = (draft.text as NSString).range(of: "draft")
        XCTAssertNotEqual(range.location, NSNotFound)
        draft.editor.insertText("ready for review", replacementRange: range)
        XCTAssertTrue(draft.isDirty)
        await assertCapture(window, in: frameDirectory, named: "04-edit")
        draft.showsPreview = true
        await assertCapture(window, in: frameDirectory, named: "04-preview-update")
        let web = try XCTUnwrap(firstWebView(in: try XCTUnwrap(window.contentView)))
        let previewText = try await web.evaluateJavaScript("document.body.textContent") as? String
        XCTAssertTrue(previewText?.contains("ready for review") == true)
        XCTAssertTrue(controller.save(draft))
        XCTAssertFalse(draft.isDirty)
        XCTAssertTrue(try String(contentsOf: markdownURL, encoding: .utf8).contains("ready for review"))
        await assertCapture(window, in: frameDirectory, named: "05-save")

        controller.select(code)
        code.showsFind = true
        code.search.pattern = #"North (\w+)"#
        code.search.isRegex = true
        code.replacement = "South $1"
        code.replaceAll()
        XCTAssertTrue(code.text.contains("South Ridge"))
        code.editor.setSelectedRange(NSRange(location: 0, length: 0))
        await assertCapture(window, in: frameDirectory, named: "06-regex")
        code.editor.breakUndoCoalescing()
        code.history.undo()
        XCTAssertEqual(code.text, swift)

        try Data("The ranger updated the route this morning.\n".utf8).write(to: externalURL)
        let vault = try XCTUnwrap(controller.documents.vaults.first)
        for _ in 0..<40 {
            if vault.entries.contains(where: { $0.name == externalURL.lastPathComponent }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(vault.entries.contains(where: { $0.name == externalURL.lastPathComponent }))
        app.openFiles([externalURL, imageURL], in: controller)
        XCTAssertTrue(try XCTUnwrap(controller.documents.active).isImage)
        await assertCapture(window, in: frameDirectory, named: "07-watch-image")

        controller.select(draft)
        XCTAssertTrue(draft.showsPreview)
        XCTAssertEqual(defaults.stringArray(forKey: "vaultPaths")?.count, 2)
        await assertCapture(window, in: frameDirectory, named: "08-return")

        let service = TextleyMCPService(defaults: defaults, port: 0, token: try TextleyMCPToken.generate())
        await service.attach(store: app)
        XCTAssertFalse(service.enabled)
        await service.setEnabled(true)
        await service.testConnection()
        XCTAssertEqual(service.testMessage, "Connection check passed · 27 tools available · Read only")
        let settings = NSWindow(contentRect: NSRect(origin: .zero, size: SettingsView.contentSize),
                                styleMask: [.titled, .closable], backing: .buffered, defer: false)
        settings.title = "Textley Settings"
        settings.appearance = window.appearance
        settings.contentViewController = NSHostingController(rootView:
            SettingsView(preferences: app.preferences, mcp: service, initialPage: .integrations)
        )
        settings.center()
        settings.orderFront(nil)
        await assertCapture(settings, in: frameDirectory, named: "09-connection")
        settings.orderOut(nil)
        await service.setEnabled(false)
    }

    @MainActor
    func testNativeScreenshotForWebsite() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let output = environment["TEXTLEY_SHOWCASE_OUTPUT"],
              let fixture = environment["TEXTLEY_SHOWCASE_FIXTURE"] else { throw XCTSkip("No website screenshot requested.") }
        _ = NSApplication.shared
        let suite = "Textley-showcase-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = TextleyApplication(defaults: defaults)
        app.preferences.editor.wrap = true
        let root = URL(fileURLWithPath: fixture)
        let notes = root.appendingPathComponent("Field Notes")
        let reference = root.appendingPathComponent("Reference")
        let markdownURL = notes.appendingPathComponent("Journal/Trail Log.md")
        let swiftURL = notes.appendingPathComponent("Trail.swift")
        let routeURL = reference.appendingPathComponent("Route.txt")
        let markdown = try EditorDocument(url: markdownURL, data: Data(contentsOf: markdownURL))
        let swift = try EditorDocument(url: swiftURL, data: Data(contentsOf: swiftURL))
        let route = try EditorDocument(url: routeURL, data: Data(contentsOf: routeURL))
        markdown.showsPreview = true
        let controller = app.newWindow(with: [markdown, swift, route])
        defer { controller.window?.orderOut(nil); app.removeWindow(controller) }
        controller.addVault(notes.resolvingSymlinksInPath())
        controller.addVault(reference.resolvingSymlinksInPath())
        let window = try XCTUnwrap(controller.window)
        window.appearance = NSAppearance(named: .darkAqua)
        let content = try XCTUnwrap(window.contentView)
        try await Task.sleep(for: .milliseconds(1300))
        window.displayIfNeeded()
        content.layoutSubtreeIfNeeded()
        XCTAssertNil(markdown.editor.window)
        let preview = try XCTUnwrap(firstWebView(in: content))
        XCTAssertGreaterThan(preview.bounds.width, 600)
        try await capture(window, to: URL(fileURLWithPath: output))
    }

    @MainActor
    private func assertCapture(_ window: NSWindow, in folder: URL, named name: String, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await Task.sleep(for: .milliseconds(650))
            try await capture(window, to: folder.appendingPathComponent(name + ".png"))
        } catch {
            XCTFail("Capture \(name): \(error)", file: file, line: line)
        }
    }

    @MainActor
    private func capture(_ window: NSWindow, to destination: URL, permitsLoadingPreview: Bool = false) async throws {
        window.displayIfNeeded()
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let nativeChrome = content.superview ?? content
        let rectangle = nativeChrome.bounds
        let bitmap = try XCTUnwrap(nativeChrome.bitmapImageRepForCachingDisplay(in: rectangle))
        nativeChrome.cacheDisplay(in: rectangle, to: bitmap)

        if let web = firstWebView(in: nativeChrome) {
            let configuration = WKSnapshotConfiguration()
            configuration.rect = web.bounds
            let preview: NSImage
            do {
                preview = try await web.takeSnapshot(configuration: configuration)
            } catch {
                guard permitsLoadingPreview else { throw error }
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: destination, options: .atomic)
                return
            }
            let area = nativeChrome.convert(web.bounds, from: web)
            let image = NSImage(size: rectangle.size)
            image.lockFocus()
            NSImage(size: rectangle.size, flipped: false) { dest in bitmap.draw(in: dest); return true }.draw(in: rectangle)
            preview.draw(in: area)
            image.unlockFocus()
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            let result = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try result.write(to: destination, options: .atomic)
        } else {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: destination, options: .atomic)
        }
    }

    @MainActor
    private func firstWebView(in view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap { self.firstWebView(in: $0) }.first
    }
}
