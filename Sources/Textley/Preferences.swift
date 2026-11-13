import AppKit
import Observation
import SwiftUI
import TextleyCore

struct EditorPreferences: Codable, Equatable {
    var fontSize: Double = 13
    var wrap = false
    var lineNumbers = true

    func validated() throws -> Self {
        guard fontSize.isFinite, (9...32).contains(fontSize) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "The editor font size must be between 9 and 32."])
        }
        return self
    }
}

@MainActor @Observable
final class Preferences {
    private struct Backup: Codable {
        let version: Int
        let editor: EditorPreferences
    }

    var editor: EditorPreferences {
        didSet {
            if let data = try? JSONEncoder().encode(editor) { defaults.set(data, forKey: "editorPreferences") }
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "editorPreferences"),
           let saved = try? JSONDecoder().decode(EditorPreferences.self, from: data).validated() {
            editor = saved
        } else {
            editor = EditorPreferences()
        }
    }

    func export(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try TextFileAccess.write(encoder.encode(Backup(version: 1, editor: editor)), to: url)
    }

    func restore(from url: URL) throws {
        let backup = try JSONDecoder().decode(Backup.self, from: TextFileAccess.read(url))
        guard backup.version == 1 else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "This settings backup uses an unsupported version."])
        }
        editor = try backup.editor.validated()
    }
}

struct SettingsView: View {
    static let contentSize = CGSize(width: 716, height: 556)

    enum Page: String, CaseIterable, Identifiable {
        case editor = "Editor"
        case integrations = "Integrations"

        var id: Self { self }

        var symbol: String {
            switch self {
            case .editor: "text.alignleft"
            case .integrations: "point.3.connected.trianglepath.dotted"
            }
        }
    }

    @Bindable var preferences: Preferences
    let mcp: TextleyMCPService
    @State private var selection: Page?

    init(preferences: Preferences, mcp: TextleyMCPService, initialPage: Page = .editor) {
        self.preferences = preferences
        self.mcp = mcp
        _selection = State(initialValue: initialPage)
    }

    var body: some View {
        let page = selection ?? .editor
        HStack(spacing: 0) {
            List(Page.allCases, selection: $selection) { page in
                Label(page.rawValue, systemImage: page.symbol)
                    .tag(page)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .padding(.top, 16)
            .frame(width: 158)
            .background(.bar)
            .accessibilityLabel("Settings sections")

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                Text(page.rawValue)
                    .font(.system(size: 24, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 26)
                    .padding(.top, 24)
                    .padding(.bottom, 8)
                switch page {
                case .editor: editorSettings
                case .integrations: MCPSettingsView(service: mcp)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
    }

    private var editorSettings: some View {
        Form {
            Section("Text display") {
                LabeledContent("Font size") {
                    Stepper(value: $preferences.editor.fontSize, in: 9...32) {
                        Text("\(Int(preferences.editor.fontSize)) pt")
                            .monospacedDigit()
                    }
                    .accessibilityLabel("Font size")
                    .accessibilityValue("\(Int(preferences.editor.fontSize)) points")
                }
                Toggle("Show line numbers", isOn: $preferences.editor.lineNumbers)
                Toggle("Soft wrap", isOn: $preferences.editor.wrap)
            }
            Section("Backup") {
                HStack {
                    Button { exportSettings() } label: {
                        Label("Export Settings…", systemImage: "square.and.arrow.up")
                    }
                    Button { importSettings() } label: {
                        Label("Import Settings…", systemImage: "square.and.arrow.down")
                    }
                }
                .labelStyle(.titleAndIcon)
            }
            #if TEXTLEY_SPARKLE
            Section("Updates") {
                Toggle("Automatically install updates", isOn: Binding(
                    get: { TextleyUpdates.shared.automaticUpdates },
                    set: { TextleyUpdates.shared.setAutomaticUpdates($0) }
                ))
                Button("Check for Updates…") { TextleyUpdates.shared.check() }
                    .disabled(!TextleyUpdates.shared.canCheck)
            }
            #endif
        }
        .formStyle(.grouped)
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Textley Settings.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try preferences.export(to: url) } catch { NSApp.presentError(error) }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert()
        alert.messageText = "Restore Textley settings?"
        alert.informativeText = "This will replace your current editor settings."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try preferences.restore(from: url) } catch { NSApp.presentError(error) }
    }
}
