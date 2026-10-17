// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JApp",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "JAppKit", targets: ["JAppKit"]),
        // All of JApp Runtime's code. It is loaded by the launcher below, which is the
        // main executable of "JApp Runtime.app" and of every per-app bundle.
        .library(name: "JAppRuntimeCore", type: .dynamic, targets: ["JAppRuntimeCore"]),
        .executable(name: "JAppRuntime", targets: ["JAppLauncher"]),
        .executable(name: "japp", targets: ["japp"]),
    ],
    targets: [
        // Platform-neutral core: ZIP archive, manifest, packaging, storage, source workspaces.
        // Depends only on Foundation + Compression so it can be unit tested headlessly.
        .target(name: "JAppKit"),
        // The macOS runtime (AppKit + WebKit). Assembled into "JApp Runtime.app" by Scripts/build.sh.
        .target(name: "JAppRuntimeCore", dependencies: ["JAppKit"], path: "Sources/JAppRuntime"),
        // A few lines of C that find and start JAppRuntimeCore (see main.c).
        .executableTarget(name: "JAppLauncher",
                          linkerSettings: [.linkedFramework("CoreFoundation"), .linkedFramework("CoreServices")]),
        // The `japp` command-line tool.
        .executableTarget(name: "japp", dependencies: ["JAppKit"]),
        .testTarget(name: "JAppKitTests", dependencies: ["JAppKit"]),
    ]
)
