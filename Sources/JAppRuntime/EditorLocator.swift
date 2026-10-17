import AppKit

/// Finds code editors installed on this Mac and opens a source folder in one.
struct Editor: Equatable {
    let name: String
    /// nil means "Finder" (just show the folder).
    let bundleID: String?
    let appURL: URL?

    static let finder = Editor(name: "Finder", bundleID: nil, appURL: nil)
}

@MainActor
enum EditorLocator {
    /// In order of preference when the user has not picked one.
    private static let known: [(name: String, bundleID: String)] = [
        ("Visual Studio Code", "com.microsoft.VSCode"),
        ("Cursor", "com.todesktop.230313mzl4w4u92"),
        ("Zed", "dev.zed.Zed"),
        ("Zed Preview", "dev.zed.Zed-Preview"),
        ("Windsurf", "com.exafunction.windsurf"),
        ("Sublime Text", "com.sublimetext.4"),
        ("Nova", "com.panic.Nova"),
        ("BBEdit", "com.barebones.bbedit"),
        ("WebStorm", "com.jetbrains.WebStorm"),
        ("Xcode", "com.apple.dt.Xcode"),
    ]

    static func installedEditors() -> [Editor] {
        let editors = known.compactMap { entry -> Editor? in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundleID) else { return nil }
            return Editor(name: entry.name, bundleID: entry.bundleID, appURL: url)
        }
        return editors + [.finder]
    }

    static func preferredEditor(in editors: [Editor]) -> Editor {
        if let id = RuntimeSettings.editorBundleID {
            if id == "finder" { return .finder }
            if let match = editors.first(where: { $0.bundleID == id }) { return match }
        }
        return editors.first ?? .finder
    }

    static func open(_ folder: URL, with editor: Editor) {
        guard let appURL = editor.appURL else {
            NSWorkspace.shared.open(folder)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([folder], withApplicationAt: appURL, configuration: configuration) { _, error in
            guard error != nil else { return }
            Task { @MainActor in NSWorkspace.shared.open(folder) }
        }
    }
}
