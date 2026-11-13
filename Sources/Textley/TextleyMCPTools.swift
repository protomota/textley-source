import AppKit
import CryptoKit
import Foundation
import MCP
import TextleyCore

enum MCPAccessError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

@MainActor
enum TextleyMCPTools {
    private static let string: Value = ["type": "string"]
    private static let boolean: Value = ["type": "boolean"]
    private static let integer: Value = ["type": "integer", "minimum": 0]
    private static let location = ["vault_id": string, "path": string]
    private static let identity = ["tab_id": string]
    private static let revision = ["expected_revision": string]
    private static let page = ["offset": integer, "limit": integer]
    private static let fields = ["text": string, "old_text": string, "new_text": string]
    private static let search = [
        "query": string, "regex": boolean, "match_case": boolean, "whole_word": boolean,
        "wrap": boolean, "backward": boolean
    ]

    static let tools = [
        tool("list_vaults", "List folders opened in Textley. Use the returned IDs with vault tools."),
        tool("list_files", "List text files, images, and nested directories in one vault.", ["vault_id": string], page, required: ["vault_id"]),
        tool("search_files", "Find files by name or by literal text in one vault. Returns matching paths. Use read_file for content.",
             ["vault_id": string, "query": string, "search_contents": boolean], page, required: ["vault_id", "query"]),
        tool("list_tabs", "List open tabs across Textley windows and identify the active tab."),
        tool("read_file", "Read a text page and its current revision from an open tab or a vault path. Use tab_id or vault_id and path.",
             identity, location, page),
        tool("open_file", "Open a text or image file from a vault in Textley.", location, required: ["vault_id", "path"], writes: true),
        tool("new_document", "Open an untitled text document in Textley.", writes: true),
        tool("select_tab", "Focus an open tab.", identity, required: ["tab_id"], writes: true),
        tool("close_tab", "Close an open tab. Unsaved edits must be saved or reviewed in the app first.", identity, required: ["tab_id"], writes: true),
        tool("move_tab_to_new_window", "Move a tab to a new native window.", identity, required: ["tab_id"], writes: true),
        tool("set_markdown_preview", "Switch a Markdown tab between rendered preview and editable source.", identity, ["enabled": boolean], required: ["tab_id", "enabled"], writes: true),
        tool("set_syntax", "Set a tab’s syntax override. Use Automatic, Plain Text, Swift, JavaScript, TypeScript, JSON, HTML, CSS or Markdown.",
             identity, ["language": string], required: ["tab_id", "language"], writes: true),
        tool("go_to_line", "Select and scroll to a 1-based line in an open text tab.", identity, ["line": integer], required: ["tab_id", "line"], writes: true),
        tool("find_text", "Set the find options and jump to a match in an open tab.", identity, search, required: ["tab_id", "query"], writes: true),
        tool("replace_matches", "Replace one or all matching strings in a tab. Requires a fresh revision. Save separately.",
             identity, search, revision, ["replacement": string, "all": boolean],
             required: ["tab_id", "query", "replacement", "expected_revision"], writes: true, destructive: true),
        tool("edit_text", "Replace the entire tab with text, or replace one exact unique passage using old_text and new_text. Read first. Save separately.",
             identity, revision, fields, required: ["tab_id", "expected_revision"], writes: true, destructive: true),
        tool("clean_up_text", "Apply trim, uppercase, lowercase or sort to the selection or entire tab. Save separately.",
             identity, revision, ["operation": string], required: ["tab_id", "expected_revision", "operation"], writes: true, destructive: true),
        tool("undo_redo", "Undo or redo one edit in a tab. Requires its current revision.",
             identity, revision, ["redo": boolean], required: ["tab_id", "expected_revision"], writes: true, destructive: true),
        tool("set_file_format", "Change encoding or line endings in a tab. Use UTF-8, UTF-8 with BOM, UTF-16 LE or UTF-16 BE and LF or CRLF.",
             identity, revision, ["encoding": string, "line_ending": string], required: ["tab_id", "expected_revision"], writes: true),
        tool("save_file", "Save a named tab in place. For an untitled tab or a copy, choose an unused path inside an open vault.",
             identity, revision, location, required: ["tab_id", "expected_revision"], writes: true, destructive: true),
        tool("create_file", "Create a new UTF-8 text file in an open vault. The parent folder must exist.",
             location, ["text": string], required: ["vault_id", "path", "text"], writes: true),
        tool("create_folder", "Create an empty folder inside an open vault. The parent folder must exist.",
             location, required: ["vault_id", "path"], writes: true),
        tool("rename_file", "Rename or move a closed file inside the same vault. The destination must be unused. Read the current revision first.",
             location, revision, ["new_path": string], required: ["vault_id", "path", "new_path", "expected_revision"], writes: true),
        tool("trash_file", "Move a closed text file to macOS Trash. Call only when requested by the user. Requires its current revision.",
             location, revision, required: ["vault_id", "path", "expected_revision"], writes: true, destructive: true),
        tool("get_editor_settings", "Read the font size, wrap and line-number settings."),
        tool("set_editor_settings", "Update the font size, soft wrap, or line-number settings.",
             ["font_size": integer, "wrap": boolean, "line_numbers": boolean], writes: true),
        tool("set_sidebar", "Show or hide the sidebar in the active Textley window.", ["visible": boolean], required: ["visible"], writes: true)
    ]

    private static func tool(_ name: String, _ description: String, _ parts: [String: Value]...,
                             required: [String] = [], writes: Bool = false, destructive: Bool = false) -> Tool {
        let properties = parts.reduce(into: [String: Value]()) { result, next in
            result.merge(next, uniquingKeysWith: { _, value in value })
        }
        let title = name.split(separator: "_").map { $0 == "markdown" ? "Markdown" : $0.capitalized }.joined(separator: " ")
        return Tool(name: name, description: description, inputSchema: [
            "type": "object", "properties": .object(properties), "required": .array(required.map(Value.string)),
            "additionalProperties": false
        ], annotations: .init(title: title, readOnlyHint: !writes, destructiveHint: destructive,
                              idempotentHint: !writes, openWorldHint: false))
    }

    static func call(_ params: CallTool.Parameters, store: TextleyApplication, allowsWriting: Bool,
                     authorization: @escaping @MainActor () -> Bool) async throws -> CallTool.Result {
        guard let definition = tools.first(where: { $0.name == params.name }) else { throw error("Unknown Textley tool.") }
        let values = Arguments(params.arguments ?? [:])
        let schema = definition.inputSchema.objectValue ?? [:]
        let allowed = Set(schema["properties"]?.objectValue?.keys.map { $0 } ?? [])
        let required = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        guard Set(values.raw.keys).isSubset(of: allowed), required.allSatisfy({ values.raw[$0] != nil }) else {
            throw error("Missing required or unexpected tool argument.")
        }
        if definition.annotations.readOnlyHint == false {
            guard allowsWriting, authorization() else {
                throw error("MCP is read only. Enable Read & write in Textley Settings → Integrations → MCP to allow changes.")
            }
        }
        switch params.name {
        case "list_vaults":
            return try result(["vaults": store.mcpVaults.map { vault in
                ["id": vaultID(vault.url), "name": vault.url.lastPathComponent, "available": vault.isAvailable] as [String: Any]
            }])
        case "list_files", "search_files":
            return try await findFiles(values, store: store, searching: params.name == "search_files")
        case "list_tabs":
            return try result(["tabs": store.mcpTabs.map { controller, document in
                var info = metadata(document)
                info["active"] = store.activeWindow === controller && controller.documents.active === document
                return info
            }])
        case "read_file":
            return try read(values, store: store)
        case "open_file":
            let url = try urlFor(values, store: store)
            return try result(metadata(store.openFileForMCP(url)))
        case "new_document":
            return try result(metadata(store.makeNewTab()))
        case "get_editor_settings":
            return try result(settings(store))
        case "set_editor_settings":
            var preferences = store.preferences.editor
            if let font = try values.optionalInt("font_size", range: 9...32) { preferences.fontSize = Double(font) }
            if let wrap = try values.optionalBool("wrap") { preferences.wrap = wrap }
            if let numbers = try values.optionalBool("line_numbers") { preferences.lineNumbers = numbers }
            store.preferences.editor = try preferences.validated()
            return try result(settings(store))
        case "set_sidebar":
            guard let window = store.activeWindow else { throw error("Open a Textley window first.") }
            window.documents.showsSidebar = try values.bool("visible")
            return try result(["visible": window.documents.showsSidebar])
        case "create_file", "create_folder", "rename_file", "trash_file":
            return try await manageFile(params.name, values, store: store, authorization: authorization)
        default:
            return try controlTab(params.name, values, store: store)
        }
    }

    private static func controlTab(_ name: String, _ args: Arguments, store: TextleyApplication) throws -> CallTool.Result {
        let (controller, document) = try tab(args, store: store)
        switch name {
        case "select_tab":
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            controller.select(document)
            return try result(metadata(document))
        case "close_tab":
            guard !document.isDirty else { throw error("The tab has unsaved edits. Save it or review it in Textley before closing.") }
            controller.closeTab(document)
            return try result(["closed": document.id.uuidString])
        case "move_tab_to_new_window":
            controller.moveToNewWindow(document)
            return try result(metadata(document))
        default: break
        }
        guard !document.isImage else { throw error("This tab is a read-only image.") }
        if args.raw["expected_revision"] != nil { try checkRevision(args, actual: revisionOf(document)) }
        switch name {
        case "set_markdown_preview":
            guard document.language == .markdown else { throw error("Choose Markdown syntax before opening a Markdown preview.") }
            document.showsPreview = try args.bool("enabled")
        case "set_syntax":
            let language = try args.text("language", max: 40)
            if language == "Automatic" { document.languageOverride = nil }
            else if let syntax = SyntaxLanguage(rawValue: language) { document.languageOverride = syntax }
            else { throw error("Unknown syntax. Use a language listed by set_syntax.") }
        case "go_to_line":
            let number = try args.int("line", default: 1, range: 1...Int.max)
            guard document.goToLine(number) else { throw error("That line isn’t in this document.") }
        case "find_text", "replace_matches":
            var query = SearchQuery()
            query.pattern = try args.text("query", max: 4000, allowEmpty: false)
            query.isRegex = try args.bool("regex", default: false)
            query.matchCase = try args.bool("match_case", default: false)
            query.wholeWord = try args.bool("whole_word", default: false)
            query.wraps = try args.bool("wrap", default: true)
            _ = try query.expression()
            document.search = query
            if name == "find_text" {
                document.openFind()
                document.findNext(backward: try args.bool("backward", default: false))
            } else {
                document.replacement = try args.text("replacement", max: 400_000)
                if try args.bool("all", default: false) { document.replaceAll() } else { document.replaceOne() }
            }
        case "edit_text":
            try applyEdit(args, to: document)
        case "clean_up_text":
            let requested = try args.text("operation", max: 15)
            let operations: [String: Cleanup] = ["trim": .trim, "uppercase": .uppercase, "lowercase": .lowercase, "sort": .sort]
            guard let operation = operations[requested] else { throw error("Use trim, uppercase, lowercase or sort.") }
            document.apply(operation)
        case "undo_redo":
            if try args.bool("redo", default: false) {
                if document.history.canRedo { document.history.redo() }
            } else if document.history.canUndo { document.history.undo() }
        case "set_file_format":
            var format = document.format
            if args.raw["encoding"] != nil {
                guard let encoding = TextEncoding(rawValue: try args.text("encoding", max: 25)) else { throw error("Unsupported encoding.") }
                format.encoding = encoding
            }
            if args.raw["line_ending"] != nil {
                guard let ending = LineEnding(rawValue: try args.text("line_ending", max: 6)) else { throw error("Use LF or CRLF.") }
                format.lineEnding = ending
            }
            document.changeFormat(format)
        case "save_file":
            let hasPath = args.raw["path"] != nil || args.raw["vault_id"] != nil
            if hasPath {
                let url = try urlFor(args, store: store, allowNew: true)
                guard store.owner(of: url) == nil else { throw TextFileError.openDestination }
                try document.save(to: url, copy: document.url != nil, exclusive: true)
                store.noteRecent(url)
            } else if let url = document.url {
                try document.save(to: url)
                store.noteRecent(url)
            } else {
                throw error("Choose an unused vault path for the untitled tab.")
            }
            controller.syncWindow()
        default: throw error("Unknown Textley tool.")
        }
        var info = metadata(document)
        info["revision"] = try revisionOf(document)
        info["selection_utf16"] = [document.editor.selectedRange().location, document.editor.selectedRange().length]
        if name == "find_text" || name == "replace_matches" { info["find_status"] = document.findMessage }
        return try result(info)
    }

    private static func applyEdit(_ args: Arguments, to document: EditorDocument) throws {
        let current = document.text
        if args.raw["text"] != nil {
            guard args.raw["old_text"] == nil, args.raw["new_text"] == nil else {
                throw error("Supply text or a single exact passage, not both.")
            }
            document.applyExternalEdit(range: NSRange(location: 0, length: current.utf16.count),
                                       replacement: try args.text("text", max: 400_000))
            return
        }
        let old = try args.text("old_text", max: 400_000, allowEmpty: false)
        let new = try args.text("new_text", max: 400_000)
        let source = current as NSString
        let range = source.range(of: old, options: .literal)
        guard range.location != NSNotFound else { throw error("The exact passage was not found.") }
        let afterStart = range.location + 1
        guard source.range(of: old, options: .literal, range: NSRange(location: afterStart, length: source.length - afterStart)).location == NSNotFound else {
            throw error("The passage occurs more than once. Include more surrounding text.")
        }
        document.applyExternalEdit(range: range, replacement: new)
    }

    private static func read(_ args: Arguments, store: TextleyApplication) throws -> CallTool.Result {
        let document: EditorDocument?
        let url: URL?
        if args.raw["tab_id"] != nil {
            guard args.raw["vault_id"] == nil, args.raw["path"] == nil else { throw error("Supply a tab ID or a vault path.") }
            document = try tab(args, store: store).1
            url = document?.url
        } else {
            url = try urlFor(args, store: store)
            document = url.flatMap { store.owner(of: $0)?.1 }
        }
        if let url, FolderEntry.isImage(url) {
            let data = try TextFileAccess.read(url)
            return try result(["kind": "image", "name": url.lastPathComponent, "bytes": data.count, "revision": digest(data)])
        }
        let text: String
        let format: TextFileFormat
        let revision: String
        if let document {
            text = document.text
            format = document.format
            revision = try revisionOf(document)
        } else if let url {
            let data = try TextFileAccess.read(url)
            let decoded = try TextFileFormat.decode(data)
            text = decoded.text
            format = decoded.format
            revision = digest(data)
        } else { throw error("Choose a file or an open tab.") }

        let offset = try args.int("offset", default: 0, range: 0...Int.max)
        let limit = try args.int("limit", default: 12_000, range: 1...20_000)
        let start = text.index(text.startIndex, offsetBy: offset, limitedBy: text.endIndex) ?? text.endIndex
        let end = text.index(start, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
        var info = document.map(metadata) ?? ["name": url?.lastPathComponent ?? "Untitled"]
        info["kind"] = "text"
        info["text"] = String(text[start..<end])
        info["revision"] = revision
        info["encoding"] = format.encoding.rawValue
        info["line_ending"] = format.lineEnding.rawValue
        info["next_offset"] = end == text.endIndex ? NSNull() : offset + limit as Any
        return try result(info)
    }

    private static func findFiles(_ args: Arguments, store: TextleyApplication, searching: Bool) async throws -> CallTool.Result {
        let vault = try resolveVault(args, store: store)
        let root = vault.url
        let query = searching ? try args.text("query", max: 500, allowEmpty: false) : nil
        let searchContents = try args.bool("search_contents", default: false)
        let offset = try args.int("offset", default: 0, range: 0...Int.max)
        let limit = try args.int("limit", default: 50, range: 1...100)
        let matches = await Task.detached(priority: .utility) {
            var found: [(path: String, kind: String)] = []
            var inspected = 0
            func scan(_ entries: [FolderEntry], prefix: String = "") {
                for entry in entries {
                    let path = prefix + entry.name
                    let kind = entry.isFolder ? "folder" : (entry.isImage ? "image" : "text")
                    var includes = query.map { path.localizedCaseInsensitiveContains($0) } ?? true
                    if !includes, let query, searchContents, kind == "text", inspected < 500,
                       let bytes = entry.size, bytes <= 1_000_000 {
                        inspected += 1
                        if let url = try? VaultPath.resolve(path, in: root),
                           let data = try? TextFileAccess.read(url), let decoded = try? TextFileFormat.decode(data) {
                            includes = decoded.text.localizedCaseInsensitiveContains(query)
                        }
                    }
                    if includes { found.append((path, kind)) }
                    if let children = entry.children { scan(children, prefix: path + "/") }
                }
            }
            scan(FolderEntry.list(root))
            return (found, inspected)
        }.value
        guard store.mcpVaults.contains(where: { $0.url == root }) else { throw error("This vault was closed.") }
        let remaining = matches.0.dropFirst(min(offset, matches.0.count))
        let rows = remaining.prefix(limit).map { ["path": $0.path, "kind": $0.kind] }
        return try result(["entries": rows, "next_offset": remaining.count > limit ? offset + limit as Any : NSNull(),
                           "content_files_examined": matches.1])
    }

    private static func manageFile(_ name: String, _ args: Arguments, store: TextleyApplication,
                                   authorization: @escaping @MainActor () -> Bool) async throws -> CallTool.Result {
        let creating = name == "create_file" || name == "create_folder"
        let url = try urlFor(args, store: store, allowNew: creating)
        if creating {
            if name == "create_folder" {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                return try result(["created": true])
            }
            guard !FolderEntry.isImage(url) else { throw error("create_file writes plain text. Choose a text filename.") }
            let bytes = try TextFileFormat().encode(args.text("text", max: 400_000))
            try TextFileAccess.write(bytes, to: url, exclusive: true)
            return try result(["created": true, "revision": digest(bytes)])
        }

        guard store.owner(of: url) == nil else { throw error("Close the file in Textley before renaming or trashing it.") }
        let data = try TextFileAccess.read(url)
        try checkRevision(args, actual: digest(data))
        if name == "rename_file" {
            let vault = try resolveVault(args, store: store)
            let newPath = try args.text("new_path", max: 4000, allowEmpty: false)
            let destination = try VaultPath.resolve(newPath, in: vault.url, allowNew: true)
            try FileManager.default.moveItem(at: url, to: destination)
            return try result(["path": newPath, "revision": digest(data)])
        }
        _ = try TextFileFormat.decode(data)
        guard authorization() else { throw error("MCP write access was revoked.") }
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        return try result(["trashed": true])
    }

    private static func settings(_ store: TextleyApplication) -> [String: Any] {
        let editor = store.preferences.editor
        return ["font_size": editor.fontSize, "wrap": editor.wrap, "line_numbers": editor.lineNumbers]
    }

    private static func metadata(_ document: EditorDocument) -> [String: Any] {
        ["tab_id": document.id.uuidString, "name": document.title,
         "kind": document.isImage ? "image" : "text", "dirty": document.isDirty,
         "syntax": document.language.rawValue, "markdown_preview": document.isShowingMarkdownPreview,
         "location": document.caret, "saved": document.url != nil]
    }

    private static func tab(_ args: Arguments, store: TextleyApplication) throws -> (EditorWindow, EditorDocument) {
        guard let id = UUID(uuidString: try args.text("tab_id", max: 50)),
              let found = store.mcpTabs.first(where: { $0.1.id == id }) else { throw error("This tab is no longer open.") }
        return found
    }

    private static func resolveVault(_ args: Arguments, store: TextleyApplication) throws -> FolderVault {
        let id = try args.text("vault_id", max: 64)
        guard let vault = store.mcpVaults.first(where: { vaultID($0.url) == id }), vault.isAvailable else {
            throw error("Open the folder in Textley before accessing it.")
        }
        return vault
    }

    private static func urlFor(_ args: Arguments, store: TextleyApplication, allowNew: Bool = false) throws -> URL {
        try VaultPath.resolve(args.text("path", max: 4000, allowEmpty: false),
                              in: resolveVault(args, store: store).url, allowNew: allowNew)
    }

    private static func vaultID(_ url: URL) -> String { digest(Data(url.path.utf8)) }
    private static func revisionOf(_ document: EditorDocument) throws -> String { digest(try document.format.encode(document.text)) }
    private static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

    private static func checkRevision(_ args: Arguments, actual: String) throws {
        guard try args.text("expected_revision", max: 64) == actual else {
            throw error("The revision is stale. Read the current file and review the differences before retrying.")
        }
    }

    private static func result(_ values: [String: Any]) throws -> CallTool.Result {
        let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        return .init(content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)], isError: false)
    }

    private nonisolated static func error(_ text: String) -> MCPAccessError { .message(text) }

    private struct Arguments {
        let raw: [String: Value]
        init(_ raw: [String: Value]) { self.raw = raw }

        func text(_ key: String, max: Int, allowEmpty: Bool = true) throws -> String {
            guard let value = raw[key]?.stringValue, value.utf8.count <= max, allowEmpty || !value.isEmpty else {
                throw error("Invalid " + key + ".")
            }
            return value
        }

        func optionalInt(_ key: String, range: ClosedRange<Int>) throws -> Int? {
            guard let value = raw[key] else { return nil }
            guard let number = value.intValue, range.contains(number) else { throw error("Invalid " + key + ".") }
            return number
        }

        func int(_ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
            try optionalInt(key, range: range) ?? fallback
        }

        func optionalBool(_ key: String) throws -> Bool? {
            guard let value = raw[key] else { return nil }
            guard let flag = value.boolValue else { throw error("Invalid " + key + ".") }
            return flag
        }

        func bool(_ key: String, default fallback: Bool? = nil) throws -> Bool {
            guard let flag = try optionalBool(key) ?? fallback else { throw error("Missing " + key + ".") }
            return flag
        }
    }
}

enum VaultPath {
    static func resolve(_ relative: String, in root: URL, allowNew: Bool = false) throws -> URL {
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, !relative.contains("\\"), !relative.utf8.contains(0),
              components.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }) else {
            throw MCPAccessError.message("Use a visible path relative to an open Textley folder.")
        }
        guard root.resolvingSymlinksInPath().path == root.path else {
            throw MCPAccessError.message("The vault location changed. Reopen it in Textley.")
        }
        var url = root
        for (index, part) in components.enumerated() {
            let final = index == components.count - 1
            url.appendPathComponent(String(part))
            let metadata = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isPackageKey, .isRegularFileKey])
            if metadata?.isSymbolicLink == true || metadata?.isPackage == true {
                throw MCPAccessError.message("Textley MCP does not follow symlinks or enter app packages.")
            }
            if final, allowNew {
                guard metadata == nil, !FileManager.default.fileExists(atPath: url.path) else {
                    throw MCPAccessError.message("That path already exists. Choose an unused filename.")
                }
            } else if final {
                guard metadata?.isRegularFile == true else { throw MCPAccessError.message("This path is not a regular file.") }
            } else {
                guard metadata?.isDirectory == true else { throw MCPAccessError.message("The parent folder does not exist.") }
            }
        }
        return url
    }
}
