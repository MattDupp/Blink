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
        // eyes, recording them, training the model and running it, the blink-counting
        // rules, the history, the file formats.
        // It is a LIBRARY on purpose: recording and monitoring go through the same code, so
        // the model is trained on exactly the pictures it will see when it runs - and the
        // tests can exercise every rule without a camera.
        .target(name: "BlinkCore"),

        // BlinkUI: the SwiftUI views and the voice that are not tied to one window.
        .target(name: "BlinkUI", dependencies: ["BlinkCore"]),

        // BlinkMonitor: the menu-bar app. Its setup records your eyes and trains your model;
        // then it runs the model on the camera and counts blinks.
        .executableTarget(name: "BlinkMonitor", dependencies: ["BlinkCore", "BlinkUI"]),

        // BlinkTrain: a command-line tool. It runs the app's own trainer on trainings
        // described in a file, so that it can be measured against the Python route on the
        // same pictures and the same splits (`make compare`).
        .executableTarget(name: "BlinkTrain", dependencies: ["BlinkCore"]),

        // BlinkReplay: a command-line tool. It runs captures that kept their whole frames
        // through the eye finding again, and counts: how a change to that stage is judged.
        .executableTarget(name: "BlinkReplay", dependencies: ["BlinkCore"]),

        // `make test` runs these (Swift Testing).
        .testTarget(name: "BlinkCoreTests", dependencies: ["BlinkCore"]),

        // The menu-bar app's own logic: its model, its clock, the demo.
        .testTarget(name: "BlinkMonitorTests", dependencies: ["BlinkMonitor"]),
    ]
)
