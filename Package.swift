// swift-tools-version:5.9
import Foundation
import PackageDescription

// Python 3.14 for iOS (device + simulator) and macOS, from BeeWare's Python-Apple-support,
// repackaged by scripts/build-python-xcframework.sh. Working on this package with that script
// run, the local copy is used; everyone else gets the release download.
let pythonVersion = "python-3.14-b14"
let localPython = FileManager.default.fileExists(
    atPath: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Frameworks/Python.xcframework/Info.plist").path)
let python: Target = localPython
    ? .binaryTarget(name: "Python", path: "Frameworks/Python.xcframework")
    : .binaryTarget(
        name: "Python",
        url: "https://github.com/devileya/ytdlp-apple/releases/download/\(pythonVersion)/Python.xcframework.zip",
        checksum: "d704854ae1b7ce0434df451b02643347e54b736fea53f768ec3879adbb7c7fa7")

let package = Package(
    name: "ytdlp-apple",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "YTDLP", targets: ["YTDLP"]),
        // A `yt-dlp`-compatible command for macOS apps to bundle (no Homebrew needed).
        .executable(name: "ytdlp-apple", targets: ["ytdlp-apple-cli"]),
    ],
    targets: [
        python,
        .target(name: "YTDLPCore", dependencies: ["Python"]),
        .target(
            name: "YTDLP",
            dependencies: ["YTDLPCore"],
            resources: [.copy("Resources/python-packages")],
            linkerSettings: [.linkedFramework("JavaScriptCore")]
        ),
        .executableTarget(name: "ytdlp-apple-cli", dependencies: ["YTDLP"]),
        .testTarget(name: "YTDLPTests", dependencies: ["YTDLP"]),
    ]
)
