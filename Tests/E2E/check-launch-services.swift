import AppKit

// check-launch-services <file.japp>: prints the file's type and the app macOS opens it with.
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let type = try url.resourceValues(forKeys: [.contentTypeKey]).contentType
print("type=\(type?.identifier ?? "none")")
print("app=\(NSWorkspace.shared.urlForApplication(toOpen: url)?.path ?? "none")")
