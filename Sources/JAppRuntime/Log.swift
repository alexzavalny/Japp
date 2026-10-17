import os

/// Unified-log channel for runtime lifecycle events:
///
///     log stream --predicate 'subsystem == "dev.japp.runtime"'
enum Log {
    static let runtime = Logger(subsystem: "dev.japp.runtime", category: "runtime")
}
