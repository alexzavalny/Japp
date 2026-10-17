import Foundation

// post-notification <name> <object>: posts a distributed notification (used to
// press the Edit Source window's buttons through the runtime's automation hook).
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name(CommandLine.arguments[1]), object: CommandLine.arguments[2], userInfo: nil, deliverImmediately: true)
RunLoop.current.run(until: Date().addingTimeInterval(0.3))
