import Foundation

/// `/usr/bin/codesign`, which is part of macOS itself (no Xcode needed).
enum CodeSigning {
    /// Signs `url`. The identity "-" makes an ad-hoc signature; any other value names a
    /// certificate in the keychain (e.g. "Developer ID Application: …") and gets a secure
    /// timestamp, as notarization requires. `hardened` turns on the hardened runtime,
    /// with `entitlements` if given.
    static func sign(_ url: URL, identity: String = "-", hardened: Bool, entitlements: URL? = nil) throws {
        var arguments = ["--force", "--sign", identity, identity == "-" ? "--timestamp=none" : "--timestamp"]
        if hardened { arguments += ["--options", "runtime"] }
        if let entitlements { arguments += ["--entitlements", entitlements.path] }
        try run(arguments + [url.path], failure: "codesign failed")
    }

    /// Checks that the signature of `url`, and of all code nested in it, is intact.
    static func verify(_ url: URL) throws {
        try run(["--verify", "--strict", "--deep", url.path], failure: "The signature of \(url.lastPathComponent) is not valid")
    }

    private static func run(_ arguments: [String], failure: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw JAppError.io("\(failure): \(String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}
