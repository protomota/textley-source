import AppKit
import SwiftUI
import TextleyCore

@main
struct TextleyMain {
    @MainActor static func main() {
        if CommandLine.arguments.contains(TextleyMCPDesktopSetup.argument) {
            Task.detached {
                await TextleyMCPStdioBridge.run()
                exit(0)
            }
            dispatchMain()
        }
        let app = NSApplication.shared
        let delegate = TextleyApplication()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class TextleyApplication: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let preferences: Preferences
    let mcp: TextleyMCPService
    private let defaults: UserDefaults
    private var windows: [EditorWindow] = []
    private var settings: NSWindowController?
    private let recentMenu = NSMenu(title: "Open Recent")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferences = Preferences(defaults: defaults)
        mcp = TextleyMCPService(defaults: defaults)
        super.init()
    }

    var activeWindow: EditorWindow? {
        (NSApp.keyWindow?.windowController as? EditorWindow)
            ?? (NSApp.mainWindow?.windowController as? EditorWindow)
            ?? windows.last
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        installMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if windows.isEmpty { newTab() }
        if let controller = windows.first {
            for path in defaults.stringArray(forKey: "vaultPaths") ?? [] {
                controller.addVault(URL(fileURLWithPath: path, isDirectory: true))
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        Task { await mcp.attach(store: self) }
        #if TEXTLEY_SPARKLE
        TextleyUpdates.shared.start()
        #endif
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let activeWindow { activeWindow.showWindow(nil) } else { newTab() }
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) { openFiles(urls) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for controller in windows where !controller.approveClosingWindow() { return .terminateCancel }
        return .terminateNow
    }

    @discardableResult
    func newWindow(with documents: [EditorDocument] = []) -> EditorWindow {
        let controller = EditorWindow(application: self, documents: documents)
        windows.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.focusActive()
        return controller
    }

    func removeWindow(_ controller: EditorWindow) {
        for vault in controller.documents.vaults { vault.stop() }
        windows.removeAll { $0 === controller }
    }

    @objc func newTab() { _ = try? makeNewTab() }

    func makeNewTab() throws -> EditorDocument {
        let document = try EditorDocument()
        if let activeWindow {
            activeWindow.documents.add(document)
            activeWindow.showWindow(nil)
            activeWindow.focusActive()
        } else {
            newWindow(with: [document])
        }
        return document
    }

    @objc private func newWindowAction() {
        if let document = try? EditorDocument() { newWindow(with: [document]) }
    }

    @objc func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.title = "Open Files"
        if panel.runModal() == .OK { openFiles(panel.urls) }
    }

    @objc func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open"
        panel.title = "Open Folders"
        guard panel.runModal() == .OK else { return }
        let controller = activeWindow ?? newWindow()
        for url in panel.urls { controller.addVault(canonical(url)) }
        controller.documents.showsSidebar = true
        rememberVaults(panel.urls)
    }

    func rememberVaults(_ urls: [URL]) {
        let remembered = Set(defaults.stringArray(forKey: "vaultPaths") ?? [])
        let selected = urls.map { canonical($0).path }
        defaults.set(Array(remembered.union(selected)).sorted(), forKey: "vaultPaths")
    }

    func forgetVault(_ url: URL) {
        let paths = defaults.stringArray(forKey: "vaultPaths") ?? []
        defaults.set(paths.filter { $0 != url.path }, forKey: "vaultPaths")
    }

    func refreshDocuments(in root: URL) {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        for controller in windows {
            for document in controller.documents.tabs where document.url?.path.hasPrefix(prefix) == true {
                document.refreshFromFolder()
            }
        }
    }

    func openFiles(_ inputs: [URL], in preferred: EditorWindow? = nil) {
        var target = preferred ?? activeWindow
        for input in inputs where input.isFileURL {
            let url = canonical(input)
            if let (controller, existing) = owner(of: url) {
                controller.showWindow(nil)
                controller.window?.makeKeyAndOrderFront(nil)
                controller.select(existing)
                target = controller
                continue
            }
            do {
                let document = try readDocument(url)
                if let target {
                    if target.documents.tabs.count == 1, let draft = target.documents.active,
                       draft.url == nil, !draft.isDirty, draft.change == 0 {
                        target.documents.remove(draft)
                    }
                    target.documents.add(document)
                    target.showWindow(nil)
                    target.window?.makeKeyAndOrderFront(nil)
                    target.focusActive()
                } else {
                    target = newWindow(with: [document])
                }
                noteRecent(url)
            } catch { NSApp.presentError(error) }
        }
    }

    func openFileForMCP(_ url: URL) throws -> EditorDocument {
        if let (controller, document) = owner(of: url) {
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            controller.select(document)
            return document
        }
        let document = try readDocument(url)
        if let controller = activeWindow {
            controller.documents.add(document)
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            controller.focusActive()
        } else {
            newWindow(with: [document])
        }
        noteRecent(url)
        return document
    }

    private func readDocument(_ url: URL) throws -> EditorDocument {
        if FolderEntry.isImage(url) { return try EditorDocument(imageURL: url) }
        return try EditorDocument(url: url, data: TextFileAccess.read(url))
    }

    var mcpTabs: [(EditorWindow, EditorDocument)] {
        windows.flatMap { controller in controller.documents.tabs.map { (controller, $0) } }
    }

    var mcpVaults: [FolderVault] {
        var found = Set<URL>()
        return windows.flatMap { $0.documents.vaults }.filter { found.insert($0.url).inserted }
    }

    func owner(of url: URL, excluding excluded: EditorDocument? = nil) -> (EditorWindow, EditorDocument)? {
        let url = canonical(url)
        for controller in windows {
            if let document = controller.documents.tabs.first(where: { $0 !== excluded && $0.url == url }) {
                return (controller, document)
            }
        }
        return nil
    }

    private func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }

    func noteRecent(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        var paths = (defaults.stringArray(forKey: "recentPaths") ?? []).filter { $0 != url.path }
        paths.insert(url.path, at: 0)
        defaults.set(Array(paths.prefix(12)), forKey: "recentPaths")
        populateRecent()
    }

    private func populateRecent() {
        recentMenu.removeAllItems()
        let paths = defaults.stringArray(forKey: "recentPaths") ?? []
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let menuItem = item(url.lastPathComponent, #selector(openRecent(_:)))
            menuItem.representedObject = url
            menuItem.toolTip = path
            recentMenu.addItem(menuItem)
        }
        if paths.isEmpty {
            let empty = NSMenuItem(title: "No Recent Files", action: nil, keyEquivalent: "")
            recentMenu.addItem(empty)
        } else {
            recentMenu.addItem(.separator())
            recentMenu.addItem(item("Clear Menu", #selector(clearRecent)))
        }
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { openFiles([url]) }
    }

    @objc private func clearRecent() {
        defaults.removeObject(forKey: "recentPaths")
        NSDocumentController.shared.clearRecentDocuments(nil)
        populateRecent()
    }

    @objc private func save() {
        if let controller = activeWindow, let document = controller.documents.active { _ = controller.save(document) }
    }

    @objc private func saveCopy() {
        if let controller = activeWindow, let document = controller.documents.active { _ = controller.save(document, copy: true) }
    }

    @objc private func closeTab() {
        if let controller = activeWindow {
            if let document = controller.documents.active { controller.closeTab(document) }
            else { controller.window?.performClose(nil) }
        }
    }

    @objc private func nextTab() { activeWindow?.documents.cycle(direction: 1); activeWindow?.focusActive() }
    @objc private func previousTab() { activeWindow?.documents.cycle(direction: -1); activeWindow?.focusActive() }
    @objc private func moveTab() {
        if let controller = activeWindow, let document = controller.documents.active { controller.moveToNewWindow(document) }
    }

    @objc private func find() { activeWindow?.documents.active?.openFind() }
    @objc private func findNext() { activeWindow?.documents.active?.findNext() }
    @objc private func findPrevious() { activeWindow?.documents.active?.findNext(backward: true) }

    @objc private func goToLine() {
        guard let document = activeWindow?.documents.active else { return }
        let alert = NSAlert()
        alert.messageText = "Go to Line"
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 180, height: 24))
        field.placeholderString = "Line number"
        field.setAccessibilityLabel("Line number")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            if let number = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), document.goToLine(number) { return }
            let invalid = NSAlert()
            invalid.messageText = "That line isn’t in this document"
            invalid.runModal()
        }
    }

    @objc private func cleanup(_ sender: NSMenuItem) {
        if let operation = Cleanup(rawValue: sender.title) { activeWindow?.documents.active?.apply(operation) }
    }

    @objc private func toggleSidebar() { activeWindow?.documents.showsSidebar.toggle() }
    @objc private func toggleWrap() { preferences.editor.wrap.toggle() }
    @objc private func toggleLineNumbers() { preferences.editor.lineNumbers.toggle() }
    @objc private func togglePreview() {
        guard let document = activeWindow?.documents.active, document.language == .markdown else { return }
        document.showsPreview.toggle()
    }

    @objc private func showSettings() {
        if settings == nil {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: SettingsView.contentSize),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Textley Settings"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SettingsView(preferences: preferences, mcp: mcp))
            window.center()
            settings = NSWindowController(window: window)
        }
        settings?.showWindow(nil)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let document = activeWindow?.documents.active
        switch item.action {
        case #selector(save), #selector(saveCopy), #selector(find), #selector(findNext), #selector(findPrevious),
             #selector(cleanup(_:)), #selector(goToLine):
            return document?.isImage == false
        case #selector(togglePreview):
            item.state = document?.showsPreview == true ? .on : .off
            return document?.language == .markdown
        case #selector(toggleSidebar):
            item.state = activeWindow?.documents.showsSidebar == true ? .on : .off
            return activeWindow != nil
        case #selector(toggleWrap):
            item.state = preferences.editor.wrap ? .on : .off
            return true
        case #selector(toggleLineNumbers):
            item.state = preferences.editor.lineNumbers ? .on : .off
            return true
        #if TEXTLEY_SPARKLE
        case #selector(checkForUpdates): return TextleyUpdates.shared.canCheck
        #endif
        case #selector(moveTab): return document != nil
        case #selector(closeTab): return activeWindow != nil
        case #selector(nextTab), #selector(previousTab): return (activeWindow?.documents.tabs.count ?? 0) > 1
        default: return true
        }
    }

    private func item(_ title: String, _ action: Selector, _ key: String = "",
                      modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private func standard(_ title: String, _ action: Selector, _ key: String,
                          modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    #if TEXTLEY_SPARKLE
    @objc private func checkForUpdates() { TextleyUpdates.shared.check() }
    #endif

    private func installMenu() {
        let root = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let menu = NSMenu(title: title)
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            parent.submenu = menu
            root.addItem(parent)
            for item in items { menu.addItem(item) }
            return menu
        }

        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        var appItems: [NSMenuItem] = [
            standard("About Textley", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "")
        ]
        #if TEXTLEY_SPARKLE
        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        appItems.append(updates)
        #endif
        _ = add("Textley", appItems + [
            .separator(), item("Settings…", #selector(showSettings), ","), .separator(), servicesItem, .separator(),
            standard("Hide Textley", #selector(NSApplication.hide(_:)), "h"),
            standard("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", modifiers: [.command, .option]),
            standard("Show All", #selector(NSApplication.unhideAllApplications(_:)), ""),
            .separator(), standard("Quit Textley", #selector(NSApplication.terminate(_:)), "q")
        ])
        NSApp.servicesMenu = services

        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recentItem.submenu = recentMenu
        populateRecent()
        _ = add("File", [
            item("New Document", #selector(newTab), "n"),
            item("New Window", #selector(newWindowAction), "n", modifiers: [.command, .shift]),
            item("Open…", #selector(openPanel), "o"),
            item("Open Folder…", #selector(openFolderPanel), "o", modifiers: [.command, .shift]), recentItem, .separator(),
            item("Close Tab", #selector(closeTab), "w"),
            standard("Close Window", #selector(NSWindow.performClose(_:)), "w", modifiers: [.command, .shift]),
            item("Save", #selector(save), "s"),
            item("Save a Copy…", #selector(saveCopy), "s", modifiers: [.command, .shift])
        ])
        _ = add("Edit", [
            standard("Undo", Selector(("undo:")), "z"),
            standard("Redo", Selector(("redo:")), "z", modifiers: [.command, .shift]), .separator(),
            standard("Cut", #selector(NSText.cut(_:)), "x"),
            standard("Copy", #selector(NSText.copy(_:)), "c"),
            standard("Paste", #selector(NSText.paste(_:)), "v"),
            standard("Select All", #selector(NSText.selectAll(_:)), "a"), .separator(),
            item("Find…", #selector(find), "f"),
            item("Find Next", #selector(findNext), "g"),
            item("Find Previous", #selector(findPrevious), "g", modifiers: [.command, .shift]),
            item("Go to Line…", #selector(goToLine), "l")
        ])
        _ = add("Text", Cleanup.allCases.map { item($0.rawValue, #selector(cleanup(_:))) })
        _ = add("View", [
            item("Show Sidebar", #selector(toggleSidebar), "s", modifiers: [.command, .control]),
            item("Show Line Numbers", #selector(toggleLineNumbers)),
            item("Soft Wrap", #selector(toggleWrap)),
            item("Markdown Preview", #selector(togglePreview), "p", modifiers: [.command, .option])
        ])
        let windowMenu = add("Window", [
            standard("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            standard("Zoom", #selector(NSWindow.performZoom(_:)), ""),
            .separator(), item("Next Tab", #selector(nextTab), "]", modifiers: [.command, .shift]),
            item("Previous Tab", #selector(previousTab), "[", modifiers: [.command, .shift]),
            item("Move Tab to New Window", #selector(moveTab)), .separator(),
            standard("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), "")
        ])
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = root
    }
}
