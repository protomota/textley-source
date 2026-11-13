# Textley product requirements

**Implementation scope · November 10, 2026 · textley.ai**

Textley is a native Mac app for opening, editing, and cleaning up plain text. It should feel quick whether you’re fixing a config file, switching between source files, or checking how a Markdown draft will render. Open files appear as tabs in a left sidebar, and the editor is ready as soon as a file opens.

## What ships in 1.0

| Area | Requirement |
| --- | --- |
| Open and save | Create an untitled document, open from Finder or the File menu, reopen recent files, save in place, and save a copy. Support plain text with or without a filename extension, including common source, config, Markdown, and log files. Use standard macOS dialogs and protect unsaved changes on close. |
| Left sidebar and tabs | List open documents as vertical tabs in the left sidebar. Mark the active tab and show which documents have unsaved changes. Switch or close tabs with the mouse or keyboard. Each document keeps its own edits, undo history, selection, and scroll position as you switch. Show one active document per window. Move a tab to a separate native window to keep two different files visible side by side. Allow the sidebar to be hidden. |
| Folder vaults | Open several existing folders as independent roots in the sidebar. Browse nested folders and open text, Markdown, and image files into the same tab list. Watch the roots and update the tree when files appear, move, or disappear. Refresh open images and clean text tabs after external changes. Preserve unsaved edits and apply the save conflict check. Remember the selected roots on relaunch. Removing a root from Textley leaves its files on disk. |
| Image viewing | Open common local images in read-only tabs and fit them to the available space. Show image dimensions. |
| Edit and navigate | Use standard Mac selection, clipboard, and undo/redo behavior. Provide a monospaced editor, optional line numbers and soft wrap, a line/column indicator, and Go to Line. Line numbers refer to actual file lines even when text wraps. |
| Syntax coloring | Detect the language from the filename and allow a manual override, including Plain Text. Start with Swift, JavaScript, TypeScript, JSON, HTML, CSS, and Markdown. Use built-in colors for light and dark appearance. Keep coloring in the editor display so opening or saving a file preserves its text. |
| Markdown preview | Switch between editable Markdown and a rendered Preview using tabs in the toolbar or ⌥⌘P. Both views use the full document area. Render headings, emphasis, lists, links, tables, block quotes, fenced code blocks, and local images relative to the saved document. Preview reflects unsaved changes, works offline, and keeps remote images from loading automatically. Remember the selected view per open document. |
| Find and replace | `⌘F` opens a find bar for the active document. Provide next/previous, match count, case sensitivity, whole-word matching for literal search, wraparound, and a regex toggle. Replace one or all in the active document, with capture groups in regex mode. An invalid pattern changes nothing. One Undo reverses Replace All. |
| Clean up text | Provide commands to trim trailing spaces and tabs, change case (upper/lower), and sort lines ascending. Use the selection when present and the whole document otherwise. Line-based commands act on the lines touched by the selection. Each command is reversible with one Undo. |
| File fidelity | New files default to UTF-8 with LF. Preserve supported existing encoding, byte-order mark, line endings, and final newline unless the user edits or converts them. Support UTF-8 with or without BOM, BOM-marked UTF-16, LF, and CRLF. Show encoding and line endings. If a format is unsupported or mixed line endings cannot be preserved, explain why and keep the original intact. |
| Backup and restore | Documents remain ordinary files wherever the user saves them. Offer a versioned JSON export and import for Textley settings such as font size, wrap, and line numbers. Validate settings before applying them. Open and Save a Copy handle document import and export. |
| MCP | Follow Jotley’s local integration. Settings → Integrations provides opt-in access, read-only or read-and-write modes, a connection check, and setup for Claude Code, Codex, and Claude chat. Agents can discover opened vaults and tabs, read and find files, edit and save with revision checks, and control editor actions, syntax, preview, and settings. The app owner chooses vault roots, and permission controls stay in the app. |

Use standard Mac menus and keyboard shortcuts, follow the system’s light or dark appearance, and support VoiceOver and input methods. Keep preferences in one small settings pane. The app works offline without an account.

## What waits

A folder search interface, cross-file replacement, backlinks, graph view, and vault synchronization are out of scope for 1.0. Diff, custom themes, language servers, plugins, Git, FTP, scripting, Text Factories, and built-in AI also wait.

## Release checks

- From Finder, open a file, jump to a line, edit, undo, save, and reopen. Only the intended text changes. Cover emoji and composed characters, UTF-8 with BOM, UTF-16 with BOM, LF, CRLF, and files without a final newline.
- Open three files in the sidebar. Switch among them with the keyboard and verify each retains its own edits, selection, scroll position, and undo history. Move one tab to a separate window and verify both files remain independently editable. Check Save, Discard, and Cancel when closing a dirty tab.
- Add two folder roots. Add, rename, and remove a nested file externally, then verify the sidebar updates. Open a text file and an image from each root. Change an open file externally and verify a clean tab reloads while an edited tab keeps its work. Relaunch to verify both roots are restored.
- Open a fixture for each supported syntax, confirm automatic detection and manual override, and check that toggling coloring leaves the underlying text and undo history intact. Edit a Markdown file, switch to Preview, and verify the result renders offline before saving. Switch to another file and back to confirm Textley remembers the view. Returning to Markdown restores the editor’s selection, scroll position, and undo history. Saving writes the Markdown source.
- Replace text using a regex capture group in one document. Check the replacement count, undo the change in one step, and verify a second open document was untouched. Check that invalid regex and empty searches never change the file.
- If another app changes the same file on disk while Textley has unsaved edits, prompt the user before overwriting the external change. Failed writes and unsupported encodings leave the original intact.
- Keep ordinary editing responsive. On a baseline Apple silicon Mac, target an editable 10 MB text fixture within two seconds; check scrolling, typing, and a long single-line fixture separately. This is a proposed release target, to be measured during the prototype.
- Restore a settings export in a clean profile. Use only the keyboard to open, edit, find, and save; check VoiceOver labels and marked-text input in the editor.

## Implementation direction

Use Swift and SwiftUI for the app UI, AppKit’s `NSTextView` for editing, and native macOS document APIs for file ownership and coordinated saves. Each open file has its own document state, including when it moves between windows. Prototype file fidelity, external edit conflicts, and editing responsiveness with syntax coloring and preview enabled. The proposed target is Apple silicon on macOS 14 or newer. Confirm the OS floor and Intel support during prototyping. [Apple’s text view documentation](https://developer.apple.com/documentation/appkit/nstextview) · [Apple’s document APIs](https://developer.apple.com/documentation/appkit/documents-data-and-pasteboard)

Verify MCP is off on a clean install. Connect local clients, list tools, read an opened vault, edit and save with a current revision, and verify that stale revisions, out-of-vault paths, and read-only writes fail. Test turning access off and rotating its token.

## Website and distribution

Publish the product site at [textley.ai](https://textley.ai) using the Jotley site as the reference and a screenshot of the running app. Include download, support, privacy, and client setup. Put the Claude Code launcher in the shared Protomota MCP repository and submit it for Claude review.

## BBEdit reference

REA 6.3.0 decoded 64 shipped Interface Builder archives from the installed BBEdit 16.1 (build `451000026`), including interfaces for Grep patterns, text transformations, editor defaults, and text encodings. The bundled scripting dictionary, defaults, and Grep help document the search options, text commands, and display controls used as references for Textley. The study covered shipped resources. REA evidence ID `ev_856aecae43f4a0b98223d5bbab05acce7925aa0dfff2e9a03788e30d3123d445`. [Bare Bones’ feature tour](https://www.barebones.com/products/bbedit/benefitsexercise.html)
