// swift-tools-version: 5.10
//
// The package manifest: it tells the Swift Package Manager (SwiftPM) what to build.
//
// tools-version 5.10 keeps the code in "Swift 5 language mode". The Swift 6 mode turns every
// data-race suspicion into a compile error, which is valuable in a big code base but would bury
// the camera code (callbacks arriving on background threads) under annotations while we learn.
import PackageDescription

let package = Package(
    name: "BlinkMonitor",
    platforms: [.macOS(.v14)],
    targets: [
        // BlinkCore: everything that turns a camera frame into two small eye pictures.
        // It is a LIBRARY on purpose: the recorder (now) and the monitoring app (later) both
        // use it, so the model is trained on exactly the pictures it will see when it runs.
        .target(name: "BlinkCore"),

        // BlinkRecorder: the window that records labelled eye pictures - our training data.
        .executableTarget(name: "BlinkRecorder", dependencies: ["BlinkCore"]),

        // BlinkMonitor: runs the trained model on the live camera and counts blinks.
        .executableTarget(name: "BlinkMonitor", dependencies: ["BlinkCore"]),
    ]
)
