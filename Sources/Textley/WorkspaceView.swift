import AppKit
import SwiftUI
import TextleyCore
import WebKit

struct WorkspaceView: View {
    unowned let controller: EditorWindow

    private var workspace: WindowDocuments { controller.documents }
    private var preferences: Preferences { controller.application.preferences }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HSplitView {
                if workspace.showsSidebar { sidebar.frame(minWidth: 155, idealWidth: 205, maxWidth: 260) }
                if let document = workspace.active {
                    documentView(document)
                        .frame(minWidth: 390, maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label("No File Open", systemImage: "doc")
                    } actions: {
                        Button("New Document") { controller.application.newTab() }
                        Button("Open…") { controller.application.openPanel() }
                    }
                    .frame(minWidth: 390, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onChange(of: workspace.selectedID, initial: true) { _, _ in
            controller.syncWindow()
            controller.focusActive()
        }
        .onChange(of: workspace.active?.isShowingMarkdownPreview) { _, isShowingPreview in
            if isShowingPreview == false, workspace.active?.showsFind == false { controller.focusActive() }
        }
        .onChange(of: workspace.active?.isDirty) { _, _ in controller.syncWindow() }
        .onChange(of: workspace.active?.url) { _, _ in controller.syncWindow() }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            iconButton("Toggle Sidebar", icon: "sidebar.left") { workspace.showsSidebar.toggle() }
            iconButton("New Document", icon: "square.and.pencil") { controller.application.newTab() }
            iconButton("Open Folder", icon: "folder.badge.plus") { controller.application.openFolderPanel() }
            Spacer()
            if let document = workspace.active, document.language == .markdown {
                @Bindable var document = document
                Picker("Markdown View", selection: $document.showsPreview) {
                    Text("Markdown").tag(false)
                    Text("Preview").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .frame(height: 37)
        .background(.bar)
    }

    private var sidebar: some View {
        List {
            Section("Open Files") {
                ForEach(workspace.tabs) { document in
                    TabRow(document: document, isSelected: document.id == workspace.selectedID, controller: controller)
                }
            }
            if !workspace.vaults.isEmpty {
                Section("Folders") {
                    ForEach(workspace.vaults) { vault in
                        @Bindable var vault = vault
                        DisclosureGroup(isExpanded: $vault.isExpanded) {
                            if vault.isAvailable {
                                OutlineGroup(vault.entries, children: \.children) { entry in
                                    if entry.isFolder {
                                        Label(entry.name, systemImage: "folder")
                                    } else {
                                        Button {
                                            controller.application.openFiles([entry.url], in: controller)
                                        } label: {
                                            Label(entry.name, systemImage: entry.isImage ? "photo" : "doc.text")
                                                .lineLimit(1)
                                        }
                                        .buttonStyle(.plain)
                                        .help(entry.url.path)
                                    }
                                }
                            } else {
                                Text("Folder unavailable").foregroundStyle(.secondary)
                            }
                        } label: {
                            Label(vault.url.lastPathComponent, systemImage: "folder")
                                .help(vault.url.path)
                                .contextMenu {
                                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([vault.url]) }
                                    Button("Remove from Sidebar") { controller.removeVault(vault) }
                                }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Open files and folders")
    }

    @ViewBuilder
    private func documentView(_ document: EditorDocument) -> some View {
        if document.isImage {
            ImageTab(document: document)
        } else {
            VStack(spacing: 0) {
                if document.isShowingMarkdownPreview {
                    MarkdownPane(source: document.text, version: document.change, assetVersion: document.previewRevision, fileURL: document.url)
                        .id(document.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    if document.showsFind {
                        FindBar(document: document).id(document.id)
                        Divider()
                    }
                    EditorSurface(document: document, preferences: preferences.editor)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Divider()
                statusBar(document)
            }
        }
    }

    private func statusBar(_ document: EditorDocument) -> some View {
        HStack(spacing: 12) {
            Text(document.caret).font(.caption.monospacedDigit()).accessibilityLabel(document.caret)
            Spacer()
            Menu(document.language.rawValue) {
                Button("Automatic") { document.languageOverride = nil }
                Divider()
                ForEach(SyntaxLanguage.allCases) { language in
                    Button(language.rawValue) { document.languageOverride = language }
                }
            }
            .accessibilityLabel("Syntax")
            Menu(document.format.encoding.rawValue) {
                ForEach(TextEncoding.allCases) { encoding in
                    Button(encoding.rawValue) {
                        document.changeFormat(TextFileFormat(encoding: encoding, lineEnding: document.format.lineEnding))
                    }
                }
            }
            .accessibilityLabel("Encoding")
            Menu(document.format.lineEnding.rawValue) {
                ForEach(LineEnding.allCases) { ending in
                    Button(ending.rawValue) {
                        document.changeFormat(TextFileFormat(encoding: document.format.encoding, lineEnding: ending))
                    }
                }
            }
            .accessibilityLabel("Line endings")
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private func iconButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon) }.accessibilityLabel(title).help(title)
    }
}

private struct TabRow: View {
    let document: EditorDocument
    let isSelected: Bool
    unowned let controller: EditorWindow

    var body: some View {
        HStack(spacing: 5) {
            Button {
                controller.select(document)
            } label: {
                Label(document.title, systemImage: document.isImage ? "photo" : "doc.text")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityValue(document.isDirty ? "Unsaved changes" : "")
            if document.isDirty {
                Circle().fill(.secondary).frame(width: 6, height: 6).accessibilityHidden(true)
            }
            Button {
                controller.closeTab(document)
            } label: {
                Image(systemName: "xmark").font(.caption2.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Close " + document.title)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .help(document.url?.path ?? document.title)
        .contextMenu {
            Button("Move to New Window") { controller.moveToNewWindow(document) }
            Button("Close Tab") { controller.closeTab(document) }
        }
    }
}

private struct FindBar: View {
    @Bindable var document: EditorDocument
    @FocusState private var isFindFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                TextField("Find", text: $document.search.pattern)
                    .focused($isFindFocused)
                    .onSubmit { document.findNext() }
                Text(document.findMessage).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityLabel(document.findMessage)
                Button { document.findNext(backward: true) } label: { Image(systemName: "chevron.up") }
                    .accessibilityLabel("Previous Match")
                Button { document.findNext() } label: { Image(systemName: "chevron.down") }
                    .accessibilityLabel("Next Match")
                Button { document.closeFind() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Close Find")
            }
            HStack {
                TextField("Replace", text: $document.replacement)
                Button("Replace") { document.replaceOne() }.disabled(document.search.pattern.isEmpty)
                Button("Replace All") { document.replaceAll() }.disabled(document.search.pattern.isEmpty)
            }
            HStack {
                Toggle("Match Case", isOn: $document.search.matchCase)
                Toggle("Whole Word", isOn: $document.search.wholeWord).disabled(document.search.isRegex)
                Toggle("Wrap", isOn: $document.search.wraps)
                Toggle("Regex", isOn: $document.search.isRegex)
            }
        }
        .font(.callout)
        .padding(8)
        .background(.bar)
        .onAppear { isFindFocused = true }
        .onChange(of: document.focusFind) { _, _ in isFindFocused = true }
        .onChange(of: document.search) { _, _ in document.scheduleFindCount() }
        .onExitCommand { document.closeFind() }
    }
}

private struct EditorSurface: NSViewRepresentable {
    let document: EditorDocument
    let preferences: EditorPreferences

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ host: NSView, context: Context) {
        let scroll = document.scroll
        if scroll.superview !== host {
            host.subviews.forEach { $0.removeFromSuperview() }
            let point = scroll.contentView.bounds.origin
            scroll.removeFromSuperview()
            scroll.frame = host.bounds
            scroll.autoresizingMask = [.width, .height]
            host.addSubview(scroll)
            document.apply(preferences)
            scroll.tile()
            if document.editor.frame.width < scroll.contentSize.width {
                document.editor.setFrameSize(NSSize(width: scroll.contentSize.width, height: document.editor.frame.height))
            }
            scroll.contentView.scroll(to: point)
            scroll.reflectScrolledClipView(scroll.contentView)
        } else {
            document.apply(preferences)
        }
    }
}

private struct ImageTab: View {
    let document: EditorDocument

    var body: some View {
        VStack(spacing: 0) {
            if let image = document.image {
                GeometryReader { geometry in
                    Image(nsImage: image).resizable().scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .padding(12)
                        .accessibilityLabel(document.title)
                }
                .padding(12)
                Divider()
                Text("\(Int(document.imageSize.width)) × \(Int(document.imageSize.height)) px")
                    .font(.caption.monospacedDigit())
                    .padding(5)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                ContentUnavailableView("Image Unavailable", systemImage: "photo")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MarkdownPane: NSViewRepresentable {
    let source: String
    let version: Int
    let assetVersion: Int
    let fileURL: URL?

    func makeCoordinator() -> Renderer { Renderer() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = context.coordinator
        web.setAccessibilityLabel("Markdown preview")
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.update(web, source: source, version: version, assetVersion: assetVersion, fileURL: fileURL)
    }

    @MainActor
    final class Renderer: NSObject, WKNavigationDelegate {
        private var task: Task<Void, Never>?
        private var latestSource: String?
        private var latestVersion: Int?
        private var latestAssetVersion: Int?
        private var latestURL: URL?

        func update(_ web: WKWebView, source: String, version: Int, assetVersion: Int, fileURL: URL?) {
            guard latestVersion != version || latestAssetVersion != assetVersion || latestURL != fileURL || latestSource != source else { return }
            latestSource = source
            latestVersion = version
            latestAssetVersion = assetVersion
            latestURL = fileURL
            task?.cancel()
            task = Task { [weak web] in
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                let html = await Task.detached(priority: .userInitiated) { MarkdownPreview.html(for: source, fileURL: fileURL) }.value
                guard !Task.isCancelled else { return }
                web?.loadHTMLString(html, baseURL: nil)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url,
               ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(action.request.url?.absoluteString.hasPrefix("about:blank") == true ? .allow : .cancel)
        }
    }
}
