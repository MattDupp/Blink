// swift-tools-version: 5.10
//
// The package manifest: it tells the Swift Package Manager (SwiftPM) what to build.
//
// tools-version 5.10 keeps the code in "Swift 5 language mode". The Swift 6 mode turns every
// data-race suspicion into a compile error, which is valuable in a big code base but would bury
// the camera code (callbacks arriving on background threads) under annotations.
import PackageDescription

let package = Package(
    name: "BlinkMonitor",
    platforms: [.macOS(.v14)],
    targets: [
        // BlinkCore: everything that is not a window. The camera, finding and cropping the
        // eyes, the model, the blink-counting rules, the history, the file formats.
        // It is a LIBRARY on purpose: the recorder and the monitor both use it, so the model
        // is trained on exactly the pictures it will see when it runs - and the tests can
        // exercise every rule without a camera.
        .target(name: "BlinkCore"),

        // BlinkUI: the few SwiftUI views both apps show.
        .target(name: "BlinkUI", dependencies: ["BlinkCore"]),

        // BlinkRecorder: the window that records labelled eye pictures - the training data.
        .executableTarget(name: "BlinkRecorder", dependencies: ["BlinkCore", "BlinkUI"]),

        // BlinkMonitor: the menu-bar app. Runs the trained model on the camera and counts blinks.
        .executableTarget(name: "BlinkMonitor", dependencies: ["BlinkCore", "BlinkUI"]),

        // BlinkReplay: a command-line tool. It runs captures that kept their whole frames
        // through the eye finding again, and counts: how a change to that stage is judged.
        .executableTarget(name: "BlinkReplay", dependencies: ["BlinkCore"]),

        // `make test` runs these (Swift Testing).
        .testTarget(name: "BlinkCoreTests", dependencies: ["BlinkCore"]),

        // The menu-bar app's own logic: its model, its clock, the demo.
        .testTarget(name: "BlinkMonitorTests", dependencies: ["BlinkMonitor"]),
    ]
)
