import AppKit
import Observation
import SwiftUI
import TextleyCore

@MainActor @Observable
final class WindowDocuments {
    var tabs: [EditorDocument]
    var selectedID: UUID?
    var showsSidebar = true
    var vaults: [FolderVault] = []

    init(documents: [EditorDocument]) {
        tabs = documents
        selectedID = documents.first?.id
    }

    var active: EditorDocument? { tabs.first { $0.id == selectedID } }

    func select(_ id: UUID?) {
        selectedID = id
    }

    func add(_ document: EditorDocument) {
        tabs.append(document)
        select(document.id)
    }

    func remove(_ document: EditorDocument) {
        guard let index = tabs.firstIndex(where: { $0.id == document.id }) else { return }
        let wasSelected = document.id == selectedID
        tabs.remove(at: index)
        if wasSelected {
            select(tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id)
        }
    }

    func cycle(direction: Int) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == selectedID }) else { return }
        select(tabs[(index + direction + tabs.count) % tabs.count].id)
    }
}

@MainActor
final class EditorWindow: NSWindowController, NSWindowDelegate {
    let documents: WindowDocuments
    unowned let application: TextleyApplication

    init(application: TextleyApplication, documents: [EditorDocument]) {
        self.application = application
        self.documents = WindowDocuments(documents: documents)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        super.init(window: window)
        window.title = "Textley"
        window.minSize = NSSize(width: 590, height: 350)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.delegate = self
        let content = NSHostingController(rootView: WorkspaceView(controller: self))
        content.sizingOptions = []
        window.contentViewController = content
        window.setContentSize(NSSize(width: 1000, height: 650))
        window.center()
        syncWindow()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func syncWindow() {
        let document = documents.active
        window?.title = document?.title ?? "Textley"
        window?.representedURL = document?.url
        window?.isDocumentEdited = document?.isDirty ?? false
    }

    func focusActive() {
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let document = self?.documents.active, !document.isShowingMarkdownPreview else { return }
            document.focusEditor()
        }
    }

    func select(_ document: EditorDocument) {
        documents.select(document.id)
        focusActive()
    }

    func closeTab(_ document: EditorDocument) {
        guard approveClosing(document) else { return }
        documents.remove(document)
        focusActive()
    }

    func moveToNewWindow(_ document: EditorDocument) {
        documents.remove(document)
        document.scroll.removeFromSuperview()
        application.newWindow(with: [document])
        syncWindow()
    }

    func addVault(_ url: URL) {
        guard !documents.vaults.contains(where: { $0.url == url }) else { return }
        documents.vaults.append(FolderVault(url: url) { [weak self] root in
            self?.application.refreshDocuments(in: root)
        })
    }

    func removeVault(_ vault: FolderVault) {
        vault.stop()
        documents.vaults.removeAll { $0 === vault }
        application.forgetVault(vault.url)
    }

    func save(_ document: EditorDocument, copy: Bool = false) -> Bool {
        var destination = document.url
        if destination == nil || copy {
            destination = chooseDestination(for: document, copy: copy)
        }
        guard let url = destination else { return false }
        if application.owner(of: url, excluding: copy ? nil : document) != nil {
            showError(TextFileError.openDestination)
            return false
        }
        do {
            try document.save(to: url, copy: copy)
        } catch TextFileError.diskChanged {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "“\(document.title)” changed on disk"
            alert.informativeText = "Save a copy to keep both versions, or replace the file with your edits."
            alert.addButton(withTitle: "Save a Copy…")
            alert.addButton(withTitle: "Cancel")
            let replace = alert.addButton(withTitle: "Replace File")
            replace.hasDestructiveAction = true
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                guard let newURL = chooseDestination(for: document, copy: true) else { return false }
                guard application.owner(of: newURL) == nil else {
                    showError(TextFileError.openDestination)
                    return false
                }
                do {
                    try document.save(to: newURL)
                    destination = newURL
                } catch { showError(error); return false }
            case .alertThirdButtonReturn:
                do { try document.save(to: url, force: true) } catch { showError(error); return false }
            default: return false
            }
        } catch {
            showError(error)
            return false
        }
        if let destination { application.noteRecent(destination) }
        syncWindow()
        return true
    }

    private func chooseDestination(for document: EditorDocument, copy: Bool) -> URL? {
        let panel = NSSavePanel()
        panel.title = copy ? "Save a Copy" : "Save Document"
        panel.canCreateDirectories = true
        if let url = document.url {
            panel.directoryURL = url.deletingLastPathComponent()
            if copy {
                let name = url.deletingPathExtension().lastPathComponent + " copy"
                panel.nameFieldStringValue = url.pathExtension.isEmpty ? name : name + "." + url.pathExtension
            } else {
                panel.nameFieldStringValue = url.lastPathComponent
            }
        } else {
            panel.nameFieldStringValue = document.language == .markdown ? "Untitled.md" : "Untitled.txt"
        }
        return panel.runModal() == .OK ? panel.url?.standardizedFileURL.resolvingSymlinksInPath() : nil
    }

    private func showError(_ error: Error) { NSApp.presentError(error) }

    private func approveClosing(_ document: EditorDocument) -> Bool {
        guard document.isDirty else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Save changes to “\(document.title)”?"
        alert.informativeText = "Save your changes before closing this document."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let discard = alert.addButton(withTitle: "Discard")
        discard.hasDestructiveAction = true
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save(document)
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    func approveClosingWindow() -> Bool {
        for document in documents.tabs where document.isDirty {
            select(document)
            if !approveClosing(document) { return false }
        }
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { approveClosingWindow() }
    func windowWillClose(_ notification: Notification) { application.removeWindow(self) }
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { documents.active?.history }
}
