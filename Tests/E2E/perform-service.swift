import AppKit

// perform-service <service name> <file>: invokes a Services menu item the way Finder does.
let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.japp.e2e"))
pasteboard.clearContents()
pasteboard.writeObjects([URL(fileURLWithPath: CommandLine.arguments[2]) as NSURL])
exit(NSPerformService(CommandLine.arguments[1], pasteboard) ? 0 : 1)
