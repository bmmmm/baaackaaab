// swift-tools-version:6.0
import PackageDescription

// Acquisition CLI for baaackaaab. Built in the Swift 6 language mode: complete
// strict-concurrency checking is enforced at compile time, so the global mutable
// state shared with the signal handlers and the sync/async bridges is audited
// rather than assumed safe.
let package = Package(
    name: "baaackaaab",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "baaackaaab",
            path: "Sources/baaackaaab",
            // Embed Info.plist into __TEXT,__info_plist so the OS can read the
            // Photos usage description — without it a TCC-protected Photos call
            // terminates the process. Path is relative to the package root,
            // which is the linker's working directory under SwiftPM.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist",
                ])
            ]
        ),
        // Pure-logic unit tests. They exercise the headless-testable surface only
        // (argument parsing, the backup-set model, restore path-safety, secret
        // redaction, the on-disk destination + run-history stores) — never the
        // TTY TUI, live restic, Photos/TCC or launchd, which can only be verified
        // on real hardware. The store tests relocate to a throwaway directory via
        // BAAACKAAAB_SUPPORT_DIR, so they never touch the real credential store.
        .testTarget(
            name: "baaackaaabTests",
            dependencies: ["baaackaaab"],
            path: "Tests/baaackaaabTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
