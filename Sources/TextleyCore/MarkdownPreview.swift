import Foundation
import UniformTypeIdentifiers

public enum MarkdownPreview {
    public static func html(for source: String, fileURL: URL?) -> String {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        guard let markdown = try? AttributedString(markdown: source, options: options) else {
            return page("<pre>" + escape(source) + "</pre>")
        }

        var output = ""
        var stack: [PresentationIntent.IntentType] = []
        for run in markdown.runs {
            let chain = Array((run.presentationIntent?.components ?? []).reversed())
            let shared = zip(stack, chain).prefix { $0.identity == $1.identity }.count
            for component in stack.dropFirst(shared).reversed() { output += closingTag(component.kind) }
            for component in chain.dropFirst(shared) { output += openingTag(component.kind) }
            stack = chain

            if chain.last?.kind == .thematicBreak { continue }
            let raw = String(markdown[run.range].characters)
            var inline = escape(raw)
            let style = run.inlinePresentationIntent ?? []
            if let imageURL = run.imageURL {
                let alt = escape(run.alternateDescription ?? raw)
                if let dataURL = localImage(imageURL, fileURL: fileURL) {
                    inline = "<img alt=\"" + alt + "\" src=\"" + dataURL + "\">"
                } else {
                    inline = "<span class=\"image-alt\">" + (alt.isEmpty ? "Image" : alt) + "</span>"
                }
            } else if style.contains(.lineBreak) {
                inline = "<br>"
            } else if style.contains(.softBreak) {
                inline = "\n"
            }
            if style.contains(.code) { inline = "<code>" + inline + "</code>" }
            if style.contains(.emphasized) { inline = "<em>" + inline + "</em>" }
            if style.contains(.stronglyEmphasized) { inline = "<strong>" + inline + "</strong>" }
            if style.contains(.strikethrough) { inline = "<del>" + inline + "</del>" }
            if let url = run.link, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                inline = "<a href=\"" + escape(url.absoluteString) + "\">" + inline + "</a>"
            } else if let url = run.link, url.absoluteString.hasPrefix("#") {
                inline = "<a href=\"" + escape(url.absoluteString) + "\">" + inline + "</a>"
            }
            output += inline
        }
        for component in stack.reversed() { output += closingTag(component.kind) }
        return page(output)
    }

    private static func openingTag(_ kind: PresentationIntent.Kind) -> String {
        switch kind {
        case .paragraph: return "<p>"
        case .header(let level): return "<h\(level)>"
        case .orderedList: return "<ol>"
        case .unorderedList: return "<ul>"
        case .listItem(let ordinal): return "<li value=\"\(ordinal)\">"
        case .codeBlock: return "<pre><code>"
        case .blockQuote: return "<blockquote>"
        case .thematicBreak: return "<hr>"
        case .table: return "<table>"
        case .tableHeaderRow, .tableRow: return "<tr>"
        case .tableCell: return "<td>"
        @unknown default: return ""
        }
    }

    private static func closingTag(_ kind: PresentationIntent.Kind) -> String {
        switch kind {
        case .paragraph: return "</p>"
        case .header(let level): return "</h\(level)>"
        case .orderedList: return "</ol>"
        case .unorderedList: return "</ul>"
        case .listItem: return "</li>"
        case .codeBlock: return "</code></pre>"
        case .blockQuote: return "</blockquote>"
        case .thematicBreak: return ""
        case .table: return "</table>"
        case .tableHeaderRow, .tableRow: return "</tr>"
        case .tableCell: return "</td>"
        @unknown default: return ""
        }
    }

    private static func localImage(_ reference: URL, fileURL: URL?) -> String? {
        guard let directory = fileURL?.deletingLastPathComponent(), reference.scheme == nil,
              !reference.relativePath.hasPrefix("/"), reference.host == nil else { return nil }
        let url = directory.appendingPathComponent(reference.relativePath).standardizedFileURL
        guard let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType,
              ["image/png", "image/jpeg", "image/gif", "image/webp", "image/avif"].contains(mime),
              let metadata = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              metadata.isRegularFile == true, let bytes = metadata.fileSize, bytes <= 10_000_000,
              let data = try? Data(contentsOf: url), data.count <= 10_000_000 else { return nil }
        return "data:" + mime + ";base64," + data.base64EncodedString()
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func page(_ body: String) -> String {
        """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
        <style>
        :root { color-scheme: light dark; }
        body { font: 15px/1.6 -apple-system, sans-serif; margin: 24px auto; padding: 0 24px; max-width: 50rem; overflow-wrap: anywhere; }
        h1, h2, h3, h4, h5, h6 { line-height: 1.25; }
        p, blockquote, pre, table { margin-block: 0 1em; }
        code { font-family: ui-monospace, monospace; font-size: .9em; }
        pre { overflow: auto; background: color-mix(in srgb, CanvasText 7%, Canvas); padding: 12px; border-radius: 5px; }
        blockquote { padding-inline-start: 12px; border-inline-start: 3px solid GrayText; margin-inline-start: 0; }
        table { border-collapse: collapse; }
        td { border: 1px solid GrayText; padding: 4px 8px; }
        tr:first-child { font-weight: 600; }
        img { max-width: 100%; height: auto; }
        .image-alt { color: GrayText; font-style: italic; }
        </style></head><body>\(body)</body></html>
        """
    }
}
