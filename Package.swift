// swift-tools-version:5.9
import PackageDescription

// Prototype acquisition CLI for baaackaaab.
// Swift 5 language mode on purpose: keeps the prototype free of Swift 6
// strict-concurrency noise while we validate the two risky API surfaces
// (FileProvider/iCloud Drive and PhotoKit). We tighten this later.
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
        )
    ]
)
