// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TidyDrive",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "TidyDrive", targets: ["TidyDrive"])
    ],
    dependencies: [
        .package(url: "https://github.com/getsentry/sentry-cocoa.git", from: "8.40.0")
    ],
    targets: [
        // Everything that finds and removes things. No UI, so it can be
        // tested and driven from the command line (`TidyDrive --report`).
        .target(
            name: "TidyDriveCore",
            path: "Sources/TidyDriveCore"
        ),
        .executableTarget(
            name: "TidyDrive",
            dependencies: [
                "TidyDriveCore",
                .product(name: "Sentry", package: "sentry-cocoa")
            ],
            path: "Sources/TidyDrive",
            // Info.plist and the icon are placed by build.sh, not by SwiftPM.
            exclude: ["Resources/Info.plist"]
        ),
        .testTarget(
            name: "TidyDriveCoreTests",
            dependencies: ["TidyDriveCore"],
            path: "Tests/TidyDriveCoreTests"
        )
    ]
)
