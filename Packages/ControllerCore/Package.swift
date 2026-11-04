// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ControllerCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "ControllerCore", targets: ["ControllerCore"]),
        .executable(name: "ControllerCoreChecks", targets: ["ControllerCoreChecks"])
    ],
    targets: [
        .target(name: "ControllerCore"),
        .executableTarget(name: "ControllerCoreChecks", dependencies: ["ControllerCore"], path: "Checks"),
        .testTarget(name: "ControllerCoreTests", dependencies: ["ControllerCore"])
    ]
)
