import Foundation
import Combine
import SwiftUI
import Testing
import BlinkCore
import BlinkUI
@testable import BlinkMonitor
/// The app's own model, without a camera: started from a state, fed updates by hand.
@MainActor
@Suite("The app's model", .serialized)
struct ModelTests {

    private func running() -> MonitorModel {
        MonitorModel(preferences: .temporary(), initial: MonitorModel.InitialState())
    }

    private func frame(face: Bool = true, rate: Double? = 13, event: BlinkDetector.Event? = nil) -> MonitorUpdate {
        var update = MonitorUpdate()
        update.live.faceFound = face
        update.live.counters.ratePerMinute = rate
        update.event = event
        return update
    }

    // MARK: Pause

    @Test("A new model that cannot be read is said, with Try Again, and is not taken for no model")
    func unreadableNewModel() async throws {
        let place = DataPlace.scratch()
        defer { try? FileManager.default.removeItem(at: place.folder) }
        let store = place.models
        try PrivateFolder.create(at: store.folder)
        let accepted = ModelInfo.Proof(found: 10, of: 10, extra: 0, on: Date(), accepted: true)
        try ModelInfo(trainedOn: Date(), sessions: ["a"], openPictures: 100, closedPictures: 100, passes: 8, seconds: 3,
                      lastLoss: 0.01, rightOnOwnPictures: 200, largestDifference: 0, proof: accepted)
            .write(to: store.folder.appendingPathComponent(ModelStore.infoName))
        try Data("not a network".utf8).write(to: store.folder.appendingPathComponent(ModelStore.weightsName))
        let model = MonitorModel(preferences: .temporary(), place: place, initial: MonitorModel.InitialState())
        #expect(model.lifecycle == .running)
        await model.modelChanged()
        #expect(model.failure == .model(trainedHere: true))
        guard case .failed = model.lifecycle else {
            Issue.record("it should have failed, not \(model.lifecycle)")
            return
        }
    }

    @Test("A timed pause says when it ends, and is over at that moment whatever the timer does")
    func timedPause() {
        let model = running()
        let now = Date()
        model.pause(for: .fifteenMinutes, now: now)
        #expect(model.isPaused)
        #expect(model.status(now: now.addingTimeInterval(60)) == .paused(until: now.addingTimeInterval(900)))
        #expect(model.status(now: now.addingTimeInterval(901)) != .paused(until: now.addingTimeInterval(900)))
        model.resume()
        #expect(!model.isPaused)
    }

    @Test("Frames that arrive during a pause are not shown")
    func pauseIgnoresFrames() {
        let model = running()
        model.pause(for: .untilResumed)
        model.apply(frame(rate: 40))
        #expect(model.live.counters.ratePerMinute == nil)
        model.resume()
    }

    // MARK: A camera that stops sending pictures

    @Test("No picture for more than five seconds is said, and the last number is not left on screen")
    func silentCamera() {
        let model = running()
        let start = Date()
        model.apply(frame(), now: start)
        #expect(model.status(now: start) == .watching(rate: 13))

        model.checkCamera(now: start.addingTimeInterval(3))
        #expect(!model.cameraSilent)

        model.checkCamera(now: start.addingTimeInterval(6))
        #expect(model.cameraSilent)
        #expect(model.status(now: start.addingTimeInterval(6)) == .cameraSilent)
        #expect(model.live.counters.ratePerMinute == nil)

        // The pictures come back: so does the status, by itself.
        model.apply(frame(), now: start.addingTimeInterval(8))
        #expect(!model.cameraSilent)
        #expect(model.status(now: start.addingTimeInterval(8)) == .watching(rate: 13))
    }

    @Test("On Automatic, ten seconds without a picture and the app tries another camera, once; a chosen camera is kept")
    func cameraFallback() {
        let own = CameraOption(id: "own", name: "FaceTime HD Camera", builtIn: true)
        let desk = CameraOption(id: "desk", name: "Studio Display Camera", builtIn: false)
        let model = running()
        model.cameraOptions = { [own, desk] }
        let start = Date()
        model.apply(frame(), now: start)
        model.checkCamera(now: start.addingTimeInterval(6))
        #expect(model.cameraSilent && model.cameraMovedTo == nil, "silent, but not for ten seconds yet")
        model.checkCamera(now: start.addingTimeInterval(11))
        #expect(model.cameraMovedTo == "Studio Display Camera")
        #expect(CameraWords.moved(to: "Studio Display Camera").contains("test it again"))

        // A camera chosen by hand: the note goes, and silence no longer moves anything.
        model.setCamera("own")
        #expect(model.cameraMovedTo == nil && model.preferences.cameraID == "own")
        model.checkCamera(now: Date().addingTimeInterval(60))
        #expect(model.cameraMovedTo == nil)
        model.setCamera(nil)
        #expect(model.preferences.cameraID == nil)
    }

    @Test("Rest on battery turns counting off and back by itself; Resume counts anyway until the Mac is plugged in")
    func restOnBattery() {
        let model = running()
        var onBattery = false
        model.powerFacts = { (onBattery, false) }
        let start = Date()
        model.apply(frame(), now: start)
        model.preferences.pauseOnBattery = true
        model.checkEnergy()
        #expect(model.energyHold == nil && model.status(now: start) == .watching(rate: 13))

        onBattery = true
        model.checkEnergy()
        #expect(model.energyHold == .battery && model.showsResume && !model.isPaused)
        #expect(model.status(now: start) == .paused(until: nil))
        #expect(model.status(now: start).explanation(limit: 10, energy: model.energyHold).hasPrefix("Resting on battery"))

        // "Resume" during the rest: it counts anyway, and the rule does not undo that.
        model.resume()
        model.checkEnergy()
        #expect(model.energyHold == nil && !model.showsResume)
        // Plugged in, then on battery again: the rule applies again.
        onBattery = false
        model.checkEnergy()
        onBattery = true
        model.checkEnergy()
        #expect(model.energyHold == .battery)
        onBattery = false
        model.checkEnergy()
        #expect(model.energyHold == nil)
    }

    @Test("Quiet during calls holds the banners only when it is switched on and the microphone is in use")
    func quietDuringCalls() {
        let model = running()
        var inUse = true
        model.microphoneInUse = { inUse }
        #expect(!model.reminders.busy().call, "off unless chosen")
        model.preferences.quietDuringCalls = true
        #expect(model.reminders.busy().call && !model.reminders.mayShowRoutineBanner())
        inUse = false
        #expect(!model.reminders.busy().call && model.reminders.mayShowRoutineBanner())
    }

    @Test("A paused camera is not a silent one")
    func pausedIsNotSilent() {
        let model = running()
        let start = Date()
        model.apply(frame(), now: start)
        model.pause(for: .untilResumed, now: start)
        model.checkCamera(now: start.addingTimeInterval(60))
        #expect(!model.cameraSilent)
        model.resume()
    }

    // MARK: Blinks

    @Test("Each counted blink is announced once: the menu-bar eye blinks back")
    func blinkAnnounced() {
        let model = running()
        var announced = 0
        let listening = model.blinked.sink { announced += 1 }
        model.apply(frame(event: .blink(Blink(start: 1, end: 1.15))))
        model.apply(frame())
        model.apply(frame(event: .longClosure(seconds: 2)))        // not a blink
        #expect(announced == 1)
        listening.cancel()
    }

    @Test("A blink break counts the events of the model it belongs to, slow blinks included")
    func blinkBreakCounts() {
        let model = running()
        model.blinkBreak.start()
        model.apply(frame(event: .blink(Blink(start: 1, end: 1.15))))
        model.apply(frame(event: .longClosure(seconds: 1.1)))
        #expect(model.blinkBreak.exercise?.count == 2)
        model.blinkBreak.stop()
    }

    @Test("Quitting writes the minute in progress when it holds enough to have a rate")
    func minuteSavedOnQuit() {
        let history = HistoryController(store: DataPlace.scratch().history)
        let start = Date(timeIntervalSince1970: 1_800_000_040)
        history.update(current: MinuteRecord(start: start, observedSeconds: 8, blinks: 2))
        history.saveCurrentMinute(now: start)
        #expect(history.minutes.isEmpty, "eight seconds are too few to be a minute's rate")
        history.update(current: MinuteRecord(start: start, observedSeconds: 41, blinks: 9))
        history.saveCurrentMinute(now: start)
        #expect(history.minutes.count == 1 && history.minutes[0].blinks == 9 && history.currentMinute == nil)
        #expect(history.store.load(since: .distantPast).count == 1)
    }

    @Test("A finished blink break says its result: the blinks it counted, and how long they took")
    func blinkBreakResult() {
        let breaks = BlinkBreakController()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        breaks.start(now: start)
        for index in 0..<10 {
            #expect(breaks.seconds == nil)
            breaks.record(.blink(Blink(start: Double(index), end: Double(index) + 0.2)), now: start.addingTimeInterval(Double(index + 1) * 3.8))
        }
        #expect(breaks.exercise?.isDone == true && breaks.seconds == 38)
        #expect(BlinkBreakWords.result(blinks: 10, seconds: 38) == "10 blinks in 38 seconds. No blink reminder for 20 minutes.")
        #expect(!BlinkBreakWords.result(blinks: 10, seconds: nil).contains("full"), "it counts any blink, and does not claim more")
        breaks.stop()
    }
}
