// swift-tools-version: 5.10
//
// SPIKE: can the eye model be trained inside the app, in Swift, with Apple's own
// frameworks and only the Command Line Tools? Not part of the product; see harness.py.
import PackageDescription

let package = Package(
    name: "TrainingSpike",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "EyeTrainSpike"),
    ]
)
