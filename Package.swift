// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JApp",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "JAppKit", targets: ["JAppKit"]),
        .executable(name: "JAppRuntime", targets: ["JAppRuntime"]),
        .executable(name: "japp", targets: ["japp"]),
    ],
    targets: [
        // Platform-neutral core: ZIP archive, manifest, packaging, storage, source workspaces.
        // Depends only on Foundation + Compression so it can be unit tested headlessly.
        .target(name: "JAppKit"),
        // The macOS runtime application (AppKit + WebKit). Assembled into
        // "JApp Runtime.app" by Scripts/build.sh.
        .executableTarget(name: "JAppRuntime", dependencies: ["JAppKit"]),
        // The `japp` command-line tool.
        .executableTarget(name: "japp", dependencies: ["JAppKit"]),
        .testTarget(name: "JAppKitTests", dependencies: ["JAppKit"]),
    ]
)
