import AppKit
import Observation
import TextleyCore

@MainActor @Observable
final class EditorDocument: NSObject, Identifiable, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
    let id = UUID()
    private(set) var url: URL?
    private(set) var format: TextFileFormat
    private(set) var isDirty = false
    private(set) var change = 0
    private(set) var selection = NSRange(location: 0, length: 0)
    private(set) var caret = "Ln 1, Col 1"
    private(set) var image: NSImage?
    private(set) var imageSize = CGSize.zero
    private(set) var isImage = false
    var languageOverride: SyntaxLanguage? {
        didSet { queueColoring(clear: true) }
    }
    var showsPreview = false
    var showsFind = false
    var focusFind = 0
    var search = SearchQuery()
    var replacement = ""
    var findMessage = ""

    @ObservationIgnored let history = UndoManager()
    @ObservationIgnored let editor: NSTextView
    @ObservationIgnored let scroll: NSScrollView
    @ObservationIgnored private var lines: LineIndex
    @ObservationIgnored private var savedText: String
    @ObservationIgnored private var savedFormat: TextFileFormat
    @ObservationIgnored private var savedData: Data?
    @ObservationIgnored private var colorTask: Task<Void, Never>?
    @ObservationIgnored private var findTask: Task<Void, Never>?
    @ObservationIgnored private var matches: [NSTextCheckingResult] = []
    @ObservationIgnored private var matchIndex: Int?
    @ObservationIgnored private var emptyMatch: (query: SearchQuery, version: Int, range: NSRange)?
    @ObservationIgnored private var lastFindSelection: NSRange?
    @ObservationIgnored private var appliedPreferences: EditorPreferences?

    var title: String { url?.lastPathComponent ?? "Untitled" }
    var language: SyntaxLanguage { languageOverride ?? SyntaxLanguage.detect(url) }
    var isShowingMarkdownPreview: Bool { showsPreview && language == .markdown }
    var text: String { editor.string }

    init(url: URL? = nil, data: Data? = nil) throws {
        let decoded = try data.map(TextFileFormat.decode)
        self.url = url
        let initialFormat = decoded?.format ?? TextFileFormat()
        format = initialFormat
        savedFormat = initialFormat
        savedData = data
        let content = decoded?.text ?? ""
        savedText = content
        lines = LineIndex(content)
        let scrollView = NSTextView.scrollablePlainDocumentContentTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            throw CocoaError(.fileReadUnknown)
        }
        self.scroll = scrollView
        editor = textView
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.string = content
        super.init()
        configureEditor()
        queueColoring()
    }

    convenience init(imageURL: URL) throws {
        try self.init(url: imageURL)
        isImage = true
        refreshImage()
        guard image != nil else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Textley couldn’t open this image."])
        }
    }

    private func refreshImage() {
        image = url.flatMap { NSImage(contentsOf: $0) }
        if let representation = image?.representations.first {
            imageSize = CGSize(width: representation.pixelsWide, height: representation.pixelsHigh)
        } else {
            imageSize = image?.size ?? .zero
        }
    }

    func refreshFromFolder() {
        guard let url, !isDirty else { return }
        if isImage {
            refreshImage()
            return
        }
        let version = change
        let previous = savedData
        Task { [weak self] in
            let update = await Task.detached(priority: .utility) {
                guard let data = try? TextFileAccess.read(url), data != previous,
                      let decoded = try? TextFileFormat.decode(data) else { return nil as (Data, String, TextFileFormat)? }
                return (data, decoded.text, decoded.format)
            }.value
            guard let self, self.change == version, self.url == url, self.savedData == previous, !self.isDirty else { return }
            if let (data, content, format) = update {
                let selection = self.editor.selectedRange()
                self.editor.string = content
                self.history.removeAllActions()
                self.format = format
                self.savedFormat = format
                self.savedText = content
                self.savedData = data
                let length = content.utf16.count
                let start = min(length, selection.location)
                self.editor.setSelectedRange(NSRange(location: start, length: min(selection.length, length - start)))
                self.change += 1
                self.updateCaret()
                self.queueColoring()
                if self.showsFind { self.scheduleFindCount() }
            } else if self.isShowingMarkdownPreview {
                // Linked images can change even when the Markdown source is identical.
                self.previewRevision += 1
            }
        }
    }

    private(set) var previewRevision = 0

    private func configureEditor() {
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.textColor = .textColor
        editor.backgroundColor = .textBackgroundColor
        editor.textContainerInset = NSSize(width: 10, height: 9)
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: 10_000_000, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.setAccessibilityLabel("Document text")
        editor.delegate = self
        editor.textStorage?.delegate = self
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.verticalRulerView = LineNumberRuler(scrollView: scroll, document: self)
    }

    func apply(_ preferences: EditorPreferences) {
        guard appliedPreferences != preferences else { return }
        let previous = appliedPreferences
        appliedPreferences = preferences
        if previous?.fontSize != preferences.fontSize {
            editor.font = .monospacedSystemFont(ofSize: preferences.fontSize, weight: .regular)
        }
        if previous?.wrap != preferences.wrap {
            scroll.hasHorizontalScroller = !preferences.wrap
            editor.isHorizontallyResizable = !preferences.wrap
            editor.autoresizingMask = [.width]
            editor.textContainer?.widthTracksTextView = preferences.wrap
            editor.textContainer?.containerSize = NSSize(
                width: preferences.wrap ? max(1, scroll.contentSize.width) : 10_000_000,
                height: CGFloat.greatestFiniteMagnitude
            )
            if preferences.wrap {
                editor.setFrameSize(NSSize(width: max(1, scroll.contentSize.width), height: editor.frame.height))
                scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY))
            }
        }
        scroll.hasVerticalRuler = preferences.lineNumbers
        scroll.rulersVisible = preferences.lineNumbers
        scroll.verticalRulerView?.needsDisplay = true
    }

    func undoManager(for view: NSTextView) -> UndoManager? { history }

    func textView(_ view: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                  replacementString: String?) -> Bool {
        guard let replacementString, replacementString.utf8.contains(13) else { return true }
        view.insertText(TextFileFormat.normalizeLineEndings(replacementString), replacementRange: affectedCharRange)
        return false
    }

    func textStorage(
        _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange, changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        lines.update(in: textStorage.string as NSString, editedRange: editedRange, changeInLength: delta)
        scroll.verticalRulerView?.needsDisplay = true
    }

    func textDidChange(_ notification: Notification) {
        change += 1
        refreshDirty()
        updateCaret()
        queueColoring()
        if showsFind { scheduleFindCount() }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        selection = editor.selectedRange()
        updateCaret()
    }

    func save(to destination: URL, copy: Bool = false, force: Bool = false, exclusive: Bool = false) throws {
        let currentText = text
        let sameFile = url == destination
        let encoded: Data
        if format == savedFormat, currentText.utf8.elementsEqual(savedText.utf8), let savedData {
            encoded = savedData
        } else {
            encoded = try format.encode(currentText)
        }
        try TextFileAccess.write(encoded, to: destination, replacing: sameFile ? savedData : nil, force: force, exclusive: exclusive)
        if !copy {
            let previousLanguage = language
            url = destination
            savedData = encoded
            savedText = currentText
            savedFormat = format
            isDirty = false
            if previousLanguage != language { queueColoring(clear: true) }
        }
    }

    func changeFormat(_ value: TextFileFormat) {
        guard value != format else { return }
        let previous = format
        history.registerUndo(withTarget: self) { $0.changeFormat(previous) }
        history.setActionName("Change File Format")
        format = value
        refreshDirty()
    }

    private func refreshDirty() {
        let current = text
        isDirty = format != savedFormat || current.utf8.count != savedText.utf8.count
            || !current.utf8.elementsEqual(savedText.utf8)
    }

    func lineNumber(at offset: Int) -> Int { lines.line(at: offset) }

    func goToLine(_ number: Int) -> Bool {
        guard (1...lines.starts.count).contains(number) else { return false }
        if isShowingMarkdownPreview { showsPreview = false }
        select(NSRange(location: lines.starts[number - 1], length: 0))
        focusEditor()
        return true
    }

    func focusEditor() { editor.window?.makeFirstResponder(editor) }

    private func updateCaret() {
        let offset = min(editor.selectedRange().location, (text as NSString).length)
        let line = lines.line(at: offset)
        let start = lines.starts[line - 1]
        let prefix = (text as NSString).substring(with: NSRange(location: start, length: offset - start))
        caret = "Ln \(line), Col \(prefix.count + 1)"
    }

    func apply(_ operation: Cleanup) {
        let edit = operation.edit(in: text, selection: editor.selectedRange())
        replace(range: edit.range, with: edit.replacement, action: operation.rawValue)
    }

    func applyExternalEdit(range: NSRange, replacement: String) {
        replace(range: range, with: replacement, action: "Edit with MCP")
    }

    private func replace(range: NSRange, with value: String, action: String) {
        let replacement = TextFileFormat.normalizeLineEndings(value)
        guard let storage = editor.textStorage,
              !storage.attributedSubstring(from: range).string.utf8.elementsEqual(replacement.utf8) else { return }
        editor.breakUndoCoalescing()
        if editor.shouldChangeText(in: range, replacementString: replacement) {
            storage.replaceCharacters(in: range, with: replacement)
            editor.didChangeText()
            editor.breakUndoCoalescing()
            history.setActionName(action)
            select(NSRange(location: range.location, length: replacement.utf16.count))
        }
    }

    private func select(_ range: NSRange) {
        editor.setSelectedRange(range)
        editor.scrollRangeToVisible(range)
    }

    func openFind() {
        if isShowingMarkdownPreview { showsPreview = false }
        showsFind = true
        focusFind += 1
        scheduleFindCount()
    }

    func closeFind() {
        findTask?.cancel()
        showsFind = false
        focusEditor()
    }

    func scheduleFindCount() {
        findTask?.cancel()
        matchIndex = nil
        lastFindSelection = nil
        emptyMatch = nil
        let input = text
        let query = search
        let version = change
        guard !query.pattern.isEmpty else {
            matches = []
            findMessage = ""
            return
        }
        findTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(125))
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) {
                Result { try query.count(in: input) }
            }.value
            guard !Task.isCancelled, let self, self.change == version, self.search == query else { return }
            switch result {
            case .success(let count): self.showMatchCount(count)
            case .failure: self.findMessage = "Invalid regular expression"
            }
        }
    }

    private func showMatchCount(_ count: Int) {
        findMessage = count == 0 ? "No matches" : "\(count) " + (count == 1 ? "match" : "matches")
    }

    private func showMatches(_ result: Result<[NSTextCheckingResult], Error>) {
        switch result {
        case .success(let results):
            matches = results
            showMatchCount(results.count)
        case .failure:
            matches = []
            findMessage = "Invalid regular expression"
        }
    }

    private func find(backward: Bool) -> NSTextCheckingResult? {
        findTask?.cancel()
        showMatches(Result { try search.matches(in: text) })
        guard !matches.isEmpty else { return nil }
        let range = editor.selectedRange()
        let index: Int?
        if let previous = matchIndex, lastFindSelection == range, matches.indices.contains(previous) {
            let next = previous + (backward ? -1 : 1)
            index = matches.indices.contains(next) ? next : nil
        } else if backward {
            index = matches.lastIndex { NSMaxRange($0.range) <= range.location }
        } else {
            index = matches.firstIndex { $0.range.location >= NSMaxRange(range) }
        }
        guard let resolved = index ?? (search.wraps ? (backward ? matches.count - 1 : 0) : nil) else {
            findMessage = backward ? "No earlier match" : "No later match"
            return nil
        }
        let match = matches[resolved]
        matchIndex = resolved
        lastFindSelection = match.range
        emptyMatch = match.range.length == 0 ? (search, change, match.range) : nil
        select(match.range)
        findMessage = "\(resolved + 1) of \(matches.count)"
        return match
    }

    func findNext(backward: Bool = false) {
        if isShowingMarkdownPreview { showsPreview = false }
        _ = find(backward: backward)
    }

    func replaceOne() {
        let query = search
        do {
            let range = editor.selectedRange()
            let results = try query.matches(in: text)
            let isCurrentEmptyMatch = emptyMatch.map { $0.query == query && $0.version == change && $0.range == range } == true
            let current = range.length > 0 || isCurrentEmptyMatch ? results.first(where: { $0.range == range }) : nil
            guard let match = current ?? find(backward: false) else { return }
            let value = try query.replacementText(replacement, for: match, in: text)
            replace(range: match.range, with: value, action: "Replace")
            _ = find(backward: false)
        } catch { findMessage = "Invalid regular expression" }
    }

    func replaceAll() {
        do {
            let result = try search.replacingAll(in: text, with: replacement)
            if result.count > 0 {
                replace(range: NSRange(location: 0, length: text.utf16.count), with: result.text, action: "Replace All")
            }
            findTask?.cancel()
            findMessage = result.count == 1 ? "1 replaced" : "\(result.count) replaced"
        } catch { findMessage = "Invalid regular expression" }
    }

    private func queueColoring(clear: Bool = false) {
        colorTask?.cancel()
        let language = self.language
        if clear || language == .plain { applyColors([]) }
        guard language != .plain else { return }
        let input = text
        let version = change
        colorTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            let tokens = await Task.detached(priority: .utility) { language.tokens(in: input) }.value
            guard !Task.isCancelled, let self, self.change == version, self.language == language else { return }
            self.applyColors(tokens)
        }
    }

    private func applyColors(_ tokens: [SyntaxLanguage.Token]) {
        guard let layout = editor.layoutManager, let storage = editor.textStorage else { return }
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: storage.length))
        for token in tokens {
            layout.addTemporaryAttribute(.foregroundColor, value: token.kind.color, forCharacterRange: token.range)
        }
    }
}

private extension SyntaxLanguage.TokenKind {
    var color: NSColor {
        switch self {
        case .comment: return .secondaryLabelColor
        case .quoted: return .systemRed
        case .keyword: return .systemPurple
        case .number: return .systemBlue
        case .heading: return .systemBlue
        case .property: return .systemTeal
        }
    }
}
